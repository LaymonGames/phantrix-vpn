#include "phantrix_kill_switch.h"

#include <aclapi.h>
#include <fwpmu.h>
#include <sddl.h>
#include <ws2tcpip.h>

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <vector>

#include "phantrix_ovpn_support.h"

#pragma comment(lib, "fwpuclnt.lib")
#pragma comment(lib, "advapi32.lib")

namespace phantrix {
namespace firewall {

namespace {

// Provider and sublayer that own every kill-switch object. Distinct from the
// keys the removed split-tunnel driver used, so the two cannot be confused in a
// WFP dump.
const GUID kProviderKey = {
    0x3f6b2c71, 0x8d4e, 0x4a19, {0xb2, 0x6c, 0x5e, 0x91, 0x0d, 0x7a, 0x40, 0x01}};
const GUID kSubLayerKey = {
    0x3f6b2c71, 0x8d4e, 0x4a19, {0xb2, 0x6c, 0x5e, 0x91, 0x0d, 0x7a, 0x40, 0x02}};

// Filters get keys from a fixed pool, the last byte being the index. Removing
// the whole set is then "delete every key in the pool", which needs no
// enumeration and finds filters a crashed helper left behind.
constexpr int kFilterPoolSize = 192;

GUID FilterKey(int index) {
  GUID key = {0x3f6b2c71,
              0x8d4e,
              0x4a19,
              {0xb2, 0x6c, 0x5e, 0x91, 0x0d, 0x7a, 0x41,
               static_cast<unsigned char>(index)}};
  return key;
}

constexpr UINT8 kWeightPermit = 15;
constexpr UINT8 kWeightDhcp = 13;
constexpr UINT8 kWeightDns = 12;
constexpr UINT8 kWeightLan = 10;
constexpr UINT8 kWeightBlock = 0;

std::string Win32Message(DWORD error) {
  char* text = nullptr;
  const DWORD length = FormatMessageA(
      FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
          FORMAT_MESSAGE_IGNORE_INSERTS,
      nullptr, error, MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
      reinterpret_cast<char*>(&text), 0, nullptr);
  std::string message;
  if (length != 0 && text != nullptr) {
    message.assign(text, length);
    while (!message.empty() &&
           (message.back() == '\r' || message.back() == '\n' ||
            message.back() == ' ' || message.back() == '.')) {
      message.pop_back();
    }
  }
  if (text != nullptr) {
    LocalFree(text);
  }
  if (message.empty()) {
    char buffer[32];
    std::snprintf(buffer, sizeof(buffer), "error 0x%08lx", error);
    message = buffer;
  }
  return message;
}

void Fail(const std::string& message, std::string* error_code,
          std::string* error_message) {
  if (error_code != nullptr) {
    *error_code = "kill_switch.failed";
  }
  if (error_message != nullptr) {
    *error_message = message;
  }
}

std::wstring ProgramDataDirectory() {
  wchar_t buffer[MAX_PATH + 1] = {0};
  const DWORD length =
      GetEnvironmentVariableW(L"ProgramData", buffer, MAX_PATH);
  if (length == 0 || length > MAX_PATH) {
    return L"C:\\ProgramData";
  }
  return std::wstring(buffer, length);
}

// Only Administrators and SYSTEM may write; users may read (the app reads the
// marker without elevation). Protected, so nothing is inherited from
// ProgramData, whose default ACL lets any user create files in subfolders.
constexpr wchar_t kStateDirectorySddl[] =
    L"O:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;FRFX;;;BU)";

bool IsReparsePoint(const std::wstring& path) {
  const DWORD attributes = GetFileAttributesW(path.c_str());
  return attributes != INVALID_FILE_ATTRIBUTES &&
         (attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0;
}

bool OwnedByAdministrators(const std::wstring& path) {
  PSID owner = nullptr;
  PSECURITY_DESCRIPTOR descriptor = nullptr;
  if (GetNamedSecurityInfoW(path.c_str(), SE_FILE_OBJECT,
                            OWNER_SECURITY_INFORMATION, &owner, nullptr,
                            nullptr, nullptr, &descriptor) != ERROR_SUCCESS) {
    return false;
  }
  const bool trusted = owner != nullptr &&
                       (IsWellKnownSid(owner, WinBuiltinAdministratorsSid) ||
                        IsWellKnownSid(owner, WinLocalSystemSid));
  LocalFree(descriptor);
  return trusted;
}

bool ApplyStateDacl(const std::wstring& path) {
  PSECURITY_DESCRIPTOR descriptor = nullptr;
  if (ConvertStringSecurityDescriptorToSecurityDescriptorW(
          kStateDirectorySddl, SDDL_REVISION_1, &descriptor, nullptr) ==
      FALSE) {
    return false;
  }
  BOOL present = FALSE;
  BOOL defaulted = FALSE;
  PACL dacl = nullptr;
  GetSecurityDescriptorDacl(descriptor, &present, &dacl, &defaulted);
  const DWORD result = SetNamedSecurityInfoW(
      const_cast<wchar_t*>(path.c_str()), SE_FILE_OBJECT,
      DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION, nullptr,
      nullptr, dacl, nullptr);
  LocalFree(descriptor);
  return result == ERROR_SUCCESS;
}

// Creates (or re-secures) one directory of the state tree. A directory that
// is a reparse point, or that someone other than an administrator owns, is
// not trusted: an elevated process writing into a folder a user controls is
// how arbitrary-file-overwrite attacks work.
bool SecureDirectory(const std::wstring& path) {
  if (IsReparsePoint(path)) {
    // A junction planted where this directory should be. Removing it only
    // removes the link, never its target.
    if (RemoveDirectoryW(path.c_str()) == FALSE) {
      return false;
    }
  }
  PSECURITY_DESCRIPTOR descriptor = nullptr;
  if (ConvertStringSecurityDescriptorToSecurityDescriptorW(
          kStateDirectorySddl, SDDL_REVISION_1, &descriptor, nullptr) ==
      FALSE) {
    return false;
  }
  SECURITY_ATTRIBUTES attributes = {sizeof(attributes), descriptor, FALSE};
  const BOOL created = CreateDirectoryW(path.c_str(), &attributes);
  const DWORD error = created ? ERROR_SUCCESS : GetLastError();
  LocalFree(descriptor);
  if (created) {
    return true;
  }
  if (error != ERROR_ALREADY_EXISTS || IsReparsePoint(path) ||
      !OwnedByAdministrators(path)) {
    return false;
  }
  return ApplyStateDacl(path);
}

// Removes a file name without following it if it is a link.
void RemoveName(const std::wstring& path) {
  const DWORD attributes = GetFileAttributesW(path.c_str());
  if (attributes == INVALID_FILE_ATTRIBUTES) {
    return;
  }
  if ((attributes & FILE_ATTRIBUTE_DIRECTORY) != 0) {
    RemoveDirectoryW(path.c_str());
  } else {
    DeleteFileW(path.c_str());
  }
}

void WriteMarker(Mode mode) {
  const std::wstring directory = StateDirectory();
  if (directory.empty()) {
    return;
  }
  const std::wstring path = MarkerPath();
  RemoveName(path);
  HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, FILE_SHARE_READ,
                            nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL,
                            nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return;
  }
  const char* name = ModeName(mode);
  DWORD written = 0;
  WriteFile(file, name, static_cast<DWORD>(std::strlen(name)), &written,
            nullptr);
  CloseHandle(file);
}

// Builds one filter at a time and keeps the storage its conditions point at
// alive until the transaction commits.
class FilterWriter {
 public:
  explicit FilterWriter(HANDLE engine) : engine_(engine) {}

  int count() const { return next_; }

  bool Add(const GUID& layer, UINT8 weight, FWP_ACTION_TYPE action,
           const wchar_t* name, std::vector<FWPM_FILTER_CONDITION0> conditions,
           DWORD* error) {
    if (next_ >= kFilterPoolSize) {
      *error = ERROR_INSUFFICIENT_BUFFER;
      return false;
    }
    FWPM_FILTER0 filter = {};
    filter.filterKey = FilterKey(next_);
    filter.displayData.name = const_cast<wchar_t*>(name);
    filter.displayData.description =
        const_cast<wchar_t*>(L"Phantrix kill switch");
    filter.flags = FWPM_FILTER_FLAG_PERSISTENT;
    if (action == FWP_ACTION_BLOCK) {
      // A block from here cannot be overruled by a permit in a lower
      // sublayer, such as an ordinary Windows Firewall allow rule.
      filter.flags |= FWPM_FILTER_FLAG_CLEAR_ACTION_RIGHT;
    }
    filter.providerKey = const_cast<GUID*>(&kProviderKey);
    filter.layerKey = layer;
    filter.subLayerKey = kSubLayerKey;
    filter.weight.type = FWP_UINT8;
    filter.weight.uint8 = weight;
    filter.action.type = action;
    filter.numFilterConditions = static_cast<UINT32>(conditions.size());
    filter.filterCondition = conditions.empty() ? nullptr : conditions.data();
    const DWORD result = FwpmFilterAdd0(engine_, &filter, nullptr, nullptr);
    if (result != ERROR_SUCCESS) {
      *error = result;
      return false;
    }
    ++next_;
    return true;
  }

 private:
  HANDLE engine_;
  int next_ = 0;
};

FWPM_FILTER_CONDITION0 Uint8Condition(const GUID& field, UINT8 value) {
  FWPM_FILTER_CONDITION0 condition = {};
  condition.fieldKey = field;
  condition.matchType = FWP_MATCH_EQUAL;
  condition.conditionValue.type = FWP_UINT8;
  condition.conditionValue.uint8 = value;
  return condition;
}

FWPM_FILTER_CONDITION0 Uint16Condition(const GUID& field, UINT16 value) {
  FWPM_FILTER_CONDITION0 condition = {};
  condition.fieldKey = field;
  condition.matchType = FWP_MATCH_EQUAL;
  condition.conditionValue.type = FWP_UINT16;
  condition.conditionValue.uint16 = value;
  return condition;
}

void DeletePool(HANDLE engine) {
  for (int index = 0; index < kFilterPoolSize; ++index) {
    const GUID key = FilterKey(index);
    (void)FwpmFilterDeleteByKey0(engine, &key);
  }
}

bool OpenEngine(HANDLE* engine, std::string* error_code,
                std::string* error_message) {
  // Not a dynamic session: the filters must outlive this process.
  const DWORD opened =
      FwpmEngineOpen0(nullptr, RPC_C_AUTHN_WINNT, nullptr, nullptr, engine);
  if (opened != ERROR_SUCCESS || *engine == nullptr) {
    *engine = nullptr;
    Fail("The Windows filtering engine could not be opened: " +
             Win32Message(opened),
         error_code, error_message);
    return false;
  }
  return true;
}

}  // namespace

Mode ParseMode(const std::string& text) {
  if (text == "automatic") {
    return Mode::kAutomatic;
  }
  if (text == "strict") {
    return Mode::kStrict;
  }
  return Mode::kOff;
}

const char* ModeName(Mode mode) {
  switch (mode) {
    case Mode::kAutomatic:
      return "automatic";
    case Mode::kStrict:
      return "strict";
    default:
      return "off";
  }
}

std::wstring StateDirectory() {
  const std::wstring directory = ProgramDataDirectory() + L"\\Phantrix";
  return SecureDirectory(directory) ? directory : std::wstring();
}

std::wstring StateSubdirectory(const std::wstring& name) {
  const std::wstring parent = StateDirectory();
  if (parent.empty()) {
    return std::wstring();
  }
  const std::wstring directory = parent + L"\\" + name;
  return SecureDirectory(directory) ? directory : std::wstring();
}

std::wstring MarkerPath() {
  return ProgramDataDirectory() + L"\\Phantrix\\kill-switch";
}

bool KillSwitch::Engage(Mode mode, const std::vector<std::wstring>& apps,
                        std::string* error_code, std::string* error_message) {
  if (mode == Mode::kOff) {
    mode_ = Mode::kOff;
    std::string ignored;
    (void)Release(&ignored);
    return true;
  }
  mode_ = mode;
  apps_ = apps;
  interfaces_.clear();
  setup_dns_ = true;
  return Rebuild(error_code, error_message);
}

bool KillSwitch::PermitInterface(NET_LUID luid, std::string* error_code,
                                 std::string* error_message) {
  if (mode_ == Mode::kOff) {
    return true;
  }
  for (const NET_LUID& known : interfaces_) {
    if (known.Value == luid.Value) {
      return true;
    }
  }
  interfaces_.push_back(luid);
  return Rebuild(error_code, error_message);
}

void KillSwitch::ForgetInterface(NET_LUID luid) {
  if (mode_ == Mode::kOff) {
    return;
  }
  const size_t before = interfaces_.size();
  interfaces_.erase(std::remove_if(interfaces_.begin(), interfaces_.end(),
                                   [&luid](const NET_LUID& known) {
                                     return known.Value == luid.Value;
                                   }),
                    interfaces_.end());
  if (interfaces_.size() != before) {
    std::string code;
    std::string message;
    (void)Rebuild(&code, &message);
  }
}

bool KillSwitch::SetSetupDns(bool allowed, std::string* error_code,
                             std::string* error_message) {
  if (mode_ == Mode::kOff || setup_dns_ == allowed) {
    return true;
  }
  setup_dns_ = allowed;
  return Rebuild(error_code, error_message);
}

bool KillSwitch::Disengage(std::string* error_message) {
  mode_ = Mode::kOff;
  interfaces_.clear();
  return Release(error_message);
}

bool KillSwitch::KeepAfterExit(std::string* error_code,
                               std::string* error_message) {
  if (mode_ == Mode::kOff) {
    return true;
  }
  interfaces_.clear();
  setup_dns_ = false;
  return Rebuild(error_code, error_message);
}

bool KillSwitch::Rebuild(std::string* error_code, std::string* error_message) {
  HANDLE engine = nullptr;
  if (!OpenEngine(&engine, error_code, error_message)) {
    return false;
  }
  DWORD result = FwpmTransactionBegin0(engine, 0);
  if (result != ERROR_SUCCESS) {
    FwpmEngineClose0(engine);
    Fail("The firewall transaction could not begin: " + Win32Message(result),
         error_code, error_message);
    return false;
  }

  FWPM_PROVIDER0 provider = {};
  provider.providerKey = kProviderKey;
  provider.displayData.name = const_cast<wchar_t*>(L"Phantrix");
  provider.displayData.description =
      const_cast<wchar_t*>(L"Phantrix VPN kill switch");
  provider.flags = FWPM_PROVIDER_FLAG_PERSISTENT;
  result = FwpmProviderAdd0(engine, &provider, nullptr);
  if (result != ERROR_SUCCESS && result != FWP_E_ALREADY_EXISTS) {
    FwpmTransactionAbort0(engine);
    FwpmEngineClose0(engine);
    Fail("The firewall provider could not be added: " + Win32Message(result),
         error_code, error_message);
    return false;
  }
  FWPM_SUBLAYER0 sublayer = {};
  sublayer.subLayerKey = kSubLayerKey;
  sublayer.displayData.name = const_cast<wchar_t*>(L"Phantrix kill switch");
  sublayer.providerKey = const_cast<GUID*>(&kProviderKey);
  sublayer.flags = FWPM_SUBLAYER_FLAG_PERSISTENT;
  sublayer.weight = 0xFFFF;
  result = FwpmSubLayerAdd0(engine, &sublayer, nullptr);
  if (result != ERROR_SUCCESS && result != FWP_E_ALREADY_EXISTS) {
    FwpmTransactionAbort0(engine);
    FwpmEngineClose0(engine);
    Fail("The firewall sublayer could not be added: " + Win32Message(result),
         error_code, error_message);
    return false;
  }

  // Replace, not append: the old set and the new one are swapped inside the
  // same transaction.
  DeletePool(engine);

  // Storage the conditions point into. Reserved up front so no pointer moves.
  std::vector<FWP_BYTE_BLOB*> app_ids;
  std::vector<UINT64> luids;
  luids.reserve(interfaces_.size());
  for (const NET_LUID& luid : interfaces_) {
    luids.push_back(luid.Value);
  }
  for (size_t index = 0; index < apps_.size(); ++index) {
    FWP_BYTE_BLOB* app_id = nullptr;
    if (FwpmGetAppIdFromFileName0(apps_[index].c_str(), &app_id) ==
            ERROR_SUCCESS &&
        app_id != nullptr) {
      app_ids.push_back(app_id);
    } else if (index == 0) {
      // The first entry is the engine. Without its permit no connection
      // could ever be made, so this is a failure, not a skipped rule.
      for (FWP_BYTE_BLOB* blob : app_ids) {
        FwpmFreeMemory0(reinterpret_cast<void**>(&blob));
      }
      FwpmTransactionAbort0(engine);
      FwpmEngineClose0(engine);
      Fail("The VPN engine could not be identified for the kill switch.",
           error_code, error_message);
      return false;
    }
  }

  struct V4Range {
    const char* address;
    const char* mask;
  };
  const V4Range v4_lan[] = {
      {"10.0.0.0", "255.0.0.0"},       {"172.16.0.0", "255.240.0.0"},
      {"192.168.0.0", "255.255.0.0"},  {"169.254.0.0", "255.255.0.0"},
      {"224.0.0.0", "240.0.0.0"},      {"255.255.255.255", "255.255.255.255"},
  };
  std::vector<FWP_V4_ADDR_AND_MASK> v4_masks;
  for (const V4Range& range : v4_lan) {
    IN_ADDR address = {};
    IN_ADDR mask = {};
    InetPtonA(AF_INET, range.address, &address);
    InetPtonA(AF_INET, range.mask, &mask);
    v4_masks.push_back({ntohl(address.S_un.S_addr), ntohl(mask.S_un.S_addr)});
  }
  struct V6Range {
    const char* address;
    UINT8 prefix;
  };
  const V6Range v6_lan[] = {{"fe80::", 10}, {"fc00::", 7}, {"ff00::", 8}};
  std::vector<FWP_V6_ADDR_AND_MASK> v6_masks;
  for (const V6Range& range : v6_lan) {
    FWP_V6_ADDR_AND_MASK value = {};
    IN6_ADDR address = {};
    InetPtonA(AF_INET6, range.address, &address);
    std::memcpy(value.addr, address.u.Byte, 16);
    value.prefixLength = range.prefix;
    v6_masks.push_back(value);
  }

  FilterWriter writer(engine);
  DWORD error = ERROR_SUCCESS;
  bool ok = true;

  const GUID connect_layers[] = {FWPM_LAYER_ALE_AUTH_CONNECT_V4,
                                 FWPM_LAYER_ALE_AUTH_CONNECT_V6};
  const GUID accept_layers[] = {FWPM_LAYER_ALE_AUTH_RECV_ACCEPT_V4,
                                FWPM_LAYER_ALE_AUTH_RECV_ACCEPT_V6};
  struct LayerInfo {
    GUID layer;
    bool v6;
    bool connect;
  };
  const LayerInfo layers[] = {
      {connect_layers[0], false, true},
      {connect_layers[1], true, true},
      {accept_layers[0], false, false},
      {accept_layers[1], true, false},
  };

  for (const LayerInfo& info : layers) {
    if (!ok) {
      break;
    }
    // Loopback.
    {
      FWPM_FILTER_CONDITION0 condition = {};
      condition.fieldKey = FWPM_CONDITION_FLAGS;
      condition.matchType = FWP_MATCH_FLAGS_ALL_SET;
      condition.conditionValue.type = FWP_UINT32;
      condition.conditionValue.uint32 = FWP_CONDITION_FLAG_IS_LOOPBACK;
      ok = ok && writer.Add(info.layer, kWeightPermit, FWP_ACTION_PERMIT,
                            L"Phantrix: permit loopback", {condition}, &error);
    }
    // The tunnel and router adapters.
    for (UINT64& luid : luids) {
      FWPM_FILTER_CONDITION0 condition = {};
      condition.fieldKey = FWPM_CONDITION_IP_LOCAL_INTERFACE;
      condition.matchType = FWP_MATCH_EQUAL;
      condition.conditionValue.type = FWP_UINT64;
      condition.conditionValue.uint64 = &luid;
      ok = ok && writer.Add(info.layer, kWeightPermit, FWP_ACTION_PERMIT,
                            L"Phantrix: permit tunnel adapter", {condition},
                            &error);
    }
    // The engine, the router and the app.
    for (FWP_BYTE_BLOB* app_id : app_ids) {
      FWPM_FILTER_CONDITION0 condition = {};
      condition.fieldKey = FWPM_CONDITION_ALE_APP_ID;
      condition.matchType = FWP_MATCH_EQUAL;
      condition.conditionValue.type = FWP_BYTE_BLOB_TYPE;
      condition.conditionValue.byteBlob = app_id;
      ok = ok && writer.Add(info.layer, kWeightPermit, FWP_ACTION_PERMIT,
                            L"Phantrix: permit Phantrix component", {condition},
                            &error);
    }
    // DHCP (v4 68/67, v6 546/547).
    {
      const UINT16 local_port = info.v6 ? 546 : 68;
      const UINT16 remote_port = info.v6 ? 547 : 67;
      ok = ok && writer.Add(
                     info.layer, kWeightDhcp, FWP_ACTION_PERMIT,
                     L"Phantrix: permit DHCP",
                     {Uint8Condition(FWPM_CONDITION_IP_PROTOCOL, IPPROTO_UDP),
                      Uint16Condition(FWPM_CONDITION_IP_LOCAL_PORT, local_port),
                      Uint16Condition(FWPM_CONDITION_IP_REMOTE_PORT,
                                      remote_port)},
                     &error);
    }
    // DNS outside the tunnel: allowed only while connecting, otherwise
    // blocked even to a resolver on the local network.
    if (info.connect) {
      ok = ok && writer.Add(info.layer, kWeightDns,
                            setup_dns_ ? FWP_ACTION_PERMIT : FWP_ACTION_BLOCK,
                            setup_dns_ ? L"Phantrix: permit DNS while connecting"
                                       : L"Phantrix: block DNS outside tunnel",
                            {Uint16Condition(FWPM_CONDITION_IP_REMOTE_PORT, 53)},
                            &error);
    }
    // The local network.
    {
      std::vector<FWPM_FILTER_CONDITION0> conditions;
      if (info.v6) {
        for (FWP_V6_ADDR_AND_MASK& mask : v6_masks) {
          FWPM_FILTER_CONDITION0 condition = {};
          condition.fieldKey = FWPM_CONDITION_IP_REMOTE_ADDRESS;
          condition.matchType = FWP_MATCH_EQUAL;
          condition.conditionValue.type = FWP_V6_ADDR_MASK;
          condition.conditionValue.v6AddrMask = &mask;
          conditions.push_back(condition);
        }
      } else {
        for (FWP_V4_ADDR_AND_MASK& mask : v4_masks) {
          FWPM_FILTER_CONDITION0 condition = {};
          condition.fieldKey = FWPM_CONDITION_IP_REMOTE_ADDRESS;
          condition.matchType = FWP_MATCH_EQUAL;
          condition.conditionValue.type = FWP_V4_ADDR_MASK;
          condition.conditionValue.v4AddrMask = &mask;
          conditions.push_back(condition);
        }
      }
      ok = ok && writer.Add(info.layer, kWeightLan, FWP_ACTION_PERMIT,
                            L"Phantrix: permit local network", conditions,
                            &error);
    }
    // Everything else.
    ok = ok && writer.Add(info.layer, kWeightBlock, FWP_ACTION_BLOCK,
                          L"Phantrix: block traffic outside the tunnel", {},
                          &error);
  }

  for (FWP_BYTE_BLOB* app_id : app_ids) {
    FwpmFreeMemory0(reinterpret_cast<void**>(&app_id));
  }

  if (!ok) {
    FwpmTransactionAbort0(engine);
    FwpmEngineClose0(engine);
    Fail("A kill-switch rule was refused: " + Win32Message(error), error_code,
         error_message);
    return false;
  }
  result = FwpmTransactionCommit0(engine);
  FwpmEngineClose0(engine);
  if (result != ERROR_SUCCESS) {
    Fail("The kill-switch rules were refused: " + Win32Message(result),
         error_code, error_message);
    return false;
  }
  WriteMarker(mode_);
  return true;
}

void KillSwitch::InstallRecoveryHelper(const std::wstring& helper_path) {
  const std::wstring directory = StateDirectory();
  if (directory.empty() || helper_path.empty()) {
    return;
  }
  const std::wstring target = directory + L"\\phantrix-unblock.exe";
  RemoveName(target);
  CopyFileW(helper_path.c_str(), target.c_str(), TRUE);
}

bool KillSwitch::Release(std::string* error_message) {
  HANDLE engine = nullptr;
  std::string code;
  if (!OpenEngine(&engine, &code, error_message)) {
    return false;
  }
  bool ok = FwpmTransactionBegin0(engine, 0) == ERROR_SUCCESS;
  if (ok) {
    DeletePool(engine);
    (void)FwpmSubLayerDeleteByKey0(engine, &kSubLayerKey);
    (void)FwpmProviderDeleteByKey0(engine, &kProviderKey);
    const DWORD committed = FwpmTransactionCommit0(engine);
    ok = committed == ERROR_SUCCESS;
    if (!ok && error_message != nullptr) {
      *error_message =
          "The kill-switch rules could not be removed: " +
          Win32Message(committed);
    }
  }
  FwpmEngineClose0(engine);
  if (ok) {
    RemoveName(MarkerPath());
  }
  return ok;
}

}  // namespace firewall
}  // namespace phantrix
