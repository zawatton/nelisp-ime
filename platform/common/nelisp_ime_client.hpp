#pragma once

#include <memory>
#include <string>
#include <vector>

namespace nelisp_ime {

struct Snapshot {
  bool consumed = false;
  std::string reading;
  std::string preedit;
  std::string commit;
  std::vector<std::string> candidates;
  int candidateIndex = 0;
  int activeSegment = 0;
  int segmentCount = 0;
};

class Client {
public:
  Client(std::string runtime, std::string resourceRoot);
  ~Client();
  Client(const Client &) = delete;
  Client &operator=(const Client &) = delete;

  void start();
  // `detail' selects how much each snapshot carries: "compact" omits the
  // candidate list and segment breakdown, which is what an adapter that only
  // shows candidates on demand should use -- encoding cost tracks payload
  // size on the standalone runtime.  Empty leaves the engine default (full).
  void openSession(const std::string &sessionId,
                   const std::string &inputStyle = "romaji",
                   const std::string &detail = "");
  // Side-effect-free snapshot.  Pass detail="full" from a compact session to
  // fetch the candidate list when opening a candidate window.
  Snapshot status(const std::string &sessionId,
                  const std::string &detail = "");
  void closeSession(const std::string &sessionId);
  Snapshot feedKey(const std::string &sessionId, const std::string &key);
  Snapshot feedOperation(const std::string &sessionId,
                         const std::string &operation, int index = -1);
  void loadLearning(const std::string &file);
  void saveLearning(const std::string &file);

private:
  class Process;
  std::unique_ptr<Process> process_;
  std::string runtime_;
  std::string root_;
  int requestId_ = 1;
  std::string request(const std::string &method, const std::string &params);
};

} // namespace nelisp_ime
