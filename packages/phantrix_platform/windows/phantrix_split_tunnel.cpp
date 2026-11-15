#include "phantrix_split_tunnel.h"

#include <iphlpapi.h>
#include <netioapi.h>
#include <winsvc.h>
#include <ws2tcpip.h>

#include <algorithm>
#include <cstdio>

#include "phantrix_ovpn_support.h"

#pragma comment(lib, "iphlpapi.lib")
#pragma comment(lib, "advapi32.lib")

namespace phantrix {
namespace split {

namespace {

using phantrix::ovpn::WideToUtf8;

// A metric high enough that no unbound connection ever picks it. The route
// exists only so a socket bound to the tunnel adapter has somewhere to go once
// OpenVPN's own full-tunnel routes are taken off.
constexpr ULONG kBoundRouteMetric = 32000;

// How long the router may take to bring its adapter and routes up.
constexpr DWORD kRouterStartTimeoutMillis = 20000;
constexpr DWORD kRouterPollMillis = 100;

constexpr ADDRESS_FAMILY kFamilies[] = {AF_INET, AF_INET6};

constexpr wchar_t kConfigFileName[] = L"router.json";
constexpr wchar_t kLogFileName[] = L"router.log";

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

// JSON string body (without the quotes) for UTF-8 text.
std::string JsonEscape(const std::string& value) {
  std::string out;
  out.reserve(value.size() + 8);
  for (const char raw : value) {
    const unsigned char c = static_cast<unsigned char>(raw);
    switch (c) {
      case '"':
        out += "\\\"";
        break;
      case '\\':
        out += "\\\\";
        break;
      case '\n':
        out += "\\n";
        break;
      case '\r':
        out += "\\r";
        break;
      case '\t':
        out += "\\t";
        break;
      default:
        if (c < 0x20) {
          char buffer[8];
          std::snprintf(buffer, sizeof(buffer), "\\u%04x", c);
          out += buffer;
        } else {
          out += raw;
        }
    }
  }
  return out;
}

// A case-insensitive, anchored RE2 pattern that matches exactly one path.
// Windows paths are case-insensitive, and the path the user picked need not
// have the same case as the one the process table reports.
std::string ExactPathPattern(const std::string& path) {
  std::string pattern = "(?i)^";
  for (const char c : path) {
    if (std::string("\\.+*?()|[]{}^$").find(c) != std::string::npos) {
      pattern += '\\';
    }
    pattern += c;
  }
  pattern += '$';
  return pattern;
}

std::string JsonStringArray(const std::vector<std::string>& values) {
  std::string out = "[";
  for (size_t index = 0; index < values.size(); ++index) {
    if (index != 0) {
      out += ", ";
    }
    out += "\"" + JsonEscape(values[index]) + "\"";
  }
  out += "]";
  return out;
}

bool InterfaceAlias(const NET_LUID& luid, std::wstring* alias) {
  wchar_t buffer[NDIS_IF_MAX_STRING_SIZE + 1] = {0};
  if (ConvertInterfaceLuidToAlias(&luid, buffer, NDIS_IF_MAX_STRING_SIZE) !=
      NO_ERROR) {
    return false;
  }
  *alias = buffer;
  return !alias->empty();
}

// The first DNS server the engine configured on the tunnel adapter, preferring
// IPv4. Empty when the server pushed none.
std::string TunnelDnsServer(const NET_LUID& luid) {
  ULONG size = 16 * 1024;
  std::vector<unsigned char> buffer;
  ULONG result = ERROR_BUFFER_OVERFLOW;
  for (int attempt = 0; attempt < 3 && result == ERROR_BUFFER_OVERFLOW;
       ++attempt) {
    buffer.resize(size);
    result = GetAdaptersAddresses(
        AF_UNSPEC,
        GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_UNICAST,
        nullptr, reinterpret_cast<PIP_ADAPTER_ADDRESSES>(buffer.data()), &size);
  }
  if (result != NO_ERROR) {
    return std::string();
  }
  std::string v4;
  std::string v6;
  for (auto* adapter = reinterpret_cast<PIP_ADAPTER_ADDRESSES>(buffer.data());
       adapter != nullptr; adapter = adapter->Next) {
    if (!SameLuid(adapter->Luid, luid)) {
      continue;
    }
    for (auto* dns = adapter->FirstDnsServerAddress; dns != nullptr;
         dns = dns->Next) {
      const SOCKADDR* address = dns->Address.lpSockaddr;
      if (address == nullptr) {
        continue;
      }
      char text[INET6_ADDRSTRLEN] = {0};
      if (address->sa_family == AF_INET && v4.empty()) {
        const auto* in = reinterpret_cast<const SOCKADDR_IN*>(address);
        if (InetNtopA(AF_INET, &in->sin_addr, text, sizeof(text)) != nullptr) {
          v4 = text;
        }
      } else if (address->sa_family == AF_INET6 && v6.empty()) {
        const auto* in6 = reinterpret_cast<const SOCKADDR_IN6*>(address);
        // Site-local "fec0:0:0:ffff::" defaults are what Windows reports when
        // nothing was configured; they are not a server.
        if (in6->sin6_addr.u.Byte[0] == 0xfe &&
            (in6->sin6_addr.u.Byte[1] & 0xc0) == 0xc0) {
          continue;
        }
        if (InetNtopA(AF_INET6, &in6->sin6_addr, text, sizeof(text)) !=
            nullptr) {
          v6 = text;
        }
      }
    }
  }
  return !v4.empty() ? v4 : v6;
}

bool TunnelHasAddress(const NET_LUID& luid, ADDRESS_FAMILY family) {
  PMIB_UNICASTIPADDRESS_TABLE table = nullptr;
  if (GetUnicastIpAddressTable(family, &table) != NO_ERROR || table == nullptr) {
    return false;
  }
  bool found = false;
  for (ULONG index = 0; index < table->NumEntries && !found; ++index) {
    const MIB_UNICASTIPADDRESS_ROW& row = table->Table[index];
    if (!SameLuid(row.InterfaceLuid, luid)) {
      continue;
    }
    if (family == AF_INET6) {
      IN6_ADDR value = row.Address.Ipv6.sin6_addr;
      if (IN6_IS_ADDR_LINKLOCAL(&value)) {
        continue;
      }
    }
    found = true;
  }
  FreeMibTable(table);
  return found;
}

bool RouterRoutesPresent(const NET_LUID& luid) {
  PMIB_IPFORWARD_TABLE2 table = nullptr;
  if (GetIpForwardTable2(AF_INET, &table) != NO_ERROR || table == nullptr) {
    return false;
  }
  bool found = false;
  for (ULONG index = 0; index < table->NumEntries && !found; ++index) {
    const MIB_IPFORWARD_ROW2& row = table->Table[index];
    found = SameLuid(row.InterfaceLuid, luid) &&
            row.DestinationPrefix.PrefixLength <= 1;
  }
  FreeMibTable(table);
  return found;
}

// A route that makes the tunnel a default path: OpenVPN's def1 pair
// (0.0.0.0/1 + 128.0.0.0/1) and its IPv6 counterparts (::/1, 8000::/1, or the
// 2000::/4, 3000::/4, fc00::/7 set older servers use).
bool IsTunnelDefaultRoute(const MIB_IPFORWARD_ROW2& row) {
  const UINT8 length = row.DestinationPrefix.PrefixLength;
  if (row.DestinationPrefix.Prefix.si_family == AF_INET) {
    return length <= 1;
  }
  return length <= 7;
}

}  // namespace

std::wstring RouterExecutable(const std::wstring& module_directory) {
  if (module_directory.empty()) {
    return std::wstring();
  }
  return module_directory + L"\\" + kRouterFileName;
}

bool RouterPresent(const std::wstring& module_directory) {
  const std::wstring path = RouterExecutable(module_directory);
  return !path.empty() &&
         GetFileAttributesW(path.c_str()) != INVALID_FILE_ATTRIBUTES;
}

void RemoveLegacyDriverService() {
  SC_HANDLE manager = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT);
  if (manager == nullptr) {
    return;
  }
  SC_HANDLE service =
      OpenServiceW(manager, kLegacyDriverServiceName,
                   SERVICE_STOP | SERVICE_QUERY_STATUS | DELETE);
  if (service != nullptr) {
    SERVICE_STATUS status = {};
    (void)ControlService(service, SERVICE_CONTROL_STOP, &status);
    (void)DeleteService(service);
    CloseServiceHandle(service);
  }
  CloseServiceHandle(manager);
}

Controller::~Controller() { Shutdown(); }

void Controller::SetUnexpectedExitCallback(ExitCallback callback) {
  on_exit_ = std::move(callback);
}

bool Controller::Prepare(const std::wstring& module_directory,
                         const std::wstring& work_directory,
                         const Policy& policy, std::string* error_code,
                         std::string* error_message) {
  Clear();
  module_directory_ = module_directory;
  work_directory_ = work_directory;
  policy_ = policy;
  prepared_ = false;
  if (!policy_.enabled) {
    prepared_ = true;
    return true;
  }
  if (policy_.include_mode && policy_.apps.empty()) {
    Fail("split.policy_rejected",
         "Include mode needs at least one application. Nothing would be "
         "routed through the tunnel otherwise.",
         error_code, error_message);
    return false;
  }
  if (!RouterPresent(module_directory_)) {
    Fail("split.router_missing",
         "The split-tunnel router (sing-box.exe) is not present beside the "
         "tunnel helper. Reinstall Phantrix to restore it.",
         error_code, error_message);
    return false;
  }
  if (work_directory_.empty()) {
    Fail("split.policy_rejected",
         "The tunnel session has no private directory for the router.",
         error_code, error_message);
    return false;
  }
  // Applications that were uninstalled since they were selected are dropped
  // rather than failing the connection. Exclude mode with no application left
  // is a full tunnel, which is the safe reading of that policy.
  std::vector<std::wstring> present;
  for (const std::wstring& path : policy_.apps) {
    if (GetFileAttributesW(path.c_str()) != INVALID_FILE_ATTRIBUTES) {
      present.push_back(path);
    }
  }
  if (policy_.include_mode && present.empty()) {
    Fail("split.policy_rejected",
         "None of the selected applications exist any more. They may have "
         "been uninstalled or moved.",
         error_code, error_message);
    return false;
  }
  policy_.apps = present;
  prepared_ = true;
  return true;
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

  std::wstring tunnel_alias;
  if (!InterfaceAlias(tunnel_luid, &tunnel_alias)) {
    Fail("split.policy_rejected",
         "The tunnel adapter could not be identified, so no application can "
         "be routed into it.",
         error_code, error_message);
    return false;
  }
  const bool tunnel_v4 = TunnelHasAddress(tunnel_luid, AF_INET);
  const bool tunnel_v6 = TunnelHasAddress(tunnel_luid, AF_INET6);
  if (!tunnel_v4 && !tunnel_v6) {
    Fail("split.policy_rejected",
         "The tunnel adapter has no address yet, so no application can be "
         "routed into it.",
         error_code, error_message);
    return false;
  }
  std::string dns = TunnelDnsServer(tunnel_luid);
  if (dns.empty()) {
    // The server pushed no resolver. A public one reached through the tunnel
    // keeps DNS off the local network, which is what the tunnel is for.
    dns = tunnel_v4 ? "1.1.1.1" : "2606:4700:4700::1111";
  }

  if (!WriteConfig(tunnel_alias, dns, error_code, error_message)) {
    return false;
  }

  // OpenVPN's full-tunnel routes would otherwise compete with the router's.
  // Taken off first, so the router's interface detection sees the physical
  // network as the default path, and replaced by one high-metric default
  // route that only sockets bound to the tunnel ever use.
  TakeTunnelRoutes(tunnel_luid);

  if (!StartRouter(error_code, error_message)) {
    StopRouter();
    RestoreTunnelRoutes();
    return false;
  }
  return true;
}

bool Controller::WriteConfig(const std::wstring& tunnel_alias,
                             const std::string& dns_server,
                             std::string* error_code,
                             std::string* error_message) {
  std::vector<std::string> app_patterns;
  for (const std::wstring& path : policy_.apps) {
    app_patterns.push_back(ExactPathPattern(WideToUtf8(path)));
  }
  // The engine's own connection to the VPN server must never be routed into
  // the tunnel it carries.
  const std::string engine_pattern = "(?i)\\\\openvpn\\.exe$";

  const char* selected_outbound = policy_.include_mode ? "vpn" : "direct";
  const char* final_outbound = policy_.include_mode ? "direct" : "vpn";

  std::string json;
  json += "{\n";
  json += "  \"log\": {\"level\": \"warn\", \"timestamp\": true},\n";
  json += "  \"dns\": {\n";
  json += "    \"servers\": [\n";
  json += "      {\"type\": \"udp\", \"tag\": \"dns-tunnel\", \"server\": \"" +
          JsonEscape(dns_server) + "\", \"detour\": \"vpn\"}\n";
  json += "    ],\n";
  json += "    \"final\": \"dns-tunnel\",\n";
  json += "    \"strategy\": \"prefer_ipv4\"\n";
  json += "  },\n";
  json += "  \"inbounds\": [\n";
  json += "    {\"type\": \"tun\", \"tag\": \"tun-in\", \"interface_name\": \"" +
          JsonEscape(WideToUtf8(kRouterAdapterName)) + "\",\n";
  json += "     \"address\": [\"172.19.0.1/30\", \"fdfe:dcba:9876::1/126\"],\n";
  json += "     \"mtu\": 1400, \"auto_route\": true, \"strict_route\": true,\n";
  json += "     \"stack\": \"mixed\"}\n";
  json += "  ],\n";
  json += "  \"outbounds\": [\n";
  json += "    {\"type\": \"direct\", \"tag\": \"vpn\", \"bind_interface\": \"" +
          JsonEscape(WideToUtf8(tunnel_alias)) + "\"},\n";
  json += "    {\"type\": \"direct\", \"tag\": \"direct\"}\n";
  json += "  ],\n";
  json += "  \"route\": {\n";
  json += "    \"rules\": [\n";
  json += "      {\"action\": \"sniff\"},\n";
  json += "      {\"protocol\": \"dns\", \"action\": \"hijack-dns\"},\n";
  json += "      {\"process_path_regex\": [\"" + JsonEscape(engine_pattern) +
          "\"], \"outbound\": \"direct\"},\n";
  json += "      {\"ip_is_private\": true, \"outbound\": \"direct\"}";
  if (!app_patterns.empty()) {
    json += ",\n      {\"process_path_regex\": " + JsonStringArray(app_patterns) +
            ", \"outbound\": \"" + selected_outbound + "\"}";
  }
  json += "\n    ],\n";
  json += std::string("    \"final\": \"") + final_outbound + "\",\n";
  json += "    \"auto_detect_interface\": true,\n";
  json += "    \"find_process\": true,\n";
  json += "    \"default_domain_resolver\": \"dns-tunnel\"\n";
  json += "  }\n";
  json += "}\n";

  const std::wstring path = work_directory_ + L"\\" + kConfigFileName;
  if (!phantrix::ovpn::WriteRestrictedFile(path, json)) {
    Fail("split.router_failed",
         "The split-tunnel router's configuration could not be written.",
         error_code, error_message);
    return false;
  }
  return true;
}

bool Controller::StartRouter(std::string* error_code,
                             std::string* error_message) {
  const std::wstring executable = RouterExecutable(module_directory_);
  const std::wstring config = work_directory_ + L"\\" + kConfigFileName;
  const std::wstring log = work_directory_ + L"\\" + kLogFileName;

  SECURITY_ATTRIBUTES inherit = {sizeof(inherit), nullptr, TRUE};
  HANDLE log_handle =
      CreateFileW(log.c_str(), GENERIC_WRITE, FILE_SHARE_READ, &inherit,
                  CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  HANDLE null_input =
      CreateFileW(L"NUL", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
                  &inherit, OPEN_EXISTING, 0, nullptr);

  // The router dies with the helper whatever way the helper ends: the job
  // closes when the helper's last handle to it does.
  job_ = CreateJobObjectW(nullptr, nullptr);
  if (job_ != nullptr) {
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {};
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    (void)SetInformationJobObject(job_, JobObjectExtendedLimitInformation,
                                  &limits, sizeof(limits));
  }

  std::wstring command = L"\"" + executable + L"\" run --disable-color -c \"" +
                         config + L"\" -D \"" + work_directory_ + L"\"";
  std::vector<wchar_t> command_line(command.begin(), command.end());
  command_line.push_back(L'\0');

  STARTUPINFOW startup = {};
  startup.cb = sizeof(startup);
  startup.dwFlags = STARTF_USESTDHANDLES;
  startup.hStdInput = null_input;
  startup.hStdOutput = log_handle;
  startup.hStdError = log_handle;
  PROCESS_INFORMATION info = {};
  const BOOL created = CreateProcessW(
      executable.c_str(), command_line.data(), nullptr, nullptr, TRUE,
      CREATE_NO_WINDOW | CREATE_SUSPENDED, nullptr, module_directory_.c_str(),
      &startup, &info);
  const DWORD create_error = created ? ERROR_SUCCESS : GetLastError();
  if (log_handle != INVALID_HANDLE_VALUE) {
    CloseHandle(log_handle);
  }
  if (null_input != INVALID_HANDLE_VALUE) {
    CloseHandle(null_input);
  }
  if (!created) {
    Fail("split.router_failed",
         "The split-tunnel router could not be started: " +
             Win32Message(create_error),
         error_code, error_message);
    return false;
  }
  if (job_ != nullptr) {
    (void)AssignProcessToJobObject(job_, info.hProcess);
  }
  ResumeThread(info.hThread);
  CloseHandle(info.hThread);
  process_ = info.hProcess;
  stopping_ = false;

  // Ready means: its adapter exists and its default routes are installed.
  const ULONGLONG deadline = GetTickCount64() + kRouterStartTimeoutMillis;
  bool ready = false;
  while (GetTickCount64() < deadline) {
    if (WaitForSingleObject(process_, kRouterPollMillis) == WAIT_OBJECT_0) {
      break;
    }
    NET_LUID luid = {};
    if (ConvertInterfaceAliasToLuid(kRouterAdapterName, &luid) == NO_ERROR &&
        RouterRoutesPresent(luid)) {
      router_luid_ = luid;
      have_router_luid_ = true;
      ready = true;
      break;
    }
  }
  if (!ready) {
    std::string detail = RouterLogTail();
    Fail("split.router_failed",
         "The split-tunnel router did not start" +
             (detail.empty() ? std::string(".") : ": " + detail),
         error_code, error_message);
    return false;
  }

  (void)RegisterWaitForSingleObject(&wait_, process_, OnRouterExit, this,
                                    INFINITE, WT_EXECUTEONLYONCE);
  return true;
}

void CALLBACK Controller::OnRouterExit(PVOID context, BOOLEAN timed_out) {
  (void)timed_out;
  auto* self = static_cast<Controller*>(context);
  if (self->stopping_.load() || !self->on_exit_) {
    return;
  }
  std::string detail = self->RouterLogTail();
  self->on_exit_("split.router_failed",
                 "The split-tunnel router stopped unexpectedly" +
                     (detail.empty() ? std::string(".") : ": " + detail));
}

std::string Controller::RouterLogTail() const {
  if (work_directory_.empty()) {
    return std::string();
  }
  const std::wstring log = work_directory_ + L"\\" + kLogFileName;
  HANDLE file = CreateFileW(log.c_str(), GENERIC_READ,
                            FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                            OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return std::string();
  }
  LARGE_INTEGER size = {};
  GetFileSizeEx(file, &size);
  const LONGLONG start = size.QuadPart > 2048 ? size.QuadPart - 2048 : 0;
  LARGE_INTEGER offset = {};
  offset.QuadPart = start;
  SetFilePointerEx(file, offset, nullptr, FILE_BEGIN);
  std::string text(2048, '\0');
  DWORD read = 0;
  (void)ReadFile(file, text.data(), static_cast<DWORD>(text.size()), &read,
                 nullptr);
  CloseHandle(file);
  text.resize(read);
  // The last non-empty line is the one that says why.
  while (!text.empty() && (text.back() == '\n' || text.back() == '\r')) {
    text.pop_back();
  }
  const size_t newline = text.find_last_of('\n');
  if (newline != std::string::npos) {
    text = text.substr(newline + 1);
  }
  return text;
}

void Controller::StopRouter() {
  stopping_ = true;
  if (wait_ != nullptr) {
    // Blocks until a running callback has returned, so `this` stays valid.
    (void)UnregisterWaitEx(wait_, INVALID_HANDLE_VALUE);
    wait_ = nullptr;
  }
  if (process_ != nullptr) {
    // sing-box removes its adapter and routes when the adapter handle closes,
    // which process termination does.
    TerminateProcess(process_, 0);
    WaitForSingleObject(process_, 5000);
    CloseHandle(process_);
    process_ = nullptr;
  }
  if (job_ != nullptr) {
    CloseHandle(job_);
    job_ = nullptr;
  }
  have_router_luid_ = false;
  router_luid_ = NET_LUID{};
}

void Controller::TakeTunnelRoutes(NET_LUID tunnel_luid) {
  tunnel_luid_ = tunnel_luid;
  have_tunnel_ = true;
  for (const ADDRESS_FAMILY family : kFamilies) {
    PMIB_IPFORWARD_TABLE2 table = nullptr;
    if (GetIpForwardTable2(family, &table) != NO_ERROR || table == nullptr) {
      continue;
    }
    for (ULONG index = 0; index < table->NumEntries; ++index) {
      const MIB_IPFORWARD_ROW2& row = table->Table[index];
      if (!SameLuid(row.InterfaceLuid, tunnel_luid) ||
          !IsTunnelDefaultRoute(row)) {
        continue;
      }
      if (DeleteIpForwardEntry2(&row) == NO_ERROR) {
        removed_routes_.push_back(row);
      }
    }
    FreeMibTable(table);
  }
  // A socket bound to the tunnel adapter needs a route on it. One default
  // route per family the tunnel carries, at a metric nothing unbound picks.
  for (const ADDRESS_FAMILY family : kFamilies) {
    if (!TunnelHasAddress(tunnel_luid, family)) {
      continue;
    }
    MIB_IPFORWARD_ROW2 row = {};
    InitializeIpForwardEntry(&row);
    row.InterfaceLuid = tunnel_luid;
    row.DestinationPrefix.Prefix.si_family = family;
    row.DestinationPrefix.PrefixLength = 0;
    row.NextHop.si_family = family;
    row.Metric = kBoundRouteMetric;
    row.Protocol = MIB_IPPROTO_NETMGMT;
    const DWORD created = CreateIpForwardEntry2(&row);
    if (created == NO_ERROR || created == ERROR_OBJECT_ALREADY_EXISTS) {
      added_routes_.push_back(row);
    }
  }
}

void Controller::RestoreTunnelRoutes() {
  for (const MIB_IPFORWARD_ROW2& row : added_routes_) {
    (void)DeleteIpForwardEntry2(&row);
  }
  added_routes_.clear();
  // Put back only while the adapter still exists; a tunnel that is already
  // gone took its routes with it.
  NET_IFINDEX index = 0;
  const bool tunnel_present =
      have_tunnel_ &&
      ConvertInterfaceLuidToIndex(&tunnel_luid_, &index) == NO_ERROR;
  if (tunnel_present) {
    for (MIB_IPFORWARD_ROW2 row : removed_routes_) {
      (void)CreateIpForwardEntry2(&row);
    }
  }
  removed_routes_.clear();
  have_tunnel_ = false;
}

bool Controller::RouterLuid(NET_LUID* luid) const {
  if (!have_router_luid_ || luid == nullptr) {
    return false;
  }
  *luid = router_luid_;
  return true;
}

void Controller::Clear() {
  StopRouter();
  RestoreTunnelRoutes();
}

void Controller::Shutdown() {
  Clear();
  prepared_ = false;
  policy_ = Policy{};
}

}  // namespace split
}  // namespace phantrix
