#include "nelisp_ime_client.hpp"
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
#include <string>
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
private:
  void apply(const nelisp_ime::Snapshot &);
  void updateUI();
  NelispEngine *engine_;
  fcitx::InputContext *context_;
  std::string sessionId_;
  std::string preedit_;
  std::vector<std::string> candidates_;
  int candidateIndex_ = 0;
  int activeSegment_ = 0;
  int segmentCount_ = 0;
};

class NelispEngine final : public fcitx::InputMethodEngineV2 {
public:
  explicit NelispEngine(fcitx::Instance *instance)
      : client_(envOr("NELISP_IME_RUNTIME", "/usr/libexec/nelisp-ime/nelisp"),
                envOr("NELISP_IME_ROOT", "/usr/share/nelisp-ime/nelisp-root")),
        learningFile_(envOr("XDG_DATA_HOME",
                            (envOr("HOME", ".") + "/.local/share").c_str()) +
                      "/nelisp-ime/learning.json"),
        factory_([this](fcitx::InputContext &context) {
          return new NelispState(this, &context);
        }) {
    client_.start();
    client_.loadLearning(learningFile_);
    instance->inputContextManager().registerProperty("nelispImeState", &factory_);
  }
  void keyEvent(const fcitx::InputMethodEntry &, fcitx::KeyEvent &event) override {
    if (!event.isRelease()) event.inputContext()->propertyFor(&factory_)->keyEvent(event);
  }
  void reset(const fcitx::InputMethodEntry &, fcitx::InputContextEvent &event) override {
    event.inputContext()->propertyFor(&factory_)->reset();
  }
  nelisp_ime::Client &client() { return client_; }
  void saveLearning() { client_.saveLearning(learningFile_); }
private:
  nelisp_ime::Client client_;
  std::string learningFile_;
  fcitx::FactoryFor<NelispState> factory_;
};

NelispState::NelispState(NelispEngine *engine, fcitx::InputContext *context)
    : engine_(engine), context_(context),
      sessionId_("fcitx:" + std::to_string(reinterpret_cast<uintptr_t>(context))) {
  engine_->client().openSession(sessionId_, "romaji");
}
NelispState::~NelispState() {
  try { engine_->client().closeSession(sessionId_); } catch (...) {}
}
void NelispState::apply(const nelisp_ime::Snapshot &snapshot) {
  preedit_ = snapshot.preedit;
  candidates_ = snapshot.candidates;
  candidateIndex_ = snapshot.candidateIndex;
  activeSegment_ = snapshot.activeSegment;
  segmentCount_ = snapshot.segmentCount;
  if (!snapshot.commit.empty()) {
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
  apply(engine_->client().feedOperation(sessionId_, "select-candidate", index));
  apply(engine_->client().feedOperation(sessionId_, "commit"));
}
void NelispState::reset() {
  apply(engine_->client().feedOperation(sessionId_, "cancel"));
}
void NelispState::keyEvent(fcitx::KeyEvent &event) {
  if (event.key().states()) return;
  try {
    if (event.key().check(FcitxKey_BackSpace)) {
      if (preedit_.empty()) return;
      apply(engine_->client().feedOperation(sessionId_, "backspace"));
      return event.filterAndAccept();
    }
    if (event.key().check(FcitxKey_Escape)) {
      if (preedit_.empty()) return;
      reset(); return event.filterAndAccept();
    }
    if (event.key().check(FcitxKey_Return)) {
      if (preedit_.empty()) return;
      apply(engine_->client().feedOperation(sessionId_, "commit"));
      return event.filterAndAccept();
    }
    if (event.key().check(FcitxKey_space) && !candidates_.empty()) {
      candidateIndex_ = (candidateIndex_ + 1) % static_cast<int>(candidates_.size());
      apply(engine_->client().feedOperation(sessionId_, "select-candidate", candidateIndex_));
      return event.filterAndAccept();
    }
    if (event.key().check(FcitxKey_Left) && activeSegment_ > 0) {
      apply(engine_->client().feedOperation(sessionId_, "select-segment", activeSegment_ - 1));
      return event.filterAndAccept();
    }
    if (event.key().check(FcitxKey_Right) && activeSegment_ + 1 < segmentCount_) {
      apply(engine_->client().feedOperation(sessionId_, "select-segment", activeSegment_ + 1));
      return event.filterAndAccept();
    }
    uint32_t cp = fcitx::Key::keySymToUnicode(event.key().sym());
    if (!((cp >= 'a' && cp <= 'z') || (cp >= 'A' && cp <= 'Z') || cp == '\'')) {
      if (!preedit_.empty() && cp) {
        apply(engine_->client().feedOperation(sessionId_, "commit"));
        context_->commitString(fcitx::utf8::UCS4ToUTF8(cp));
        return event.filterAndAccept();
      }
      if (!preedit_.empty()) return event.filterAndAccept();
      return;
    }
    apply(engine_->client().feedKey(sessionId_, fcitx::utf8::UCS4ToUTF8(cp)));
    event.filterAndAccept();
  } catch (const std::exception &error) {
    FCITX_ERROR() << "NeLisp IME: " << error.what();
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
