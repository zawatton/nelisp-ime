#include "nelisp_ime_client.hpp"
#include <fcitx-utils/eventdispatcher.h>
#include <fcitx-utils/utf8.h>
#include <fcitx/addonfactory.h>
#include <fcitx/addonmanager.h>
#include <fcitx/candidatelist.h>
#include <fcitx/inputcontext.h>
#include <fcitx/inputcontextproperty.h>
#include <fcitx/inputmethodengine.h>
#include <fcitx/inputpanel.h>
#include <fcitx/instance.h>
#include <cstdlib>
#include <memory>
#include <atomic>
#include <chrono>
#include <exception>
#include <thread>
#include <string>
#include <unordered_set>
#include <utility>
#include <vector>

class NelispEngine;
class NelispState;

namespace {
std::string envOr(const char *name, const char *fallback) {
  const char *value = std::getenv(name);
  return value && *value ? value : fallback;
}
class NelispCandidate final : public fcitx::CandidateWord {
public:
  NelispCandidate(NelispState *state, int index, std::string value);
  void select(fcitx::InputContext *) const override;
private:
  NelispState *state_;
  int index_;
};
class NelispCandidateList final : public fcitx::CandidateList,
                                  public fcitx::CursorMovableCandidateList {
public:
  NelispCandidateList(NelispState *state,
                      const std::vector<std::string> &values, int cursor) {
    setCursorMovable(this);
    cursor_ = values.empty() ? -1 : cursor;
    for (size_t i = 0; i < values.size(); ++i)
      words_.push_back(std::make_unique<NelispCandidate>(
          state, static_cast<int>(i), values[i]));
  }
  const fcitx::Text &label(int) const override { return empty_; }
  const fcitx::CandidateWord &candidate(int index) const override {
    return *words_.at(static_cast<size_t>(index));
  }
  int size() const override { return static_cast<int>(words_.size()); }
  fcitx::CandidateLayoutHint layoutHint() const override {
    return fcitx::CandidateLayoutHint::Vertical;
  }
  void prevCandidate() override { if (!words_.empty()) cursor_ = (cursor_ + size() - 1) % size(); }
  void nextCandidate() override { if (!words_.empty()) cursor_ = (cursor_ + 1) % size(); }
  int cursorIndex() const override { return cursor_; }
private:
  fcitx::Text empty_;
  std::vector<std::unique_ptr<NelispCandidate>> words_;
  int cursor_ = -1;
};
} // namespace

class NelispState final : public fcitx::InputContextProperty {
public:
  NelispState(NelispEngine *, fcitx::InputContext *);
  ~NelispState() override;
  void keyEvent(fcitx::KeyEvent &);
  void reset();
  void select(int);
  void clearUI() noexcept;
  bool ensureSession();
  void discardSession() noexcept;
  // Startup/recovery key queue: keys are held while NeLisp starts, then
  // replayed in order; unconsumed or unreplayable keys are forwarded.
  void queueKey(const fcitx::Key &key);
  void replayQueued();
  void forwardQueued() noexcept;
  void dropQueued() noexcept;
  bool hasQueued() const { return !queued_.empty(); }
private:
  void showQueued();
  std::vector<fcitx::Key> queued_;
  void apply(const nelisp_ime::Snapshot &, bool *commitDelivered = nullptr);
  void updateUI();
  NelispEngine *engine_;
  fcitx::InputContext *context_;
  std::string sessionId_;
  std::string preedit_;
  std::vector<std::string> candidates_;
  int candidateIndex_ = 0;
  int activeSegment_ = 0;
  int segmentCount_ = 0;
  uint64_t generation_ = 0;
};

class NelispEngine final : public fcitx::InputMethodEngineV2 {
public:
  explicit NelispEngine(fcitx::Instance *instance)
      : instance_(instance), client_(envOr("NELISP_IME_RUNTIME", "/usr/libexec/nelisp-ime/nelisp"),
                envOr("NELISP_IME_ROOT", "/usr/share/nelisp-ime/nelisp-root"),
                nelisp_ime::Client::TimeoutPolicy{std::chrono::seconds(60),
                                                  std::chrono::milliseconds(250)}),
        learningFile_(envOr("XDG_DATA_HOME",
                            (envOr("HOME", ".") + "/.local/share").c_str()) +
                      "/nelisp-ime/learning.json"),
        factory_([this](fcitx::InputContext &context) {
          return new NelispState(this, &context);
        }) {
    instance->inputContextManager().registerProperty("nelispImeState", &factory_);
    beginRecovery();
  }
  ~NelispEngine() override {
    shuttingDown_.store(true);
    if (recoveryThread_.joinable()) recoveryThread_.join();
    alive_.reset();
    factory_.unregister();
  }
  void keyEvent(const fcitx::InputMethodEntry &, fcitx::KeyEvent &event) override {
    if (event.isRelease()) return;
    finishRecoveryIfReady();
    auto *state = event.inputContext()->propertyFor(&factory_);
    if (recovering_.load()) {
      if (event.key().states()) return;
      state->queueKey(event.key());
      return event.filterAndAccept();
    }
    state->keyEvent(event);
  }
  void reset(const fcitx::InputMethodEntry &, fcitx::InputContextEvent &event) override {
    finishRecoveryIfReady();
    auto *state = event.inputContext()->propertyFor(&factory_);
    if (recovering_.load()) state->dropQueued();
    else state->reset();
  }
  void deactivate(const fcitx::InputMethodEntry &entry,
                  fcitx::InputContextEvent &event) override {
    event.inputContext()->propertyFor(&factory_)->forwardQueued();
    fcitx::InputMethodEngineV2::deactivate(entry, event);
  }
  bool recovering() const { return recovering_.load(); }
  nelisp_ime::Client &client() { return client_; }
  bool ready() { finishRecoveryIfReady(); return available_ && !recovering_.load(); }
  uint64_t generation() const { return generation_; }
  void add(NelispState *state) { states_.insert(state); }
  void remove(NelispState *state) { states_.erase(state); }
  void failed(const char *where, const std::exception &error) {
    FCITX_ERROR() << "NeLisp IME " << where << ": " << error.what();
    available_ = false;
    for (auto *state : states_) state->clearUI();
    beginRecovery();
  }
  void protocolFailure(NelispState *state, const std::exception &error) {
    FCITX_ERROR() << "NeLisp IME protocol: " << error.what();
    state->discardSession();
  }
  bool canCloseSessions() const { return available_ && !recovering_.load(); }
  void saveLearning() noexcept {
    try { client_.saveLearning(learningFile_); }
    catch (const nelisp_ime::TransportError &error) { failed("learning save", error); }
    catch (const std::exception &error) {
      FCITX_ERROR() << "NeLisp IME learning save: " << error.what();
    }
  }
private:
  void beginRecovery() {
    if (shuttingDown_.load() || recovering_.exchange(true)) return;
    lastRetry_ = std::chrono::steady_clock::now();
    recoveryDone_.store(false);
    recoverySucceeded_.store(false);
    try {
      recoveryThread_ = std::thread([this] {
        bool ok = false;
        try { client_.start(); client_.loadLearning(learningFile_); ok = true; }
        catch (const std::exception &error) {
          FCITX_ERROR() << "NeLisp IME recovery: " << error.what();
        }
        recoverySucceeded_.store(ok);
        recoveryDone_.store(true);
        // Settle held keys even when no further key arrives.
        instance_->eventDispatcher().schedule(
            [this, alive = std::weak_ptr<int>(alive_)] {
              if (alive.lock()) finishRecoveryIfReady();
            });
      });
    } catch (const std::exception &error) {
      available_ = false;
      recoveryDone_.store(false);
      recoverySucceeded_.store(false);
      recovering_.store(false);
      FCITX_ERROR() << "NeLisp IME recovery thread: " << error.what();
    }
  }
  void finishRecoveryIfReady() {
    if (recovering_.load() && recoveryDone_.load()) {
      if (recoveryThread_.joinable()) recoveryThread_.join();
      available_ = recoverySucceeded_.load();
      if (available_) ++generation_;
      recovering_.store(false);
      std::vector<NelispState *> states(states_.begin(), states_.end());
      for (auto *state : states) {
        if (!states_.count(state) || !state->hasQueued()) continue;
        if (available_) state->replayQueued();
        else state->forwardQueued();
      }
    }
    if (!available_) {
      auto now = std::chrono::steady_clock::now();
      if (now - lastRetry_ >= std::chrono::seconds(3)) beginRecovery();
    }
  }
  fcitx::Instance *instance_;
  std::shared_ptr<int> alive_ = std::make_shared<int>(0);
  nelisp_ime::Client client_;
  std::string learningFile_;
  fcitx::FactoryFor<NelispState> factory_;
  std::unordered_set<NelispState *> states_;
  std::thread recoveryThread_;
  std::atomic<bool> recovering_{false}, recoveryDone_{false}, recoverySucceeded_{false}, shuttingDown_{false};
  bool available_ = false;
  uint64_t generation_ = 0;
  std::chrono::steady_clock::time_point lastRetry_ = std::chrono::steady_clock::now();
};

NelispState::NelispState(NelispEngine *engine, fcitx::InputContext *context)
    : engine_(engine), context_(context),
      sessionId_("fcitx:" + std::to_string(reinterpret_cast<uintptr_t>(context))) {
  engine_->add(this);
}
NelispState::~NelispState() {
  engine_->remove(this);
  if (engine_->canCloseSessions() && generation_ == engine_->generation()) {
    try { engine_->client().closeSession(sessionId_); } catch (...) {}
  }
}
bool NelispState::ensureSession() {
  if (!engine_->ready()) return false;
  if (generation_ != engine_->generation()) {
    engine_->client().openSession(sessionId_, "romaji");
    generation_ = engine_->generation();
    preedit_.clear(); candidates_.clear(); candidateIndex_ = 0;
  }
  return true;
}
void NelispState::clearUI() noexcept {
  preedit_.clear(); candidates_.clear(); candidateIndex_ = 0;
  activeSegment_ = 0; segmentCount_ = 0; generation_ = 0;
  try { updateUI(); } catch (...) {}
}
void NelispState::discardSession() noexcept {
  clearUI();
  if (!engine_->canCloseSessions()) return;
  try { engine_->client().closeSession(sessionId_); }
  catch (const nelisp_ime::TransportError &error) { engine_->failed("session close", error); }
  catch (const std::exception &error) {
    FCITX_ERROR() << "NeLisp IME session close: " << error.what();
  }
}
void NelispState::apply(const nelisp_ime::Snapshot &snapshot, bool *commitDelivered) {
  preedit_ = snapshot.preedit;
  candidates_ = snapshot.candidates;
  candidateIndex_ = snapshot.candidateIndex;
  activeSegment_ = snapshot.activeSegment;
  segmentCount_ = snapshot.segmentCount;
  if (!snapshot.commit.empty()) {
    if (commitDelivered) *commitDelivered = true;
    context_->commitString(snapshot.commit);
    engine_->saveLearning();
  }
  updateUI();
}
void NelispState::updateUI() {
  auto &panel = context_->inputPanel();
  panel.reset();
  if (!preedit_.empty()) {
    fcitx::Text text(preedit_, fcitx::TextFormatFlag::HighLight);
    if (context_->capabilityFlags().test(fcitx::CapabilityFlag::Preedit))
      panel.setClientPreedit(text);
    else panel.setPreedit(text);
  }
  if (!candidates_.empty())
    panel.setCandidateList(std::make_unique<NelispCandidateList>(this, candidates_, candidateIndex_));
  context_->updateUserInterface(fcitx::UserInterfaceComponent::InputPanel);
  context_->updatePreedit();
}
void NelispState::select(int index) {
  try {
    if (!ensureSession()) return;
    apply(engine_->client().feedOperation(sessionId_, "select-candidate", index));
    apply(engine_->client().feedOperation(sessionId_, "commit"));
  } catch (const nelisp_ime::TransportError &error) { engine_->failed("candidate selection", error); }
    catch (const std::exception &error) { engine_->protocolFailure(this, error); }
}
void NelispState::reset() {
  try {
    if (!ensureSession()) { clearUI(); return; }
    apply(engine_->client().feedOperation(sessionId_, "cancel"));
  } catch (const nelisp_ime::TransportError &error) { engine_->failed("reset", error); }
    catch (const std::exception &error) { engine_->protocolFailure(this, error); }
}
void NelispState::queueKey(const fcitx::Key &key) {
  static constexpr size_t limit = 64;
  if (queued_.size() >= limit) {
    FCITX_WARN() << "NeLisp IME QUEUE_FULL";
    return;
  }
  queued_.push_back(key);
  showQueued();
}
void NelispState::showQueued() {
  std::string raw;
  for (const auto &key : queued_) {
    uint32_t cp = fcitx::Key::keySymToUnicode(key.sym());
    if (cp >= 0x20 && cp != 0x7f) raw += fcitx::utf8::UCS4ToUTF8(cp);
  }
  auto &panel = context_->inputPanel();
  panel.reset();
  if (!raw.empty()) {
    fcitx::Text text(raw, fcitx::TextFormatFlag::Underline);
    if (context_->capabilityFlags().test(fcitx::CapabilityFlag::Preedit))
      panel.setClientPreedit(text);
    else panel.setPreedit(text);
  }
  context_->updateUserInterface(fcitx::UserInterfaceComponent::InputPanel);
  context_->updatePreedit();
}
void NelispState::replayQueued() {
  auto keys = std::move(queued_);
  queued_.clear();
  try { updateUI(); } catch (...) {}
  for (size_t i = 0; i < keys.size(); ++i) {
    if (engine_->recovering()) {
      // A replayed key broke the transport again: hold the rest.
      queued_.assign(keys.begin() + static_cast<std::ptrdiff_t>(i), keys.end());
      showQueued();
      return;
    }
    fcitx::KeyEvent event(context_, keys[i]);
    keyEvent(event);
    if (!event.filtered()) context_->forwardKey(keys[i]);
  }
}
void NelispState::forwardQueued() noexcept {
  auto keys = std::move(queued_);
  queued_.clear();
  try {
    updateUI();
    for (const auto &key : keys) context_->forwardKey(key);
  } catch (...) {}
}
void NelispState::dropQueued() noexcept {
  if (queued_.empty()) return;
  queued_.clear();
  try { updateUI(); } catch (...) {}
}
void NelispState::keyEvent(fcitx::KeyEvent &event) {
  if (event.key().states()) return;
  bool commitDelivered = false;
  try {
    if (!ensureSession()) { clearUI(); return; }
    if (event.key().check(FcitxKey_BackSpace)) {
      if (preedit_.empty()) return;
      apply(engine_->client().feedOperation(sessionId_, "backspace"), &commitDelivered);
      return event.filterAndAccept();
    }
    if (event.key().check(FcitxKey_Escape)) {
      if (preedit_.empty()) return;
      apply(engine_->client().feedOperation(sessionId_, "cancel"), &commitDelivered);
      return event.filterAndAccept();
    }
    if (event.key().check(FcitxKey_Return)) {
      if (preedit_.empty()) return;
      apply(engine_->client().feedOperation(sessionId_, "commit"), &commitDelivered);
      return event.filterAndAccept();
    }
    if (event.key().check(FcitxKey_space) && !candidates_.empty()) {
      candidateIndex_ = (candidateIndex_ + 1) % static_cast<int>(candidates_.size());
      apply(engine_->client().feedOperation(sessionId_, "select-candidate", candidateIndex_), &commitDelivered);
      return event.filterAndAccept();
    }
    if (event.key().check(FcitxKey_Left) && activeSegment_ > 0) {
      apply(engine_->client().feedOperation(sessionId_, "select-segment", activeSegment_ - 1), &commitDelivered);
      return event.filterAndAccept();
    }
    if (event.key().check(FcitxKey_Right) && activeSegment_ + 1 < segmentCount_) {
      apply(engine_->client().feedOperation(sessionId_, "select-segment", activeSegment_ + 1), &commitDelivered);
      return event.filterAndAccept();
    }
    uint32_t cp = fcitx::Key::keySymToUnicode(event.key().sym());
    if (!((cp >= 'a' && cp <= 'z') || (cp >= 'A' && cp <= 'Z') || cp == '\'')) {
      if (!preedit_.empty() && cp) {
        apply(engine_->client().feedOperation(sessionId_, "commit"), &commitDelivered);
        context_->commitString(fcitx::utf8::UCS4ToUTF8(cp));
        return event.filterAndAccept();
      }
      if (!preedit_.empty()) return event.filterAndAccept();
      return;
    }
    apply(engine_->client().feedKey(sessionId_, fcitx::utf8::UCS4ToUTF8(cp)), &commitDelivered);
    event.filterAndAccept();
  } catch (const nelisp_ime::TransportError &error) {
    engine_->failed("key event", error);
    if (commitDelivered) event.filterAndAccept();
  } catch (const std::exception &error) {
    FCITX_ERROR() << "NeLisp IME key event: " << error.what();
    engine_->protocolFailure(this, error);
    if (commitDelivered) event.filterAndAccept();
  }
}

namespace {
NelispCandidate::NelispCandidate(NelispState *state, int index, std::string value)
    : state_(state), index_(index) { setText(fcitx::Text(std::move(value))); }
void NelispCandidate::select(fcitx::InputContext *) const { state_->select(index_); }
} // namespace

class NelispEngineFactory final : public fcitx::AddonFactory {
public:
  fcitx::AddonInstance *create(fcitx::AddonManager *manager) override {
    return new NelispEngine(manager->instance());
  }
};
FCITX_ADDON_FACTORY(NelispEngineFactory);
