#include "nelisp_ime_client.hpp"

#include <chrono>
#include <cstdlib>
#include <iostream>
#include <stdexcept>
#include <string>

#ifdef _WIN32
#include <cstdlib>
#define SET_MODE(value) _putenv_s("NELISP_IME_FAULT_MODE", value)
#else
#define SET_MODE(value) setenv("NELISP_IME_FAULT_MODE", value, 1)
#endif

using namespace std::chrono;

static void expectFailure(nelisp_ime::Client &client, bool startup) {
  auto began = steady_clock::now();
  bool failed = false;
  try {
    if (startup) client.start(); else client.openSession("probe");
  } catch (const std::exception &) { failed = true; }
  auto elapsed = duration_cast<milliseconds>(steady_clock::now() - began).count();
  if (!failed || elapsed > 700)
    throw std::runtime_error("fault did not fail within bounded time");
  std::cout << "failure-ms=" << elapsed << '\n';
}

int main(int argc, char **argv) {
  if (argc != 2) return 2;
  nelisp_ime::Client::TimeoutPolicy timeouts{milliseconds(140), milliseconds(140)};
  nelisp_ime::Client client(argv[1], ".", timeouts);
  try {
    SET_MODE("startup-stall");
    expectFailure(client, true);
    SET_MODE("trickle");
    expectFailure(client, true);
    SET_MODE("exit");
    expectFailure(client, true);
    SET_MODE("late-reply");
    client.start();
    expectFailure(client, false);
    expectFailure(client, false);
    SET_MODE("normal");
    client.start();
    client.openSession("probe");
    SET_MODE("error-once");
    client.start();
    bool protocolError = false;
    try { client.openSession("probe"); }
    catch (const std::exception &) { protocolError = true; }
    if (!protocolError) throw std::runtime_error("protocol error was not surfaced");
    client.openSession("probe");
    SET_MODE("exit-after-reply");
    client.start();
    client.openSession("probe");
    expectFailure(client, false);
    SET_MODE("normal");
    client.start();
    client.openSession("probe");
    SET_MODE("exit-reply");
    client.start();
    expectFailure(client, false);
    SET_MODE("ignore-term");
    client.start();
    expectFailure(client, false);
    SET_MODE("normal");
    client.start();
    client.openSession("probe");
    std::cout << "PASS fault injection scenarios=9\n";
  } catch (const std::exception &error) {
    std::cerr << "FAIL: " << error.what() << '\n';
    return 1;
  }
}
