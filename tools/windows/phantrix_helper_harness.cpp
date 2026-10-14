// Drives the real Phantrix Windows OpenVPN helper over the real named-pipe
// protocol, with no Flutter app and no UAC.
//
// What it proves
//
// It is the plugin's client side, reproduced exactly: create the pipe with the
// plugin's own security descriptor, launch `phantrix_ovpn_helper.exe`, wait for
// the connection, echo the session token, send a start request with three paths
// inside the session directory, then read every message the helper sends until
// it reports a teardown or goes away. That exercises the whole native path —
// pipe framing, token authentication, the profile re-check, adapter creation,
// engine launch, state classification, and shutdown — against the real binary.
//
// Why it is needed
//
// The helper carries a `requireAdministrator` manifest, so an unelevated process
// cannot launch the shipped one, and a tunnel cannot be created without an
// administrator token. This harness runs the *same source* compiled without
// that manifest, which is what makes every layer short of the actual adapter
// creation observable and repeatable on a machine where UAC cannot be answered
// non-interactively.
//
// Usage
//
//   helper_harness.exe <helper.exe> <profile.ovpn> [--expect-reject <code>]
//
// It never prints profile contents. Session paths, error codes and engine state
// labels are printed verbatim; the engine's own log is written to the session
// directory and only its size is reported.
#include <windows.h>

#include <aclapi.h>
#include <sddl.h>

#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

#pragma comment(lib, "advapi32.lib")

namespace {

constexpr uint32_t kMessageMagic = 0x54475456;  // 'VTGT'
enum class MessageType : uint16_t {
  kStart = 1,
  kStarted = 2,
  kState = 3,
  kTraffic = 4,
  kFailed = 5,
  kExited = 6,
  kStop = 7,
  kDisconnected = 8,
  kShutdown = 9,
  kHello = 10,
};

const wchar_t kPipePrefix[] = L"\\\\.\\pipe\\PhantrixTunnel-";
const wchar_t kMediumIntegritySid[] = L"S-1-16-8192";

struct Message {
  MessageType type = MessageType::kShutdown;
  std::vector<std::string> fields;
};

std::wstring utf8ToWide(const std::string& value) {
  if (value.empty()) return std::wstring();
  const int needed =
      MultiByteToWideChar(CP_UTF8, 0, value.c_str(), -1, nullptr, 0);
  std::wstring wide(static_cast<size_t>(needed), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, value.c_str(), -1, &wide[0], needed);
  wide.resize(static_cast<size_t>(needed - 1));
  return wide;
}

std::string wideToUtf8(const std::wstring& value) {
  if (value.empty()) return std::string();
  const int needed =
      WideCharToMultiByte(CP_UTF8, 0, value.c_str(), -1, nullptr, 0, nullptr, nullptr);
  std::string narrow(static_cast<size_t>(needed), '\0');
  WideCharToMultiByte(CP_UTF8, 0, value.c_str(), -1, &narrow[0], needed, nullptr, nullptr);
  narrow.resize(static_cast<size_t>(needed - 1));
  return narrow;
}

// A random 128-bit token, the same way the plugin makes one.
std::wstring randomToken() {
  std::wstring token;
  for (int i = 0; i < 4; ++i) {
    wchar_t buffer[9] = {0};
    swprintf_s(buffer, 9, L"%08x", static_cast<unsigned>(rand() * 32768 + rand()));
    token += buffer;
  }
  return token;
}

void appendField(std::vector<uint8_t>* out, const std::string& field) {
  uint32_t length = static_cast<uint32_t>(field.size());
  out->insert(out->end(), reinterpret_cast<uint8_t*>(&length),
              reinterpret_cast<uint8_t*>(&length) + sizeof(length));
  out->insert(out->end(), field.begin(), field.end());
}

bool writeMessage(HANDLE pipe, const Message& message) {
  std::vector<uint8_t> payload;
  uint32_t count = static_cast<uint32_t>(message.fields.size());
  payload.insert(payload.end(), reinterpret_cast<uint8_t*>(&count),
                 reinterpret_cast<uint8_t*>(&count) + sizeof(count));
  for (const auto& field : message.fields) appendField(&payload, field);
  uint8_t header[12] = {0};
  const uint16_t version = 1;
  const uint16_t type = static_cast<uint16_t>(message.type);
  memcpy(header + 0, &kMessageMagic, 4);
  memcpy(header + 4, &version, 2);
  memcpy(header + 6, &type, 2);
  const uint32_t length = static_cast<uint32_t>(payload.size());
  memcpy(header + 8, &length, 4);
  DWORD written = 0;
  if (!WriteFile(pipe, header, sizeof(header), &written, nullptr)) return false;
  if (!payload.empty() &&
      !WriteFile(pipe, payload.data(), static_cast<DWORD>(payload.size()), &written, nullptr)) {
    return false;
  }
  return true;
}

bool takeMessage(std::vector<uint8_t>* carry, Message* message) {
  if (carry->size() < 12) return false;
  uint32_t magic = 0;
  memcpy(&magic, carry->data(), 4);
  if (magic != kMessageMagic) {
    carry->clear();
    return false;
  }
  uint32_t payloadLength = 0;
  memcpy(&payloadLength, carry->data() + 8, 4);
  if (payloadLength > 64 * 1024) {
    carry->clear();
    return false;
  }
  const size_t total = 12 + payloadLength;
  if (carry->size() < total) return false;
  uint16_t type = 0;
  memcpy(&type, carry->data() + 6, 2);
  message->type = static_cast<MessageType>(type);
  message->fields.clear();
  size_t cursor = 12;
  if (payloadLength >= 4) {
    uint32_t count = 0;
    memcpy(&count, &(*carry)[cursor], 4);
    cursor += 4;
    for (uint32_t i = 0; i < count && cursor + 4 <= total; ++i) {
      uint32_t length = 0;
      memcpy(&length, &(*carry)[cursor], 4);
      cursor += 4;
      if (cursor + length > total) break;
      message->fields.emplace_back(reinterpret_cast<const char*>(&(*carry)[cursor]), length);
      cursor += length;
    }
  }
  carry->erase(carry->begin(), carry->begin() + total);
  return true;
}

bool createSessionDirectory(const std::wstring& path) {
  if (!CreateDirectoryW(path.c_str(), nullptr) && GetLastError() != ERROR_ALREADY_EXISTS) {
    return false;
  }
  return true;
}

void removeTree(const std::wstring& path) {
  const std::wstring search = path + L"\\*";
  WIN32_FIND_DATAW entry = {0};
  HANDLE find = FindFirstFileW(search.c_str(), &entry);
  if (find == INVALID_HANDLE_VALUE) {
    RemoveDirectoryW(path.c_str());
    return;
  }
  do {
    const wchar_t* name = entry.cFileName;
    if (wcscmp(name, L".") == 0 || wcscmp(name, L"..") == 0) continue;
    const std::wstring child = path + L"\\" + name;
    if ((entry.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) {
      removeTree(child);
    } else {
      DeleteFileW(child.c_str());
    }
  } while (FindNextFileW(find, &entry));
  FindClose(find);
  RemoveDirectoryW(path.c_str());
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
  if (argc < 3) {
    printf("usage: helper_harness.exe <helper.exe> <profile.ovpn> [--expect-reject <code>]\n");
    return 2;
  }
  const std::wstring helper = argv[1];
  const std::wstring profile = argv[2];
  std::string expectedReject;
  for (int i = 3; i < argc; ++i) {
    if (wcscmp(argv[i], L"--expect-reject") == 0 && i + 1 < argc) {
      expectedReject = wideToUtf8(argv[++i]);
    }
  }

  // The plugin's own security descriptor: current user + LocalSystem, with a
  // Medium mandatory label.
  std::wstring descriptor = L"D:P(A;;GA;;;SY)(A;;GA;;;";
  {
    HANDLE token = nullptr;
    OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token);
    DWORD length = 0;
    GetTokenInformation(token, TokenUser, nullptr, 0, &length);
    std::vector<BYTE> buffer(length);
    GetTokenInformation(token, TokenUser,
                        reinterpret_cast<TOKEN_USER*>(buffer.data()), length, &length);
    CloseHandle(token);
    LPWSTR sidText = nullptr;
    ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER*>(buffer.data())->User.Sid,
                           &sidText);
    if (sidText == nullptr) {
      printf("FAIL could not build the pipe's security descriptor\n");
      return 1;
    }
    descriptor += sidText;
    LocalFree(sidText);
  }
  descriptor += L")S:(ML;;NW;;;";
  descriptor += kMediumIntegritySid;
  descriptor += L")";

  PSECURITY_DESCRIPTOR security = nullptr;
  if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
          descriptor.c_str(), SDDL_REVISION_1, &security, nullptr)) {
    printf("FAIL security descriptor rejected\n");
    return 1;
  }

  const std::wstring token = randomToken();
  const std::wstring pipeName = std::wstring(kPipePrefix) + token;

  SECURITY_ATTRIBUTES attributes = {0};
  attributes.nLength = sizeof(attributes);
  attributes.lpSecurityDescriptor = security;
  attributes.bInheritHandle = FALSE;
  HANDLE pipe = CreateNamedPipeW(
      pipeName.c_str(), PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED,
      PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT, 1, 64 * 1024, 64 * 1024,
      0, &attributes);
  LocalFree(security);
  if (pipe == INVALID_HANDLE_VALUE) {
    printf("FAIL CreateNamedPipeW error=%lu\n", GetLastError());
    return 1;
  }

  // The session directory the helper insists the three paths live inside.
  wchar_t localAppData[MAX_PATH] = {0};
  GetEnvironmentVariableW(L"LOCALAPPDATA", localAppData, MAX_PATH);
  const std::wstring root = std::wstring(localAppData) + L"\\Phantrix\\openvpn";
  CreateDirectoryW((std::wstring(localAppData) + L"\\Phantrix").c_str(), nullptr);
  CreateDirectoryW(root.c_str(), nullptr);
  const std::wstring session = root + L"\\session-" + token;
  if (!createSessionDirectory(session)) {
    printf("FAIL session directory: %lu\n", GetLastError());
    return 1;
  }
  const std::wstring sessionProfile = session + L"\\phantrix.ovpn";
  const std::wstring sessionStatus = session + L"\\status.txt";
  const std::wstring sessionLog = session + L"\\openvpn.log";
  CopyFileW(profile.c_str(), sessionProfile.c_str(), FALSE);

  std::wstring parameters = std::wstring(L"--pipe \"") + pipeName +
                            L"\" --token \"" + token + L"\" --parent \"" +
                            std::to_wstring(GetCurrentProcessId()) + L"\"";

  printf("launching helper with a %s\n",
         wideToUtf8(parameters).c_str());
  SHELLEXECUTEINFOW execute = {0};
  execute.cbSize = sizeof(execute);
  execute.fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC;
  execute.hwnd = nullptr;
  execute.lpVerb = L"open";  // No elevation: this binary is built without a manifest.
  execute.lpFile = helper.c_str();
  execute.lpParameters = parameters.c_str();
  execute.nShow = SW_HIDE;
  if (!ShellExecuteExW(&execute)) {
    printf("FAIL ShellExecuteExW error=%lu\n", GetLastError());
    removeTree(session);
    return 1;
  }
  HANDLE helperProcess = execute.hProcess;

  HANDLE connectedEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  OVERLAPPED overlap = {0};
  overlap.hEvent = connectedEvent;
  if (ConnectNamedPipe(pipe, &overlap) == FALSE) {
    const DWORD error = GetLastError();
    if (error == ERROR_IO_PENDING) {
      if (WaitForSingleObject(connectedEvent, 90000) != WAIT_OBJECT_0) {
        printf("FAIL helper never connected\n");
        CloseHandle(connectedEvent);
        return 1;
      }
    } else if (error != ERROR_PIPE_CONNECTED) {
      printf("FAIL ConnectNamedPipe error=%lu\n", error);
      CloseHandle(connectedEvent);
      return 1;
    }
  }
  CloseHandle(connectedEvent);
  printf("helper connected\n");

  if (!writeMessage(pipe, Message{MessageType::kHello, {wideToUtf8(token)}})) {
    printf("FAIL could not write the hello message\n");
    return 1;
  }
  printf("hello sent\n");
  if (!writeMessage(pipe,
                    Message{MessageType::kStart,
                            {wideToUtf8(sessionProfile), wideToUtf8(sessionStatus),
                             wideToUtf8(sessionLog)}})) {
    printf("FAIL could not write the start message\n");
    return 1;
  }
  printf("start sent\n");

  // Read until the helper reports an outcome, goes away, or the budget runs out.
  const DWORD deadline = GetTickCount() + 120000;
  std::vector<uint8_t> carry;
  std::string lastState;
  std::string failureCode;
  std::string failureMessage;
  bool disconnected = false;
  int trafficEvents = 0;
  while (!disconnected && GetTickCount() < deadline) {
    uint8_t buffer[4096] = {0};
    DWORD read = 0;
    const BOOL ok = ReadFile(pipe, buffer, sizeof(buffer), &read, nullptr);
    if (ok == FALSE || read == 0) break;
    carry.insert(carry.end(), buffer, buffer + read);
    Message message;
    while (takeMessage(&carry, &message)) {
      switch (message.type) {
        case MessageType::kStarted:
          printf("event: started (the engine process is running)\n");
          break;
        case MessageType::kState: {
          lastState = message.fields.empty() ? "" : message.fields[0];
          const std::string when =
              message.fields.size() > 1 ? message.fields[1] : "";
          printf("event: state=%s handshakeAtMillis=%s\n", lastState.c_str(), when.c_str());
          break;
        }
        case MessageType::kTraffic:
          ++trafficEvents;
          printf("event: traffic rx=%s tx=%s\n",
                 message.fields.size() > 0 ? message.fields[0].c_str() : "?",
                 message.fields.size() > 1 ? message.fields[1].c_str() : "?");
          break;
        case MessageType::kFailed:
          failureCode = message.fields.empty() ? "" : message.fields[0];
          failureMessage = message.fields.size() > 1 ? message.fields[1] : "";
          printf("event: failed code=%s message=%s\n", failureCode.c_str(),
                 failureMessage.c_str());
          break;
        case MessageType::kDisconnected:
          disconnected = true;
          printf("event: disconnected\n");
          break;
        default:
          printf("event: type=%u\n", static_cast<unsigned>(message.type));
          break;
      }
    }
    if (!failureCode.empty() || disconnected) break;
  }

  if (!failureCode.empty()) {
    printf("RESULT: helper reported %s)", failureCode.c_str());
  }
  if (disconnected) {
    printf("RESULT: teardown complete\n");
  } else if (failureCode.empty()) {
    printf("RESULT: no outcome within the budget\n");
  }

  // Ask for a stop either way, so the engine is not left behind.
  writeMessage(pipe, Message{MessageType::kStop, {}});
  Sleep(2000);
  CancelIo(pipe);
  CloseHandle(pipe);
  if (WaitForSingleObject(helperProcess, 20000) != WAIT_OBJECT_0) {
    TerminateProcess(helperProcess, 1);
    printf("helper had to be terminated\n");
  }
  DWORD exitCode = 0;
  GetExitCodeProcess(helperProcess, &exitCode);
  CloseHandle(helperProcess);
  printf("helper exit code: %lu\n", exitCode);

  if (GetFileAttributesW(sessionLog.c_str()) != INVALID_FILE_ATTRIBUTES) {
    WIN32_FILE_ATTRIBUTE_DATA info = {0};
    GetFileAttributesExW(sessionLog.c_str(), GetFileExInfoStandard, &info);
    printf("engine log size: %lu bytes\n", info.nFileSizeLow);
  } else {
    printf("engine log size: none\n");
  }
  printf("traffic events: %d\n", trafficEvents);
  printf("last engine state: %s\n", lastState.empty() ? "(none)" : lastState.c_str());

  if (!expectedReject.empty()) {
    if (failureCode == expectedReject) {
      printf("EXPECT: reject %s -> observed\n", expectedReject.c_str());
    } else {
      printf("EXPECT: reject %s -> NOT observed (got %s)\n", expectedReject.c_str(),
             failureCode.empty() ? "(nothing)" : failureCode.c_str());
    }
  }
  removeTree(session);
  return 0;
}
