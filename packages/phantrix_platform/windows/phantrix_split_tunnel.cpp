#include "phantrix_split_tunnel.h"

#include <fwpmtypes.h>
#include <iphlpapi.h>
#include <netioapi.h>
#include <rpc.h>
#include <winsvc.h>
#include <ws2tcpip.h>

#include <algorithm>
#include <cstdio>

#include "driver/phantrix_split_tunnel/phantrix_split_tunnel_public.h"

#pragma comment(lib, "fwpuclnt.lib")
#pragma comment(lib, "iphlpapi.lib")
#pragma comment(lib, "rpcrt4.lib")
#pragma comment(lib, "advapi32.lib")

namespace phantrix {
namespace split {

namespace {

// The provider and sublayer that group every object this feature adds. A WFP
// dump can then answer "which rules belong to the split tunnel" without
// guessing from filter names.
const GUID kProviderKey = {
    0x8a0c6f1e, 0x62d5, 0x4c47, {0x9d, 0x8b, 0x2b, 0x1a, 0x7d, 0x0e, 0x5c, 0x11}};
const GUID kSubLayerKey = {
    0x8a0c6f1e, 0x62d5, 0x4c47, {0x9d, 0x8b, 0x2b, 0x1a, 0x7d, 0x0e, 0x5c, 0x12}};

// A metric high enough that the physical default route wins, and distinctive
// enough that the cleanup path can recognise a route this program added rather
// than one OpenVPN or Windows owns.
constexpr ULONG kIncludeRouteMetric = 32000;

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
    while (!message.empty() && (message.back() == '\r' || message.back() == '\n' ||
                                message.back() == ' ' || message.back() == '.')) {
      message.pop_back();
    }
  }
  if (text != nullptr) {
    LocalFree(text);
  }
  if (message.empty()) {
    message = "Windows error " + std::to_string(error);
  }
  return message;
}

void Fail(const char* code, const std::string& message, std::string* error_code,
          std::string* error_message) {
  if (error_code != nullptr) {
    *error_code = code;
  }
  if (error_message != nullptr) {
    *error_message = message;
  }
}

bool SameLuid(const NET_LUID& left, const NET_LUID& right) {
  return left.Value == right.Value;
}

bool AddressIsUsable(const SOCKADDR_INET& address) {
  if (address.si_family == AF_INET) {
    const IN_ADDR value = address.Ipv4.sin_addr;
    const unsigned char* b = reinterpret_cast<const unsigned char*>(&value);
    return value.S_un.S_addr != 0 && b[0] != 127 &&
           !(b[0] == 169 && b[1] == 254);
  }
  if (address.si_family == AF_INET6) {
    IN6_ADDR value = address.Ipv6.sin6_addr;
    return !IN6_IS_ADDR_UNSPECIFIED(&value) &&
           !IN6_IS_ADDR_LOOPBACK(&value) &&
           !IN6_IS_ADDR_LINKLOCAL(&value) &&
           !IN6_IS_ADDR_MULTICAST(&value);
  }
  return false;
}

bool UnicastAddressOnLuid(const NET_LUID& luid, ADDRESS_FAMILY family,
                          SOCKADDR_INET* result) {
  PMIB_UNICASTIPADDRESS_TABLE table = nullptr;
  if (GetUnicastIpAddressTable(family, &table) != NO_ERROR || table == nullptr) {
    return false;
  }
  bool found = false;
  for (ULONG index = 0; index < table->NumEntries; ++index) {
    const MIB_UNICASTIPADDRESS_ROW& row = table->Table[index];
    if (!SameLuid(row.InterfaceLuid, luid) || !AddressIsUsable(row.Address)) {
      continue;
    }
    if (result != nullptr) {
      *result = row.Address;
    }
    found = true;
    break;
  }
  FreeMibTable(table);
  return found;
}

bool BestInterfaceAddress(ADDRESS_FAMILY family, NET_LUID* luid,
                          SOCKADDR_INET* address) {
  NET_LUID best = {};
  if (family == AF_INET) {
    DWORD index = 0;
    IN_ADDR destination_address = {};
    InetPtonA(AF_INET, "1.1.1.1", &destination_address);
    const IPAddr destination = destination_address.S_un.S_addr;
    if (GetBestInterface(destination, &index) != NO_ERROR) {
      return false;
    }
    if (ConvertInterfaceIndexToLuid(index, &best) != NO_ERROR) {
      return false;
    }
  } else {
    SOCKADDR_IN6 destination = {};
    destination.sin6_family = AF_INET6;
    if (InetPtonA(AF_INET6, "2001:4860:4860::8888",
                  &destination.sin6_addr) != 1) {
      return false;
    }
    DWORD index = 0;
    if (GetBestInterfaceEx(reinterpret_cast<SOCKADDR*>(&destination), &index) !=
        NO_ERROR) {
      return false;
    }
    if (ConvertInterfaceIndexToLuid(index, &best) != NO_ERROR) {
      return false;
    }
  }
  SOCKADDR_INET found = {};
  if (!UnicastAddressOnLuid(best, family, &found)) {
    return false;
  }
  if (luid != nullptr) {
    *luid = best;
  }
  if (address != nullptr) {
    *address = found;
  }
  return true;
}

void DeleteSplitDefaultRoutes(const NET_LUID& luid, ADDRESS_FAMILY family) {
  PMIB_IPFORWARD_TABLE2 table = nullptr;
  if (GetIpForwardTable2(family, &table) != NO_ERROR || table == nullptr) {
    return;
  }
  for (ULONG index = 0; index < table->NumEntries; ++index) {
    const MIB_IPFORWARD_ROW2& row = table->Table[index];
    if (!SameLuid(row.InterfaceLuid, luid) ||
        row.DestinationPrefix.PrefixLength != 1) {
      continue;
    }
    // 0.0.0.0/1 + 128.0.0.0/1, and ::/1 + 8000::/1: the pair a full-tunnel
    // configuration uses to beat the physical default route without owning it.
    (void)DeleteIpForwardEntry2(&row);
  }
  FreeMibTable(table);
}

bool AddDefaultRoute(const NET_LUID& luid, ADDRESS_FAMILY family,
                     const SOCKADDR_INET& next_hop) {
  // Remove an earlier copy first, so reconnecting cannot accumulate routes.
  PMIB_IPFORWARD_TABLE2 table = nullptr;
  if (GetIpForwardTable2(family, &table) == NO_ERROR && table != nullptr) {
    for (ULONG index = 0; index < table->NumEntries; ++index) {
      const MIB_IPFORWARD_ROW2& row = table->Table[index];
      if (SameLuid(row.InterfaceLuid, luid) &&
          row.DestinationPrefix.PrefixLength == 0 &&
          row.Metric == kIncludeRouteMetric) {
        (void)DeleteIpForwardEntry2(&row);
      }
    }
    FreeMibTable(table);
  }

  MIB_IPFORWARD_ROW2 row = {};
  InitializeIpForwardEntry(&row);
  row.InterfaceLuid = luid;
  row.DestinationPrefix.Prefix.si_family = family;
  row.DestinationPrefix.PrefixLength = 0;
  row.SitePrefixLength = 0;
  row.NextHop = next_hop;
  row.Metric = kIncludeRouteMetric;
  row.Protocol = MIB_IPPROTO_NETMGMT;
  return CreateIpForwardEntry2(&row) == NO_ERROR;
}

void RemoveDefaultRoute(const NET_LUID& luid, ADDRESS_FAMILY family,
                        const SOCKADDR_INET& next_hop) {
  PMIB_IPFORWARD_TABLE2 table = nullptr;
  if (GetIpForwardTable2(family, &table) != NO_ERROR || table == nullptr) {
    return;
  }
  for (ULONG index = 0; index < table->NumEntries; ++index) {
    const MIB_IPFORWARD_ROW2& row = table->Table[index];
    if (!SameLuid(row.InterfaceLuid, luid) ||
        row.DestinationPrefix.PrefixLength != 0 ||
        row.Metric != kIncludeRouteMetric) {
      continue;
    }
    if (row.NextHop.si_family != next_hop.si_family) {
      continue;
    }
    // The metric and interface are the identity of a route this program added.
    // The next hop is deliberately not compared: an address that changed
    // between reconnects must still have its old route removed.
    (void)DeleteIpForwardEntry2(&row);
  }
  FreeMibTable(table);
}

bool StartDriverService(const std::wstring& binary_path, std::string* code,
                        std::string* message) {
  SC_HANDLE manager =
      OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT |
                                            SC_MANAGER_CREATE_SERVICE);
  if (manager == nullptr) {
    Fail("split.driver_failed",
         "The service manager could not be opened: " +
             Win32Message(GetLastError()),
         code, message);
    return false;
  }
  SC_HANDLE service = CreateServiceW(
      manager, kDriverServiceName, L"Phantrix split tunnel",
      SERVICE_START | SERVICE_QUERY_STATUS, SERVICE_KERNEL_DRIVER,
      SERVICE_DEMAND_START, SERVICE_ERROR_NORMAL, binary_path.c_str(), nullptr,
      nullptr, nullptr, nullptr, nullptr);
  if (service == nullptr && GetLastError() == ERROR_SERVICE_EXISTS) {
    service = OpenServiceW(manager, kDriverServiceName,
                           SERVICE_START | SERVICE_QUERY_STATUS);
  }
  if (service == nullptr) {
    const DWORD error = GetLastError();
    CloseServiceHandle(manager);
    Fail("split.driver_failed",
         "The split-tunnel driver service could not be created: " +
             Win32Message(error),
         code, message);
    return false;
  }
  const BOOL started = StartServiceW(service, 0, nullptr);
  const DWORD error = started == FALSE ? GetLastError() : ERROR_SUCCESS;
  CloseServiceHandle(service);
  CloseServiceHandle(manager);
  if (started == FALSE && error != ERROR_SERVICE_ALREADY_RUNNING) {
    // A test-signed driver on a machine that has not enabled test signing
    // lands here with ERROR_INVALID_IMAGE_HASH (577). The sentence names the
    // fact, not the code, so the user knows re-signing is the answer.
    Fail("split.driver_failed",
         "The split-tunnel driver would not start: " + Win32Message(error),
         code, message);
    return false;
  }
  return true;
}

void StopDriverService() {
  SC_HANDLE manager = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT);
  if (manager == nullptr) {
    return;
  }
  SC_HANDLE service = OpenServiceW(
      manager, kDriverServiceName, SERVICE_STOP | SERVICE_QUERY_STATUS);
  if (service != nullptr) {
    SERVICE_STATUS status = {};
    (void)ControlService(service, SERVICE_CONTROL_STOP, &status);
    CloseServiceHandle(service);
  }
  CloseServiceHandle(manager);
}

bool AddCallout(HANDLE engine, const GUID& key, const GUID& layer) {
  FWPM_CALLOUT0 callout = {};
  callout.calloutKey = key;
  callout.displayData.name = const_cast<wchar_t*>(L"Phantrix split tunnel");
  callout.displayData.description =
      const_cast<wchar_t*>(L"Redirects a selected application's connection");
  callout.providerKey = const_cast<GUID*>(&kProviderKey);
  callout.applicableLayer = layer;
  callout.flags = FWPM_CALLOUT_FLAG_USES_PROVIDER_CONTEXT;
  const DWORD result = FwpmCalloutAdd0(engine, &callout, nullptr, nullptr);
  return result == ERROR_SUCCESS || result == ERROR_ALREADY_EXISTS;
}

bool AddProviderContext(HANDLE engine, const GUID& key,
                        const PHANTRIX_REDIRECT_DATA& data) {
  FWP_BYTE_BLOB blob = {};
  blob.size = sizeof(data);
  blob.data = reinterpret_cast<UINT8*>(const_cast<PHANTRIX_REDIRECT_DATA*>(&data));
  FWPM_PROVIDER_CONTEXT0 context = {};
  context.providerContextKey = key;
  context.displayData.name =
      const_cast<wchar_t*>(L"Phantrix split tunnel redirect");
  context.providerKey = const_cast<GUID*>(&kProviderKey);
  context.type = FWPM_GENERAL_CONTEXT;
  context.dataBuffer = &blob;
  return FwpmProviderContextAdd0(engine, &context, nullptr, nullptr) ==
         ERROR_SUCCESS;
}

bool AddFilter(HANDLE engine, const wchar_t* name, const GUID& layer,
               const GUID& callout_key, const GUID& context_key,
               const FWP_BYTE_BLOB* app_id, bool block) {
  FWPM_FILTER0 filter = {};
  filter.displayData.name = const_cast<wchar_t*>(name);
  filter.layerKey = layer;
  filter.subLayerKey = kSubLayerKey;
  filter.providerKey = const_cast<GUID*>(&kProviderKey);
  filter.weight.type = FWP_UINT8;
  filter.weight.uint8 = 15;
  if (block) {
    filter.action.type = FWP_ACTION_BLOCK;
  } else {
    filter.action.type = FWP_ACTION_CALLOUT_TERMINATING;
    filter.action.calloutKey = callout_key;
    // Without this flag Windows ignores providerContextKey, so the callout
    // sees no redirect address and silently does nothing.
    filter.flags |= FWPM_FILTER_FLAG_HAS_PROVIDER_CONTEXT;
    filter.providerContextKey = context_key;
  }
  FWPM_FILTER_CONDITION0 condition = {};
  condition.fieldKey = FWPM_CONDITION_ALE_APP_ID;
  condition.matchType = FWP_MATCH_EQUAL;
  condition.conditionValue.type = FWP_BYTE_BLOB_TYPE;
  condition.conditionValue.byteBlob =
      const_cast<FWP_BYTE_BLOB*>(app_id);
  filter.numFilterConditions = 1;
  filter.filterCondition = &condition;
  return FwpmFilterAdd0(engine, &filter, nullptr, nullptr) == ERROR_SUCCESS;
}

GUID FreshGuid() {
  GUID value = {};
  (void)UuidCreate(&value);
  return value;
}

std::wstring TargetDescription(bool include_mode, ADDRESS_FAMILY family) {
  if (include_mode) {
    return family == AF_INET ? L"tunnel IPv4" : L"tunnel IPv6";
  }
  return family == AF_INET ? L"physical IPv4" : L"physical IPv6";
}

}  // namespace

Controller::~Controller() { Shutdown(); }

bool Controller::Prepare(const std::wstring& module_directory,
                         const Policy& policy, std::string* error_code,
                         std::string* error_message) {
  // A live update keeps the physical addresses captured before the tunnel
  // existed. Asking "best interface" once the tunnel is up answers with the
  // tunnel, which is the one address exclude mode must not redirect to.
  const bool had_physical = have_physical_v4_ || have_physical_v6_;
  const NET_LUID physical_luid = physical_luid_;
  const IN_ADDR physical_v4 = physical_v4_;
  const IN6_ADDR physical_v6 = physical_v6_;
  Clear();
  module_directory_ = module_directory;
  policy_ = policy;
  prepared_ = false;
  if (!policy_.enabled) {
    prepared_ = true;
    return true;
  }
  if (had_physical) {
    physical_luid_ = physical_luid;
    physical_v4_ = physical_v4;
    physical_v6_ = physical_v6;
    have_physical_v4_ = physical_v4.S_un.S_addr != 0;
    IN6_ADDR zero = {};
    have_physical_v6_ = memcmp(&physical_v6, &zero, sizeof(IN6_ADDR)) != 0;
  }
  if (policy_.include_mode && policy_.apps.empty()) {
    Fail("split.policy_rejected",
         "Include mode needs at least one application. Nothing would be "
         "routed through the tunnel otherwise.",
         error_code, error_message);
    return false;
  }
  if (!EnsureDriver(module_directory_, error_code, error_message)) {
    return false;
  }
  if (!had_physical &&
      !CapturePhysicalAddresses(error_code, error_message)) {
    return false;
  }
  prepared_ = true;
  return true;
}

bool Controller::EnsureDriver(const std::wstring& module_directory,
                              std::string* error_code,
                              std::string* error_message) {
  if (module_directory.empty()) {
    Fail("split.driver_missing", "The tunnel helper could not be located.",
         error_code, error_message);
    return false;
  }
  const std::wstring path =
      module_directory + L"\\" + std::wstring(kDriverFileName);
  if (GetFileAttributesW(path.c_str()) == INVALID_FILE_ATTRIBUTES) {
    Fail("split.driver_missing",
         "The split-tunnel driver is not present beside the tunnel helper. "
         "Reinstall Phantrix to restore it.",
         error_code, error_message);
    return false;
  }
  if (!StartDriverService(path, error_code, error_message)) {
    return false;
  }
  driver_started_ = true;
  return true;
}

bool Controller::CapturePhysicalAddresses(std::string* error_code,
                                           std::string* error_message) {
  NET_LUID luid = {};
  SOCKADDR_INET address = {};
  have_physical_v4_ =
      BestInterfaceAddress(AF_INET, &luid, &address);
  if (have_physical_v4_) {
    physical_luid_ = luid;
    physical_v4_ = address.Ipv4.sin_addr;
  }
  (void)physical_luid_;
  SOCKADDR_INET address6 = {};
  have_physical_v6_ =
      BestInterfaceAddress(AF_INET6, &luid, &address6);
  if (have_physical_v6_) {
    physical_v6_ = address6.Ipv6.sin6_addr;
  }
  if (!have_physical_v4_ && !have_physical_v6_) {
    Fail("split.policy_rejected",
         "The physical network interface could not be identified, so there is "
         "no address to route around the tunnel.",
         error_code, error_message);
    return false;
  }
  return true;
}

bool Controller::ReadTunnelAddresses(NET_LUID tunnel_luid,
                                      std::string* error_code,
                                      std::string* error_message) {
  have_tunnel_v4_ = false;
  have_tunnel_v6_ = false;
  SOCKADDR_INET address = {};
  if (UnicastAddressOnLuid(tunnel_luid, AF_INET, &address)) {
    tunnel_v4_ = address.Ipv4.sin_addr;
    have_tunnel_v4_ = true;
  }
  SOCKADDR_INET address6 = {};
  if (UnicastAddressOnLuid(tunnel_luid, AF_INET6, &address6)) {
    tunnel_v6_ = address6.Ipv6.sin6_addr;
    have_tunnel_v6_ = true;
  }
  if (!have_tunnel_v4_ && !have_tunnel_v6_) {
    Fail("split.policy_rejected",
         "The tunnel adapter has no address yet, so no application can be "
         "routed into it.",
         error_code, error_message);
    return false;
  }
  return true;
}

bool Controller::BeginSession(std::string* error_code,
                              std::string* error_message) {
  if (engine_ != nullptr) {
    return true;
  }
  session_ = {};
  session_.flags = FWPM_SESSION_FLAG_DYNAMIC;
  const DWORD opened = FwpmEngineOpen0(nullptr, RPC_C_AUTHN_WINNT, nullptr,
                                      &session_, &engine_);
  if (opened != ERROR_SUCCESS || engine_ == nullptr) {
    engine_ = nullptr;
    Fail("split.filter_failed",
         "The filtering engine could not be opened: " +
             Win32Message(opened),
         error_code, error_message);
    return false;
  }
  const DWORD transaction = FwpmTransactionBegin0(engine_, 0);
  if (transaction != ERROR_SUCCESS) {
    Fail("split.filter_failed",
         "The filtering transaction could not begin: " +
             Win32Message(transaction),
         error_code, error_message);
    return false;
  }
  FWPM_PROVIDER0 provider = {};
  provider.providerKey = kProviderKey;
  provider.displayData.name =
      const_cast<wchar_t*>(L"Phantrix split tunnel provider");
  const DWORD provider_result = FwpmProviderAdd0(
      engine_, &provider, nullptr);
  if (provider_result != ERROR_SUCCESS &&
      provider_result != ERROR_ALREADY_EXISTS) {
    (void)FwpmTransactionAbort0(engine_);
    Fail("split.filter_failed",
         "The split-tunnel provider could not be added: " +
             Win32Message(provider_result),
         error_code, error_message);
    return false;
  }
  FWPM_SUBLAYER0 sublayer = {};
  sublayer.subLayerKey = kSubLayerKey;
  sublayer.displayData.name =
      const_cast<wchar_t*>(L"Phantrix split tunnel filters");
  sublayer.providerKey = const_cast<GUID*>(&kProviderKey);
  sublayer.weight = 0x8000;
  const DWORD sublayer_result =
      FwpmSubLayerAdd0(engine_, &sublayer, nullptr);
  if (sublayer_result != ERROR_SUCCESS &&
      sublayer_result != ERROR_ALREADY_EXISTS) {
    (void)FwpmTransactionAbort0(engine_);
    Fail("split.filter_failed",
         "The split-tunnel filter group could not be added: " +
             Win32Message(sublayer_result),
         error_code, error_message);
    return false;
  }
  const struct {
    const GUID& key;
    const GUID& layer;
  } callouts[] = {
      {PHANTRIX_CONNECT_REDIRECT_V4_CALLOUT,
       FWPM_LAYER_ALE_CONNECT_REDIRECT_V4},
      {PHANTRIX_CONNECT_REDIRECT_V6_CALLOUT,
       FWPM_LAYER_ALE_CONNECT_REDIRECT_V6},
      {PHANTRIX_BIND_REDIRECT_V4_CALLOUT, FWPM_LAYER_ALE_BIND_REDIRECT_V4},
      {PHANTRIX_BIND_REDIRECT_V6_CALLOUT, FWPM_LAYER_ALE_BIND_REDIRECT_V6},
  };
  for (const auto& callout : callouts) {
    if (!AddCallout(engine_, callout.key, callout.layer)) {
      (void)FwpmTransactionAbort0(engine_);
      Fail("split.filter_failed",
           "The split-tunnel redirect callout could not be registered with "
           "the filtering engine.",
           error_code, error_message);
      return false;
    }
  }
  return true;
}

bool Controller::AddRedirectFilters(const std::wstring& target_description,
                                    std::string* error_code,
                                    std::string* error_message) {
  const bool include = policy_.include_mode;
  const bool v4 = include ? have_tunnel_v4_ : have_physical_v4_;
  const bool v6 = include ? have_tunnel_v6_ : have_physical_v6_;
  if (!v4 && !v6) {
    Fail("split.policy_rejected",
         "There is no usable tunnel or physical address to redirect to.",
         error_code, error_message);
    return false;
  }

  GUID context_v4 = {};
  GUID context_v6 = {};
  if (v4) {
    PHANTRIX_REDIRECT_DATA data = {};
    data.address_family = AF_INET;
    data.address.v4 = include ? tunnel_v4_ : physical_v4_;
    context_v4 = FreshGuid();
    if (!AddProviderContext(engine_, context_v4, data)) {
      Fail("split.filter_failed",
           "The split-tunnel redirect address could not be recorded.",
           error_code, error_message);
      return false;
    }
  }
  if (v6) {
    PHANTRIX_REDIRECT_DATA data = {};
    data.address_family = AF_INET6;
    data.address.v6 = include ? tunnel_v6_ : physical_v6_;
    context_v6 = FreshGuid();
    if (!AddProviderContext(engine_, context_v6, data)) {
      Fail("split.filter_failed",
           "The IPv6 redirect address could not be recorded.",
           error_code, error_message);
      return false;
    }
  }

  int created = 0;
  for (const std::wstring& path : policy_.apps) {
    FWP_BYTE_BLOB* app_id = nullptr;
    if (FwpmGetAppIdFromFileName0(path.c_str(), &app_id) != ERROR_SUCCESS ||
        app_id == nullptr) {
      continue;
    }
    if (v4) {
      created += AddFilter(engine_, L"Phantrix split tunnel TCP IPv4",
                           FWPM_LAYER_ALE_CONNECT_REDIRECT_V4,
                           PHANTRIX_CONNECT_REDIRECT_V4_CALLOUT, context_v4,
                           app_id, false)
                     ? 1
                     : 0;
      created += AddFilter(engine_, L"Phantrix split tunnel UDP IPv4",
                           FWPM_LAYER_ALE_BIND_REDIRECT_V4,
                           PHANTRIX_BIND_REDIRECT_V4_CALLOUT, context_v4,
                           app_id, false)
                     ? 1
                     : 0;
    }
    if (v6) {
      created += AddFilter(engine_, L"Phantrix split tunnel TCP IPv6",
                           FWPM_LAYER_ALE_CONNECT_REDIRECT_V6,
                           PHANTRIX_CONNECT_REDIRECT_V6_CALLOUT, context_v6,
                           app_id, false)
                     ? 1
                     : 0;
      created += AddFilter(engine_, L"Phantrix split tunnel UDP IPv6",
                           FWPM_LAYER_ALE_BIND_REDIRECT_V6,
                           PHANTRIX_BIND_REDIRECT_V6_CALLOUT, context_v6,
                           app_id, false)
                     ? 1
                     : 0;
    }
    FwpmFreeMemory0(reinterpret_cast<void**>(&app_id));
  }
  if (created == 0) {
    Fail("split.policy_rejected",
         "None of the selected applications could be given a routing rule. "
         "They may have been uninstalled or renamed.",
         error_code, error_message);
    return false;
  }
  return true;
}

bool Controller::AddBlockV6Filters(std::string* error_code,
                                   std::string* error_message) {
  // A selected application with no IPv6 target address must not silently fall
  // back to the physical IPv6 link. Blocking its IPv6 connections is the only
  // honest answer when neither the tunnel nor the physical interface can carry
  // the policy it was given.
  (void)error_code;
  (void)error_message;
  int created = 0;
  for (const std::wstring& path : policy_.apps) {
    FWP_BYTE_BLOB* app_id = nullptr;
    if (FwpmGetAppIdFromFileName0(path.c_str(), &app_id) != ERROR_SUCCESS ||
        app_id == nullptr) {
      continue;
    }
    created += AddFilter(engine_, L"Phantrix split tunnel IPv6 block",
                         FWPM_LAYER_ALE_AUTH_CONNECT_V6, GUID{}, GUID{},
                         app_id, true)
                   ? 1
                   : 0;
    FwpmFreeMemory0(reinterpret_cast<void**>(&app_id));
  }
  return true;
}

void Controller::RemoveIncludeRoute() {
  if (!prepared_) {
    return;
  }
  if (include_route_v4_) {
    SOCKADDR_INET next_hop = {};
    next_hop.si_family = AF_INET;
    next_hop.Ipv4.sin_family = AF_INET;
    next_hop.Ipv4.sin_addr = tunnel_v4_;
    RemoveDefaultRoute(tunnel_luid_, AF_INET, next_hop);
    include_route_v4_ = false;
  }
  if (include_route_v6_) {
    SOCKADDR_INET next_hop = {};
    next_hop.si_family = AF_INET6;
    next_hop.Ipv6.sin6_family = AF_INET6;
    next_hop.Ipv6.sin6_addr = tunnel_v6_;
    RemoveDefaultRoute(tunnel_luid_, AF_INET6, next_hop);
    include_route_v6_ = false;
  }
}

bool Controller::Apply(NET_LUID tunnel_luid, std::string* error_code,
                       std::string* error_message) {
  if (!policy_.enabled) {
    Clear();
    return true;
  }
  if (!prepared_) {
    Fail("split.policy_rejected",
         "The split-tunnel policy was not prepared before the tunnel "
         "started.",
         error_code, error_message);
    return false;
  }
  Clear();
  if (!ReadTunnelAddresses(tunnel_luid, error_code, error_message)) {
    return false;
  }
  tunnel_luid_ = tunnel_luid;

  if (policy_.include_mode) {
    // The full-tunnel pair becomes a single route at a metric below the
    // physical default, so only a connection redirected to the tunnel address
    // takes it.
    DeleteSplitDefaultRoutes(tunnel_luid_, AF_INET);
    DeleteSplitDefaultRoutes(tunnel_luid_, AF_INET6);
  }

  if (!BeginSession(error_code, error_message)) {
    return false;
  }
  if (!AddRedirectFilters(TargetDescription(policy_.include_mode, AF_INET),
                          error_code, error_message)) {
    Clear();
    return false;
  }
  const bool target_v6 = policy_.include_mode ? have_tunnel_v6_ : have_physical_v6_;
  if (!target_v6) {
    (void)AddBlockV6Filters(error_code, error_message);
  }
  if (policy_.include_mode) {
    if (have_tunnel_v4_) {
      SOCKADDR_INET next_hop = {};
      next_hop.si_family = AF_INET;
      next_hop.Ipv4.sin_family = AF_INET;
      next_hop.Ipv4.sin_addr = tunnel_v4_;
      if (!AddDefaultRoute(tunnel_luid_, AF_INET, next_hop)) {
        Clear();
        Fail("split.route_failed",
             "The include-mode default route could not be added, so the "
             "selected applications would have no tunnel path.",
             error_code, error_message);
        return false;
      }
      include_route_v4_ = true;
    }
    if (have_tunnel_v6_) {
      SOCKADDR_INET next_hop = {};
      next_hop.si_family = AF_INET6;
      next_hop.Ipv6.sin6_family = AF_INET6;
      next_hop.Ipv6.sin6_addr = tunnel_v6_;
      if (!AddDefaultRoute(tunnel_luid_, AF_INET6, next_hop)) {
        RemoveIncludeRoute();
        Clear();
        Fail("split.route_failed",
             "The include-mode IPv6 route could not be added.",
             error_code, error_message);
        return false;
      }
      include_route_v6_ = true;
    }
  }
  const DWORD committed = FwpmTransactionCommit0(engine_);
  if (committed != ERROR_SUCCESS) {
    Clear();
    Fail("split.filter_failed",
         "The split-tunnel filters were refused: " + Win32Message(committed),
         error_code, error_message);
    return false;
  }
  return true;
}

void Controller::Clear() {
  if (engine_ != nullptr) {
    // Closing a dynamic session deletes every filter, callout and provider
    // context the session created. That is the cleanup guarantee: a helper
    // that is killed cannot leave routing rules behind.
    (void)FwpmEngineClose0(engine_);
    engine_ = nullptr;
  }
  RemoveIncludeRoute();
}

void Controller::Shutdown() {
  Clear();
  if (driver_started_) {
    StopDriverService();
    driver_started_ = false;
  }
  prepared_ = false;
  policy_ = Policy{};
}

}  // namespace split
}  // namespace phantrix
