#include <chrono>
#include <cstdlib>
#include <iostream>
#include <string>
#include <thread>

#ifndef _WIN32
#include <csignal>
#endif

int main() {
  const char *configured = std::getenv("NELISP_IME_FAULT_MODE");
  const std::string mode = configured ? configured : "normal";
#ifndef _WIN32
  if (mode == "ignore-term") std::signal(SIGTERM, SIG_IGN);
#endif
  std::string line;
  unsigned requests = 0;
  while (std::getline(std::cin, line)) {
    if (line.find("(progn ") != std::string::npos) {
      if (mode == "startup-stall") { std::this_thread::sleep_for(std::chrono::seconds(30)); return 0; }
      if (mode == "trickle") {
        for (char c : std::string("ready\n")) {
          std::cout << c << std::flush;
          std::this_thread::sleep_for(std::chrono::milliseconds(55));
        }
      } else if (mode == "exit") {
        return 0;
      } else {
        std::cout << "ready\n" << std::flush;
      }
      continue;
    }
    ++requests;
    if (requests == 1) {
      std::cout << "{\"result\":{\"ok\":true}}\n" << std::flush;
      continue;
    }
    if (mode == "late-reply" && requests == 2)
      std::this_thread::sleep_for(std::chrono::milliseconds(350));
    if (mode == "reply-stall" || mode == "ignore-term") {
      std::this_thread::sleep_for(std::chrono::seconds(30));
      return 0;
    }
    if (mode == "exit-reply") return 0;
    if (mode == "error-once" && requests == 2) {
      std::cout << "{\"error\":{\"message\":\"fixture error\"}}\n" << std::flush;
      continue;
    }
    std::cout << "{\"result\":{\"ok\":true}}\n" << std::flush;
    if (mode == "exit-after-reply") return 0;
  }
}
