#include "nelisp_ime_client.hpp"

#include <cerrno>
#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <stdexcept>
#include <string_view>

#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#else
#include <csignal>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#endif

namespace nelisp_ime {
namespace {

#ifdef _WIN32
std::wstring windowsWide(std::string_view value) {
  if (value.empty()) return {};
  int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                                 static_cast<int>(value.size()), nullptr, 0);
  if (!size) throw std::runtime_error("invalid UTF-8 Windows path");
  std::wstring out(static_cast<size_t>(size), L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                      static_cast<int>(value.size()), out.data(), size);
  return out;
}
#endif

std::string jsonQuote(std::string_view value) {
  std::string out = "\"";
  static const char hex[] = "0123456789abcdef";
  for (unsigned char c : value) {
    switch (c) {
    case '\"': out += "\\\""; break;
    case '\\': out += "\\\\"; break;
    case '\b': out += "\\b"; break;
    case '\f': out += "\\f"; break;
    case '\n': out += "\\n"; break;
    case '\r': out += "\\r"; break;
    case '\t': out += "\\t"; break;
    default:
      if (c < 0x20) {
        out += "\\u00";
        out += hex[c >> 4];
        out += hex[c & 15];
      } else {
        out += static_cast<char>(c);
      }
    }
  }
  return out + "\"";
}

std::string lispQuote(std::string_view value) {
  std::string out = "\"";
  for (char c : value) {
    if (c == '\\' || c == '\"') out += '\\';
    if (c == '\n') out += "\\n";
    else if (c == '\r') out += "\\r";
    else out += c;
  }
  return out + "\"";
}

void appendUtf8(std::string &out, uint32_t cp) {
  if (cp <= 0x7f) out += static_cast<char>(cp);
  else if (cp <= 0x7ff) {
    out += static_cast<char>(0xc0 | (cp >> 6));
    out += static_cast<char>(0x80 | (cp & 0x3f));
  } else if (cp <= 0xffff) {
    out += static_cast<char>(0xe0 | (cp >> 12));
    out += static_cast<char>(0x80 | ((cp >> 6) & 0x3f));
    out += static_cast<char>(0x80 | (cp & 0x3f));
  } else {
    out += static_cast<char>(0xf0 | (cp >> 18));
    out += static_cast<char>(0x80 | ((cp >> 12) & 0x3f));
    out += static_cast<char>(0x80 | ((cp >> 6) & 0x3f));
    out += static_cast<char>(0x80 | (cp & 0x3f));
  }
}

int hexValue(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  throw std::runtime_error("invalid JSON unicode escape");
}

std::string parseString(const std::string &json, size_t &at) {
  if (at >= json.size() || json[at++] != '\"')
    throw std::runtime_error("expected JSON string");
  std::string out;
  while (at < json.size()) {
    char c = json[at++];
    if (c == '\"') return out;
    if (c != '\\') { out += c; continue; }
    if (at >= json.size()) throw std::runtime_error("truncated JSON escape");
    c = json[at++];
    switch (c) {
    case '\"': case '\\': case '/': out += c; break;
    case 'b': out += '\b'; break;
    case 'f': out += '\f'; break;
    case 'n': out += '\n'; break;
    case 'r': out += '\r'; break;
    case 't': out += '\t'; break;
    case 'u': {
      if (at + 4 > json.size()) throw std::runtime_error("truncated unicode escape");
      uint32_t cp = 0;
      for (int i = 0; i < 4; ++i) cp = cp * 16 + hexValue(json[at++]);
      if (cp >= 0xd800 && cp <= 0xdbff && at + 6 <= json.size() &&
          json[at] == '\\' && json[at + 1] == 'u') {
        at += 2;
        uint32_t low = 0;
        for (int i = 0; i < 4; ++i) low = low * 16 + hexValue(json[at++]);
        if (low >= 0xdc00 && low <= 0xdfff)
          cp = 0x10000 + ((cp - 0xd800) << 10) + (low - 0xdc00);
      }
      appendUtf8(out, cp);
      break;
    }
    default: throw std::runtime_error("invalid JSON escape");
    }
  }
  throw std::runtime_error("unterminated JSON string");
}

size_t valueAt(const std::string &json, std::string_view key) {
  int depth = 0;
  size_t at = 0;
  while (at < json.size()) {
    if (json[at] == '{' || json[at] == '[') { ++depth; ++at; continue; }
    if (json[at] == '}' || json[at] == ']') { --depth; ++at; continue; }
    if (json[at] != '\"') { ++at; continue; }
    size_t start = at;
    std::string candidate = parseString(json, at);
    if ((depth != 1 && depth != 2) || candidate != key) continue;
    while (at < json.size() && (json[at] == ' ' || json[at] == '\t')) ++at;
    if (at >= json.size() || json[at] != ':') { at = start + 1; continue; }
    do { ++at; } while (at < json.size() &&
                        (json[at] == ' ' || json[at] == '\t' || json[at] == '\n'));
    return at;
  }
  return std::string::npos;
}

std::string stringField(const std::string &json, std::string_view key) {
  size_t at = valueAt(json, key);
  if (at == std::string::npos || json.compare(at, 4, "null") == 0) return {};
  return parseString(json, at);
}

int intField(const std::string &json, std::string_view key) {
  size_t at = valueAt(json, key);
  if (at == std::string::npos) return 0;
  return std::stoi(json.substr(at));
}

std::vector<std::string> stringArrayField(const std::string &json,
                                          std::string_view key) {
  size_t at = valueAt(json, key);
  std::vector<std::string> out;
  if (at == std::string::npos || json.compare(at, 4, "null") == 0) return out;
  if (json[at++] != '[')
    throw std::runtime_error("expected JSON array near: " + json.substr(at - 1, 40));
  while (at < json.size()) {
    while (at < json.size() && (json[at] == ' ' || json[at] == ',')) ++at;
    if (at < json.size() && json[at] == ']') return out;
    out.push_back(parseString(json, at));
  }
  throw std::runtime_error("unterminated JSON array");
}

std::string rawValueField(const std::string &json, std::string_view key) {
  size_t at = valueAt(json, key);
  if (at == std::string::npos) throw std::runtime_error("missing JSON field");
  size_t start = at;
  if (json[at] != '[' && json[at] != '{')
    throw std::runtime_error("expected structured JSON value");
  char open = json[at], close = open == '[' ? ']' : '}';
  int depth = 0; bool inString = false, escaped = false;
  for (; at < json.size(); ++at) {
    char c = json[at];
    if (inString) {
      if (escaped) escaped = false;
      else if (c == '\\') escaped = true;
      else if (c == '\"') inString = false;
      continue;
    }
    if (c == '\"') inString = true;
    else if (c == open) ++depth;
    else if (c == close && --depth == 0) return json.substr(start, at - start + 1);
  }
  throw std::runtime_error("unterminated structured JSON value");
}

Snapshot snapshotFromJson(const std::string &json) {
  if (valueAt(json, "error") != std::string::npos)
    throw std::runtime_error("NeLisp IME error: " + stringField(json, "message"));
  Snapshot out;
  out.consumed = json.compare(valueAt(json, "consumed"), 4, "true") == 0;
  out.reading = stringField(json, "reading");
  out.preedit = stringField(json, "preedit");
  out.commit = stringField(json, "commit");
  out.candidates = stringArrayField(json, "candidates");
  out.candidateIndex = intField(json, "candidate-index");
  out.activeSegment = intField(json, "active-segment");
  std::string segments = rawValueField(json, "segments");
  int depth = 0; bool inString = false, escaped = false;
  for (char c : segments) {
    if (inString) {
      if (escaped) escaped = false;
      else if (c == '\\') escaped = true;
      else if (c == '\"') inString = false;
    } else if (c == '\"') inString = true;
    else if (c == '{' && depth++ == 0) ++out.segmentCount;
    else if (c == '}' && depth > 0) --depth;
  }
  return out;
}

} // namespace

class Client::Process {
public:
  ~Process() { stop(); }
  void start(const std::string &runtime) {
#ifdef _WIN32
    SECURITY_ATTRIBUTES sa{sizeof(sa), nullptr, TRUE};
    HANDLE childInRead = nullptr, childOutWrite = nullptr;
    if (!CreatePipe(&childOutRead_, &childOutWrite, &sa, 0) ||
        !SetHandleInformation(childOutRead_, HANDLE_FLAG_INHERIT, 0) ||
        !CreatePipe(&childInRead, &childInWrite_, &sa, 0) ||
        !SetHandleInformation(childInWrite_, HANDLE_FLAG_INHERIT, 0))
      throw std::runtime_error("CreatePipe failed");
    STARTUPINFOW si{}; si.cb = sizeof(si); si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput = childInRead; si.hStdOutput = childOutWrite;
    si.hStdError = GetStdHandle(STD_ERROR_HANDLE);
    PROCESS_INFORMATION pi{};
    std::wstring command = L"\"" + windowsWide(runtime) +
                           L"\" --repl --no-prompt --no-print";
    if (!CreateProcessW(nullptr, command.data(), nullptr, nullptr, TRUE,
                        CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi))
      throw std::runtime_error("CreateProcess failed");
    CloseHandle(childInRead); CloseHandle(childOutWrite); CloseHandle(pi.hThread);
    process_ = pi.hProcess;
#else
    int input[2], output[2];
    if (pipe(input) || pipe(output)) throw std::runtime_error("pipe failed");
    pid_ = fork();
    if (pid_ < 0) throw std::runtime_error("fork failed");
    if (pid_ == 0) {
      dup2(input[0], STDIN_FILENO); dup2(output[1], STDOUT_FILENO);
      close(input[0]); close(input[1]); close(output[0]); close(output[1]);
      execl(runtime.c_str(), runtime.c_str(), "--repl", "--no-prompt",
            "--no-print", static_cast<char *>(nullptr));
      _exit(127);
    }
    close(input[0]); close(output[1]); input_ = input[1]; output_ = output[0];
#endif
  }
  void writeLine(const std::string &line) {
    std::string data = line + "\n"; size_t done = 0;
    while (done < data.size()) {
#ifdef _WIN32
      DWORD written = 0;
      if (!WriteFile(childInWrite_, data.data() + done,
                     static_cast<DWORD>(data.size() - done), &written, nullptr))
        throw std::runtime_error("write to NeLisp failed");
#else
      ssize_t written = ::write(input_, data.data() + done, data.size() - done);
      if (written < 0 && errno == EINTR) continue;
      if (written <= 0) throw std::runtime_error("write to NeLisp failed");
#endif
      done += static_cast<size_t>(written);
    }
  }
  std::string readLine() {
    std::string line; char c;
    while (true) {
#ifdef _WIN32
      DWORD count = 0;
      if (!ReadFile(childOutRead_, &c, 1, &count, nullptr) || count == 0)
        throw std::runtime_error("NeLisp exited");
#else
      ssize_t count = ::read(output_, &c, 1);
      if (count < 0 && errno == EINTR) continue;
      if (count <= 0) throw std::runtime_error("NeLisp exited");
#endif
      if (c == '\n') return line;
      line += c;
    }
  }
private:
  void stop() {
#ifdef _WIN32
    if (childInWrite_) CloseHandle(childInWrite_);
    if (childOutRead_) CloseHandle(childOutRead_);
    if (process_) {
      if (WaitForSingleObject(process_, 1000) == WAIT_TIMEOUT) {
        TerminateProcess(process_, 0);
        WaitForSingleObject(process_, 1000);
      }
      CloseHandle(process_);
    }
    childInWrite_ = childOutRead_ = process_ = nullptr;
#else
    if (input_ >= 0) close(input_);
    if (output_ >= 0) close(output_);
    if (pid_ > 0) { kill(pid_, SIGTERM); waitpid(pid_, nullptr, 0); }
    input_ = output_ = -1; pid_ = -1;
#endif
  }
#ifdef _WIN32
  HANDLE childInWrite_ = nullptr, childOutRead_ = nullptr, process_ = nullptr;
#else
  int input_ = -1, output_ = -1; pid_t pid_ = -1;
#endif
};

Client::Client(std::string runtime, std::string resourceRoot)
    : process_(std::make_unique<Process>()), runtime_(std::move(runtime)),
      root_(std::move(resourceRoot)) {}
Client::~Client() = default;

void Client::start() {
  process_->start(runtime_);
  const std::vector<std::string> files = {
      "packages/nelisp-json/src/nelisp-json.el",
      "packages/nelisp-ime/src/nelisp-ime-input.el",
      "packages/nelisp-ime/src/nelisp-ime.el",
      "packages/nelisp-ime/data/nelisp-ime-dictionary-data.el",
      "packages/nelisp-ime/src/nelisp-ime-protocol.el"};
  std::string form = "(progn ";
  for (const auto &file : files) form += "(load " + lispQuote(root_ + "/" + file) + ") ";
  form += "(princ \"ready\\n\"))";
  process_->writeLine(form);
  if (process_->readLine() != "ready") throw std::runtime_error("NeLisp bootstrap failed");
  request("ime/initialize", "{\"protocolVersion\":1}");
}

std::string Client::request(const std::string &method, const std::string &params) {
  std::string json = "{\"jsonrpc\":\"2.0\",\"id\":" +
      std::to_string(requestId_++) + ",\"method\":" + jsonQuote(method) +
      ",\"params\":" + params + "}";
  process_->writeLine("(princ (concat (nelisp-ime-protocol-handle-json " +
                      lispQuote(json) + ") \"\\n\"))");
  std::string response = process_->readLine();
  if (valueAt(response, "error") != std::string::npos)
    throw std::runtime_error("NeLisp IME error: " + stringField(response, "message"));
  return response;
}

void Client::openSession(const std::string &id, const std::string &style) {
  request("ime/session.open", "{\"sessionId\":" + jsonQuote(id) +
          ",\"inputStyle\":" + jsonQuote(style) + "}");
}
void Client::closeSession(const std::string &id) {
  request("ime/session.close", "{\"sessionId\":" + jsonQuote(id) + "}");
}
Snapshot Client::feedKey(const std::string &id, const std::string &key) {
  return snapshotFromJson(request("ime/session.feed", "{\"sessionId\":" +
      jsonQuote(id) + ",\"event\":{\"op\":\"key\",\"key\":" +
      jsonQuote(key) + "}}"));
}
Snapshot Client::feedOperation(const std::string &id, const std::string &op,
                               int index) {
  std::string event = "{\"op\":" + jsonQuote(op);
  if (index >= 0) event += ",\"index\":" + std::to_string(index);
  event += "}";
  return snapshotFromJson(request("ime/session.feed", "{\"sessionId\":" +
      jsonQuote(id) + ",\"event\":" + event + "}"));
}

void Client::loadLearning(const std::string &file) {
  std::ifstream stream(file, std::ios::binary);
  if (!stream) return;
  std::ostringstream buffer; buffer << stream.rdbuf();
  std::string rows = buffer.str();
  size_t first = rows.find_first_not_of(" \t\r\n");
  if (first == std::string::npos || rows[first] != '[')
    throw std::runtime_error("invalid learning JSON");
  request("ime/learning.import", "{\"rows\":" + rows.substr(first) + "}");
}

void Client::saveLearning(const std::string &file) {
  std::string rows = rawValueField(request("ime/learning.export", "{}"), "rows");
  std::filesystem::path path(file);
  if (path.has_parent_path()) std::filesystem::create_directories(path.parent_path());
  std::filesystem::path temporary = path; temporary += ".tmp";
  { std::ofstream stream(temporary, std::ios::binary | std::ios::trunc);
    if (!stream || !(stream << rows << '\n')) throw std::runtime_error("learning write failed"); }
#ifdef _WIN32
  if (!MoveFileExW(temporary.c_str(), path.c_str(),
                   MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
    throw std::runtime_error("learning rename failed");
#else
  std::error_code error;
  std::filesystem::rename(temporary, path, error);
  if (error) throw std::runtime_error("learning rename failed");
#endif
}

} // namespace nelisp_ime
