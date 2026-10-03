#include "nelisp-ime.cpp"

#include <fcitx/inputcontextmanager.h>
#include <fcitx/instance.h>
#include <fcitx/inputmethodentry.h>
#include <fcitx-utils/key.h>
#include <fcitx/event.h>

#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <thread>
#include <algorithm>

class FixtureContext final : public fcitx::InputContext {
public:
  explicit FixtureContext(fcitx::InputContextManager &manager)
      : InputContext(manager, "recovery-fixture") { created(); }
  ~FixtureContext() override { destroy(); }
  const char *frontend() const override { return "fixture"; }
  void commitStringImpl(const std::string &text) override { committed += text; }
  void deleteSurroundingTextImpl(int, unsigned int) override {}
  void forwardKeyImpl(const fcitx::ForwardKeyEvent &) override {}
  void updatePreeditImpl() override { ++updates; }
  std::string committed;
  unsigned updates = 0;
};

static void require(bool condition, const char *message) {
  if (!condition) throw std::runtime_error(message);
}
static void setEnv(const char *name, const std::string &value) {
  if (setenv(name, value.c_str(), 1) != 0) throw std::runtime_error("setenv failed");
}
static void setMode(const std::filesystem::path &path, const char *value) {
  std::ofstream(path, std::ios::trunc) << value;
}
static bool waitReady(NelispEngine &engine) {
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
  while (std::chrono::steady_clock::now() < deadline) {
    if (engine.ready()) return true;
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  return engine.ready();
}
static fcitx::KeyEvent key(FixtureContext &context, fcitx::KeySym sym) {
  return fcitx::KeyEvent(&context, fcitx::Key(sym));
}
static bool hasPreedit(const FixtureContext &context) {
  const auto &panel = context.inputPanel();
  return !panel.clientPreedit().empty() || !panel.preedit().empty();
}
static bool hasCandidates(const FixtureContext &context) {
  auto candidates = context.inputPanel().candidateList();
  return candidates && candidates->size() > 0;
}
static size_t occurrences(const std::string &text, const std::string &needle) {
  size_t count = 0, at = 0;
  while ((at = text.find(needle, at)) != std::string::npos) { ++count; at += needle.size(); }
  return count;
}

class TempDirectory {
public:
  explicit TempDirectory(std::filesystem::path path) : path_(std::move(path)) {}
  ~TempDirectory() { std::error_code error; std::filesystem::remove_all(path_, error); }
  const std::filesystem::path &path() const { return path_; }
private:
  std::filesystem::path path_;
};

int main(int argc, char **argv) {
  if (argc != 2) return 2;
  const auto temp = std::filesystem::temp_directory_path() /
      ("nelisp-fcitx-recovery-fixture-" + std::to_string(
          std::chrono::steady_clock::now().time_since_epoch().count()));
  TempDirectory cleanup(temp);
  std::filesystem::create_directories(temp);
  const auto modeFile = temp / "mode", logFile = temp / "runtime.log";
  std::filesystem::remove(logFile);
  setEnv("NELISP_IME_RUNTIME", argv[1]);
  setEnv("NELISP_IME_ROOT", temp.string());
  setEnv("XDG_DATA_HOME", temp.string());
  setEnv("XDG_CONFIG_HOME", (temp / "config").string());
  setEnv("XDG_CACHE_HOME", (temp / "cache").string());
  setEnv("NELISP_FCITX_FIXTURE_MODE_FILE", modeFile.string());
  setEnv("NELISP_FCITX_FIXTURE_LOG", logFile.string());
  std::filesystem::create_directories(temp / "nelisp-ime");
  std::filesystem::create_directories(temp / "config");
  std::filesystem::create_directories(temp / "cache");
  std::ofstream(temp / "nelisp-ime" / "learning.json") << "[]\n";
  setMode(modeFile, "normal");

  try {
    char instanceName[] = "fcitx-recovery-fixture";
    char *instanceArgs[] = {instanceName, nullptr};
    fcitx::Instance instance(1, instanceArgs);
    const fcitx::InputMethodEntry entry("nelisp", "NeLisp", "ja", "nelisp-ime");
    const auto missingRuntime = temp / "missing-runtime";
    setEnv("NELISP_IME_RUNTIME", missingRuntime.string());
    {
      NelispEngine offline(&instance);
      FixtureContext unavailable(instance.inputContextManager());
      auto initial = key(unavailable, FcitxKey_a);
      offline.keyEvent(entry, initial);
      require(!initial.filtered() && !initial.accepted(),
              "unavailable initial runtime consumed application input");
      const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(200);
      while (std::chrono::steady_clock::now() < deadline) {
        require(!offline.ready(), "missing runtime unexpectedly became ready");
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
      }
      std::filesystem::create_symlink(std::filesystem::absolute(argv[1]), missingRuntime);
      require(waitReady(offline), "same engine did not retry after initial startup failure");
      auto recovered = key(unavailable, FcitxKey_a);
      offline.keyEvent(entry, recovered);
      require(recovered.filtered() && hasPreedit(unavailable),
              "initially unavailable engine did not recover and accept input");
    }
    std::filesystem::remove(logFile);
    setEnv("NELISP_IME_RUNTIME", argv[1]);
    NelispEngine engine(&instance);
    FixtureContext first(instance.inputContextManager()), second(instance.inputContextManager());
    require(waitReady(engine), "fixture runtime did not bootstrap");

    auto a1 = key(first, FcitxKey_a); engine.keyEvent(entry, a1);
    auto a2 = key(second, FcitxKey_a); engine.keyEvent(entry, a2);
    require(a1.filtered() && a2.filtered(), "healthy keys were not filtered");
    require(hasPreedit(first) && hasPreedit(second), "preedit missing");
    require(hasCandidates(first) && hasCandidates(second), "candidate snapshots missing");

    setMode(modeFile, "key-fail");
    auto x = key(first, FcitxKey_x); engine.keyEvent(entry, x);
    require(!x.filtered() && !x.accepted(), "failed key was consumed instead of passed through");
    require(!hasPreedit(first) && !hasPreedit(second),
            "transport failure left stale preedit in a context");
    require(!hasCandidates(first) && !hasCandidates(second),
            "transport failure left stale candidates in a context");

    {
      FixtureContext transient(instance.inputContextManager());
      NelispState transientState(&engine, &transient);
    }
    setMode(modeFile, "normal");
    require(waitReady(engine), "engine did not recover in background");
    auto a3 = key(second, FcitxKey_a); engine.keyEvent(entry, a3);
    require(a3.filtered() && hasPreedit(second),
            "recovered session did not accept new input");

    setMode(modeFile, "protocol");
    auto p = key(second, FcitxKey_p); engine.keyEvent(entry, p);
    require(!p.filtered() && !hasPreedit(second), "protocol error did not fail open and clear its session");
    require(engine.ready(), "protocol error incorrectly invalidated the client");
    setMode(modeFile, "normal");
    auto a4 = key(second, FcitxKey_a); engine.keyEvent(entry, a4);
    require(a4.filtered() && hasPreedit(second), "session did not reopen after protocol error");

    setMode(modeFile, "save-fail");
    auto c = key(first, FcitxKey_c); engine.keyEvent(entry, c);
    require(c.filtered() && first.committed == "Z",
            "learning-save transport failure replayed or lost an already delivered commit");
    require(!hasPreedit(first) && !hasCandidates(first), "commit failure left stale UI");
    setMode(modeFile, "normal");
    require(waitReady(engine), "engine did not recover after learning save failure");
    auto a5 = key(first, FcitxKey_a); engine.keyEvent(entry, a5);
    require(a5.filtered() && first.committed == "Z", "post-recovery input duplicated the commit");

    std::ifstream logInput(logFile);
    const std::string log((std::istreambuf_iterator<char>(logInput)), {});
    require(occurrences(log, "\\\"key\\\":\\\"x\\\"") == 1,
            "failed key was replayed or not delivered exactly once");
    require(occurrences(log, "\\\"key\\\":\\\"c\\\"") == 1,
            "committed key was replayed after learning-save failure");
    require(occurrences(log, "BOOT") == 3, "protocol error unexpectedly restarted the client");
    require(occurrences(log, "learning.import") >= 3,
            "restarted clients did not attempt to restore the persisted learning file");
    std::cout << "PASS native Fcitx callbacks: clear, fail-open, recovery, protocol preservation, commit safety\n";
    return 0;
  } catch (const std::exception &error) {
    std::cerr << "FAIL: " << error.what() << '\n';
    return 1;
  }
}
