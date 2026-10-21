#include "phantrix_ovpn_support.h"

#include <cstdio>
#include <string>
#include <vector>

using namespace phantrix::ovpn;

namespace {

void Append(std::vector<uint8_t>* bytes, uint32_t value) {
  const uint8_t* data = reinterpret_cast<const uint8_t*>(&value);
  bytes->insert(bytes->end(), data, data + sizeof(value));
}

std::vector<uint8_t> Frame(uint16_t version, uint16_t type,
                           const std::vector<std::string>& fields,
                           bool trailingByte = false) {
  std::vector<uint8_t> payload;
  Append(&payload, static_cast<uint32_t>(fields.size()));
  for (const std::string& field : fields) {
    Append(&payload, static_cast<uint32_t>(field.size()));
    payload.insert(payload.end(), field.begin(), field.end());
  }
  if (trailingByte) {
    payload.push_back(0);
  }

  std::vector<uint8_t> frame;
  Append(&frame, kMessageMagic);
  frame.push_back(static_cast<uint8_t>(version));
  frame.push_back(static_cast<uint8_t>(version >> 8));
  frame.push_back(static_cast<uint8_t>(type));
  frame.push_back(static_cast<uint8_t>(type >> 8));
  Append(&frame, static_cast<uint32_t>(payload.size()));
  frame.insert(frame.end(), payload.begin(), payload.end());
  return frame;
}

bool Expect(bool condition, const char* label) {
  if (!condition) {
    std::fprintf(stderr, "FAIL: %s\n", label);
    return false;
  }
  return true;
}

bool TestProfilePolicy() {
  const std::string safe =
      "client\n"
      "dev tun\n"
      "proto udp\n"
      "remote vpn.example.net 1194\n"
      "remote-cert-tls server\n"
      "resolv-retry infinite\n"
      "nobind\n"
      "persist-key\n"
      "persist-tun\n"
      "pull-filter ignore \"redirect-gateway\"\n"
      "redirect-gateway def1 bypass-dhcp\n"
      "data-ciphers AES-256-GCM\n"
      "<ca>\n"
      "certificate-body\n"
      "</ca>\n";
  ProfileRejection rejection = {nullptr, nullptr};
  bool ok = true;
  ok &= Expect(RejectUnsafeDirectives(safe, &rejection),
               "accepts normalized safe profile");
  ok &= Expect(!RejectUnsafeDirectives(safe + "up C:\\\\payload.exe\n", &rejection),
               "rejects command execution");
  ok &= Expect(rejection.code != nullptr &&
                   std::string(rejection.code) == "ovpn.script_directive",
               "reports a stable script rejection code");
  ok &= Expect(!RejectUnsafeDirectives(safe + "ca C:\\\\private.pem\n", &rejection),
               "rejects external CA files");
  ok &= Expect(!RejectUnsafeDirectives(safe + "auth-user-pass C:\\\\auth.txt\n",
                                       &rejection),
               "rejects external credential files");
  ok &= Expect(!RejectUnsafeDirectives(safe + "auth-user-pass\n", &rejection) &&
                   std::string(rejection.code) == "ovpn.credentials_missing",
               "does not leave an unattended credential prompt hanging");
  ok &= Expect(!RejectUnsafeDirectives(safe + "unrecognized-option true\n",
                                       &rejection),
               "rejects unknown engine options");
  ok &= Expect(!RejectUnsafeDirectives(safe.substr(0, safe.find("remote-cert-tls")),
                                       &rejection),
               "requires server certificate verification");

  std::string oversized = safe;
  oversized.append(kMaxProfileBytes, ' ');
  ok &= Expect(!RejectUnsafeDirectives(oversized, &rejection) &&
                   std::string(rejection.code) == "ovpn.profile_size",
               "rejects oversized profiles instead of checking a prefix");
  return ok;
}

bool TestMessageFrames() {
  bool ok = true;
  Message message;
  auto safe = Frame(1, static_cast<uint16_t>(MessageType::kState),
                    {"connected", "123"});
  auto partial = safe;
  partial.pop_back();
  ok &= Expect(!TakeMessage(&partial, &message) && !partial.empty(),
               "retains an incomplete frame");
  safe.push_back(0x55);
  ok &= Expect(TakeMessage(&safe, &message) &&
                   message.type == MessageType::kState &&
                   message.fields == std::vector<std::string>{"connected", "123"} &&
                   safe.size() == 1,
               "reads one frame and preserves following bytes");

  auto wrongVersion = Frame(2, static_cast<uint16_t>(MessageType::kState), {});
  ok &= Expect(!TakeMessage(&wrongVersion, &message) && wrongVersion.empty(),
               "rejects unknown frame versions");
  auto trailing = Frame(1, static_cast<uint16_t>(MessageType::kState), {}, true);
  ok &= Expect(!TakeMessage(&trailing, &message) && trailing.empty(),
               "rejects unparsed trailing frame payload");
  return ok;
}

bool TestSessionFileLocks() {
  wchar_t current[MAX_PATH] = {};
  const DWORD length = GetCurrentDirectoryW(MAX_PATH, current);
  if (length == 0 || length >= MAX_PATH) {
    return Expect(false, "can locate workspace for file-lock tests");
  }
  const std::wstring root =
      std::wstring(current) + L"\\build\\support-test-" + RandomToken();
  const std::wstring app = root + L"\\app";
  const std::wstring vpn = app + L"\\openvpn";
  const std::wstring session = vpn + L"\\session";
  bool ok = true;
  for (const auto& directory : {root, app, vpn, session}) {
    ok &= Expect(CreateDirectoryW(directory.c_str(), nullptr) != FALSE,
                 "creates a disposable test directory inside the build tree");
  }
  if (!ok) {
    RemoveTree(root);
    return false;
  }
  const std::wstring profile = session + L"\\phantrix.ovpn";
  const std::wstring status = session + L"\\status.txt";
  const std::wstring log = session + L"\\openvpn.log";
  const std::string safe =
      "client\ndev tun\nremote vpn.example.net 1194\n"
      "remote-cert-tls server\n<ca>\ncertificate-body\n</ca>\n";
  ok &= Expect(WriteRestrictedFile(profile, safe), "writes a test profile");
  ProfileRejection rejection = {};
  LockedSessionFiles files;
  ok &= Expect(files.Open(session, profile, status, log, &rejection),
               "locks exact session files and reads the whole profile");
  HANDLE writer = CreateFileW(profile.c_str(), GENERIC_WRITE,
                              FILE_SHARE_READ | FILE_SHARE_WRITE,
                              nullptr, OPEN_EXISTING, 0, nullptr);
  ok &= Expect(writer == INVALID_HANDLE_VALUE,
               "prevents replacing validated profile contents");
  if (writer != INVALID_HANDLE_VALUE) {
    CloseHandle(writer);
  }
  ok &= Expect(DeleteFileW(profile.c_str()) == FALSE,
               "prevents swapping the validated profile file");
  files.Close();
  ok &= Expect(!files.Open(session, profile, session + L"\\..\\status.txt",
                           log, &rejection),
               "rejects traversal even with a session path prefix");
  ok &= Expect(WriteRestrictedFile(
                   profile, safe + std::string(kMaxProfileBytes, ' ') + "\nup bad\n"),
               "writes an oversized test profile");
  ok &= Expect(!files.Open(session, profile, status, log, &rejection) &&
                   std::string(rejection.code) == "ovpn.profile_size",
               "rejects a malicious tail beyond the old read buffer");
  files.Close();
  ok &= Expect(RemoveTree(root), "cleans disposable test files");
  return ok;
}

}  // namespace

int main() {
  const bool ok =
      TestProfilePolicy() && TestMessageFrames() && TestSessionFileLocks();
  if (ok) {
    std::puts("Windows tunnel support tests passed.");
  }
  return ok ? 0 : 1;
}
