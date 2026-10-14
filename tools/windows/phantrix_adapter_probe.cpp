// Creates a Wintun adapter through the bundled `wintun.dll` and then applies the
// registration the helper applies, so the effect on OpenVPN's adapter
// enumeration can be observed from the same machine without elevation.
//
// The engine decides which adapters exist by reading `ComponentId` from each
// subkey of `HKLM\SYSTEM\CurrentControlSet\Control\Class\{4D36E972-…}`; a subkey
// without the value is skipped, and an empty list is `at_least_one_tap_win`'s
// M_FATAL. This tool therefore answers the one question the code analysis
// cannot: whether writing that value is sufficient, and whether restoring it
// returns the machine to exactly the state it started in.
//
// Run elevated (it needs Administrator to create the adapter):
//   phantrix_helper_harness.exe --probe <wintun.dll> <engineDir> <profile.ovpn>
//
// With --probe it performs the same registration the helper does and then
// launches the bundled openvpn.exe, so the engine's own verdict can be read
// from the log it writes.
#include <windows.h>

#include <iphlpapi.h>
#include <objbase.h>

#include <cstdio>
#include <string>

#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "iphlpapi.lib")
#pragma comment(lib, "ole32.lib")

namespace {

constexpr wchar_t kAdapterName[] = L"Phantrix";
constexpr wchar_t kComponentIdValue[] = L"wintun";
constexpr wchar_t kNetClassKey[] =
    L"SYSTEM\\CurrentControlSet\\Control\\Class\\{4D36E972-E325-11CE-BFC1-"
    L"08002BE10318}";

typedef void *(WINAPI *CreateFn)(LPCWSTR, LPCWSTR, const GUID *);
typedef void *(WINAPI *OpenFn)(LPCWSTR);
typedef void(WINAPI *CloseFn)(void *);
// Real wintun.h: `void WintunGetAdapterLUID(adapter, NET_LUID*)`. A one-arg
// NET_LUID-return form makes the call write through a stale second register —
// crashing when that register is not writable, and handing the caller a garbage
// LUID (the `ConvertInterfaceLuidToGuid` failure) when it was.
typedef void(WINAPI *LuidFn)(void *, NET_LUID *);

bool ReadReg(const std::wstring& key, const wchar_t* name, std::wstring* value) {
  HKEY handle = nullptr;
  if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, key.c_str(), 0, KEY_READ, &handle) !=
      ERROR_SUCCESS) {
    return false;
  }
  wchar_t buffer[512] = {0};
  DWORD length = sizeof(buffer);
  DWORD type = 0;
  const LONG status = RegQueryValueExW(handle, name, nullptr, &type,
                                       reinterpret_cast<LPBYTE>(buffer),
                                       &length);
  RegCloseKey(handle);
  if (status != ERROR_SUCCESS || type != REG_SZ) return false;
  *value = buffer;
  return true;
}

std::wstring SubkeyFor(const std::wstring& instanceId) {
  HKEY root = nullptr;
  if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, kNetClassKey, 0, KEY_READ, &root) !=
      ERROR_SUCCESS) {
    return std::wstring();
  }
  std::wstring found;
  for (int i = 0;; ++i) {
    wchar_t name[256] = {0};
    DWORD length = 256;
    if (RegEnumKeyExW(root, i, name, &length, nullptr, nullptr, nullptr,
                      nullptr) != ERROR_SUCCESS) {
      break;
    }
    const std::wstring subkey = std::wstring(kNetClassKey) + L"\\" + name;
    std::wstring value;
    if (ReadReg(subkey, L"NetCfgInstanceId", &value) &&
        _wcsicmp(value.c_str(), instanceId.c_str()) == 0) {
      found = subkey;
      break;
    }
  }
  RegCloseKey(root);
  return found;
}

void DumpWintunEntries(const char* label) {
  printf("\n[%s] Net-class subkeys OpenVPN could match\n", label);
  HKEY root = nullptr;
  if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, kNetClassKey, 0, KEY_READ, &root) !=
      ERROR_SUCCESS) {
    printf("  (class key unreadable)\n");
    return;
  }
  int matched = 0;
  int total = 0;
  for (int i = 0;; ++i) {
    wchar_t name[256] = {0};
    DWORD length = 256;
    if (RegEnumKeyExW(root, i, name, &length, nullptr, nullptr, nullptr,
                      nullptr) != ERROR_SUCCESS) {
      break;
    }
    const std::wstring subkey = std::wstring(kNetClassKey) + L"\\" + name;
    std::wstring instance;
    if (!ReadReg(subkey, L"NetCfgInstanceId", &instance)) continue;
    ++total;
    std::wstring component;
    const bool has = ReadReg(subkey, L"ComponentId", &component);
    const bool ours = has && _wcsicmp(component.c_str(), kComponentIdValue) == 0;
    if (ours) ++matched;
    printf("  %ls instance=%ls ComponentId=%ls%s\n", name, instance.c_str(),
           has ? component.c_str() : L"(absent)", ours ? "  <-- MATCHES" : "");
  }
  RegCloseKey(root);
  printf("  %d entries with NetCfgInstanceId, %d of them ComponentId=wintun\n",
         total, matched);
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
  // Accepted forms, both documented in WINDOWS_LIVE_VERIFICATION.md:
  //   phantrix_adapter_probe.exe <wintun.dll> <engineDir> <profile.ovpn> [--run]
  //   phantrix_helper_harness.exe --probe <wintun.dll> <engineDir> <profile.ovpn> [--run]
  const bool prefixed = argc > 1 && _wcsicmp(argv[1], L"--probe") == 0;
  const int first = prefixed ? 2 : 1;
  if (argc < first + 3) {
    printf("usage: %ls [--probe] <wintun.dll> <engineDir> <profile.ovpn> [--run]\n",
           argv[0]);
    return 2;
  }
  const std::wstring dll = argv[first];
  const std::wstring engineDir = argv[first + 1];
  const std::wstring profile = argv[first + 2];
  bool runEngine = false;
  for (int i = first + 3; i < argc; ++i) {
    if (_wcsicmp(argv[i], L"--run") == 0) runEngine = true;
  }

  HMODULE module = LoadLibraryExW(dll.c_str(), nullptr, LOAD_WITH_ALTERED_SEARCH_PATH);
  if (module == nullptr) {
    printf("FAIL wintun.dll load error=%lu\n", GetLastError());
    return 1;
  }
  auto create = reinterpret_cast<CreateFn>(GetProcAddress(module, "WintunCreateAdapter"));
  auto open = reinterpret_cast<OpenFn>(GetProcAddress(module, "WintunOpenAdapter"));
  auto close = reinterpret_cast<CloseFn>(GetProcAddress(module, "WintunCloseAdapter"));
  auto luid = reinterpret_cast<LuidFn>(GetProcAddress(module, "WintunGetAdapterLUID"));
  printf("exports create=%p open=%p close=%p luid=%p\n",
         reinterpret_cast<void*>(create), reinterpret_cast<void*>(open),
         reinterpret_cast<void*>(close), reinterpret_cast<void*>(luid));
  if (create == nullptr || close == nullptr || luid == nullptr) {
    printf("FAIL missing exports\n");
    return 1;
  }

  SetLastError(0);
  void* adapter = create(kAdapterName, kAdapterName, nullptr);
  const DWORD createError = adapter == nullptr ? GetLastError() : 0;
  if (adapter == nullptr && open != nullptr) adapter = open(kAdapterName);
  if (adapter == nullptr) {
    printf("FAIL adapter create error=%lu\n", createError);
    return 1;
  }
  printf("adapter created (handle=%p)\n", adapter);

  NET_LUID l = {0};
  luid(adapter, &l);
  GUID guid = {0};
  // The driver populates the interface table asynchronously relative to
  // `WintunCreateAdapter`, so a read that misses it is retried rather than
  // treated as a verdict.
  bool identified = false;
  for (int attempt = 0; attempt < 50; ++attempt) {
    if (ConvertInterfaceLuidToGuid(&l, &guid) == NO_ERROR) {
      identified = true;
      break;
    }
    Sleep(200);
  }
  if (!identified) {
    printf("FAIL ConvertInterfaceLuidToGuid (interface never appeared)\n");
    close(adapter);
    FreeLibrary(module);
    return 1;
  }
  wchar_t instanceId[64] = {0};
  StringFromGUID2(guid, instanceId, 64);
  printf("NetCfgInstanceId = %ls\n", instanceId);

  // Give Windows a moment to populate the class subkey, then find it.
  std::wstring subkey;
  for (int attempt = 0; attempt < 30 && subkey.empty(); ++attempt) {
    subkey = SubkeyFor(instanceId);
    if (subkey.empty()) Sleep(100);
  }
  if (subkey.empty()) {
    printf("FAIL no class subkey for this adapter's NetCfgInstanceId\n");
    close(adapter);
    FreeLibrary(module);
    return 1;
  }
  printf("class subkey = %ls\n", subkey.c_str());

  std::wstring before;
  const bool existed = ReadReg(subkey, L"ComponentId", &before);
  printf("ComponentId before: %ls\n", existed ? before.c_str() : L"(absent)");

  DumpWintunEntries("before registration");

  // Now apply the same registration the helper applies.
  HKEY handle = nullptr;
  if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, subkey.c_str(), 0, KEY_READ | KEY_WRITE,
                    &handle) != ERROR_SUCCESS) {
    printf("FAIL open class subkey for write\n");
    return 1;
  }
  const LONG written = RegSetValueExW(
      handle, L"ComponentId", 0, REG_SZ,
      reinterpret_cast<const BYTE*>(kComponentIdValue),
      static_cast<DWORD>((wcslen(kComponentIdValue) + 1) * sizeof(wchar_t)));
  RegCloseKey(handle);
  printf("RegSetValueExW(ComponentId) = %ld\n", written);

  DumpWintunEntries("after registration");

  if (runEngine) {
    printf("\n--- launching the bundled openvpn.exe with --dev-node Phantrix ---\n");
    // The log lands beside the profile, so the probe needs no write access to
    // the (possibly read-only) engine directory.
    const std::wstring log = profile + L".probe-openvpn.log";
    DeleteFileW(log.c_str());
    std::wstring args = L"--config \"" + profile +
                        L"\" --windows-driver wintun --dev-node \"Phantrix\" "
                        L"--log \"" + log + L"\"";
    STARTUPINFOW si = {0};
    si.cb = sizeof(si);
    PROCESS_INFORMATION pi = {0};
    std::wstring cmd = L"\"" + engineDir + L"\\openvpn.exe\" " + args;
    if (CreateProcessW(nullptr, cmd.data(), nullptr, nullptr, FALSE,
                       CREATE_NO_WINDOW, nullptr, engineDir.c_str(), &si, &pi)) {
      WaitForSingleObject(pi.hProcess, 45000);
      DWORD code = 0;
      GetExitCodeProcess(pi.hProcess, &code);
      printf("openvpn.exe exit code = %lu\n", code);
      CloseHandle(pi.hThread);
      CloseHandle(pi.hProcess);
    } else {
      printf("FAIL launching openvpn.exe error=%lu\n", GetLastError());
    }
    // Print the log's tail.
    HANDLE f = CreateFileW(log.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                           OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (f != INVALID_HANDLE_VALUE) {
      char buffer[8192] = {0};
      DWORD read = 0;
      ReadFile(f, buffer, sizeof(buffer) - 1, &read, nullptr);
      CloseHandle(f);
      printf("--- engine log ---\n%s\n", buffer);
    } else {
      printf("--- no engine log written ---\n");
    }
  }

  // Restore exactly what was there.
  if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, subkey.c_str(), 0, KEY_READ | KEY_WRITE,
                    &handle) == ERROR_SUCCESS) {
    if (existed && !before.empty()) {
      RegSetValueExW(handle, L"ComponentId", 0, REG_SZ,
                     reinterpret_cast<const BYTE*>(before.c_str()),
                     static_cast<DWORD>((before.size() + 1) * sizeof(wchar_t)));
      printf("restored ComponentId = %ls\n", before.c_str());
    } else {
      RegDeleteValueW(handle, L"ComponentId");
      printf("removed the ComponentId this session added\n");
    }
    RegCloseKey(handle);
  }

  close(adapter);
  FreeLibrary(module);
  printf("adapter closed\n");
  return 0;
}
