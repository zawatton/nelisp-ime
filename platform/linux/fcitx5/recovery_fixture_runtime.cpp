#include <chrono>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <string>
#include <thread>

static std::string env(const char *name) {
  const char *value = std::getenv(name);
  return value ? value : "";
}

static std::string mode() {
  std::ifstream input(env("NELISP_FCITX_FIXTURE_MODE_FILE"));
  std::string value;
  input >> value;
  return value;
}

static void log(const std::string &line) {
  std::ofstream output(env("NELISP_FCITX_FIXTURE_LOG"), std::ios::app);
  output << line << '\n';
}

int main() {
  std::string line;
  if (!std::getline(std::cin, line)) return 2;
  if (mode() == "slow-boot") std::this_thread::sleep_for(std::chrono::milliseconds(400));
  log("BOOT");
  std::cout << "ready" << std::endl;
  while (std::getline(std::cin, line)) {
    log(line);
    const std::string current = mode();
    if (current == "key-fail" && line.find("\\\"key\\\":\\\"x\\\"") != std::string::npos)
      return 0;
    if (current == "save-fail" && line.find("learning.export") != std::string::npos)
      return 0;
    if (current == "protocol" && line.find("\\\"key\\\":\\\"p\\\"") != std::string::npos) {
      std::cout << R"({"jsonrpc":"2.0","id":1,"error":{"code":-1,"message":"fixture protocol error"}})" << std::endl;
      continue;
    }
    if (line.find("ime/session.feed") != std::string::npos &&
        line.find("\\\"key\\\":\\\"a\\\"") != std::string::npos) {
      std::cout << R"({"jsonrpc":"2.0","id":1,"result":{"consumed":true,"reading":"a","preedit":"a","commit":"","candidates":["A"],"candidate-index":0,"active-segment":0,"segments":[]}})" << std::endl;
    } else if (line.find("ime/session.feed") != std::string::npos &&
               line.find("\\\"key\\\":\\\"b\\\"") != std::string::npos) {
      std::cout << R"({"jsonrpc":"2.0","id":1,"result":{"consumed":true,"reading":"ab","preedit":"ab","commit":"","candidates":["AB"],"candidate-index":0,"active-segment":0,"segments":[]}})" << std::endl;
    } else if (line.find("ime/session.feed") != std::string::npos &&
               line.find("\\\"key\\\":\\\"c\\\"") != std::string::npos) {
      std::cout << R"({"jsonrpc":"2.0","id":1,"result":{"consumed":true,"reading":"c","preedit":"","commit":"Z","candidates":[],"candidate-index":0,"active-segment":0,"segments":[]}})" << std::endl;
    } else if (line.find("ime/session.feed") != std::string::npos) {
      std::cout << R"({"jsonrpc":"2.0","id":1,"result":{"consumed":true,"reading":"","preedit":"","commit":"","candidates":[],"candidate-index":0,"active-segment":0,"segments":[]}})" << std::endl;
    } else {
      std::cout << R"({"jsonrpc":"2.0","id":1,"result":{}})" << std::endl;
    }
  }
  return 0;
}
