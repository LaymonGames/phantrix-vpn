// Windows tunnel backend for Phantrix.
//
// ## What this does
//
// Drives the **official OpenVPN 2.6 community** binaries (`openvpn.exe` plus
// wintun), bundled into the app next to this plugin. This file implements no
// protocol logic: its job is to write a configuration Phantrix has already
// validated to a file in the app's own per-user directory, start the engine,
// and report back what the engine itself said so the UI never guesses.
//
// ## Privilege
//
// `openvpn.exe` needs Administrator: it creates the TUN adapter and installs
// routes. This code never elevates itself and never runs elevated.
//
// Instead it launches a **separate helper program**
// (`phantrix_ovpn_helper.exe`) that carries a `requireAdministrator` manifest,
// using `ShellExecuteExW` with the `runas` verb so Windows shows its own
// consent dialog. The app stays unelevated; the helper spawns the engine as its
// child and the two talk over a named pipe the plugin creates with an explicit
// Medium-mandatory-label security descriptor. See `phantrix_ovpn_helper.cpp`
// for the helper's side of that, and `phantrix_ovpn_support.h` for the framing
// and the DACL both sides share.
//
// ## Injection
//
// The profile is written by Dart from a configuration that has already passed
// parsing and validation. It is handed to this code as one string
// (`ovpnConfig`), written to a private file, and its path — never its contents
// — travels to the engine on the command line. A newline inside a value could
// append a directive to an elevated configuration, so the native side re-checks
// the profile for execution-capable directives before it is used, in the helper
// as well as here.

#include <phantrix_platform/phantrix_plugin.h>

#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/method_call.h>
#include <flutter/method_channel.h>
#include <flutter/method_result.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <flutter/event_stream_handler.h>
#include <flutter/event_stream_handler_functions.h>
#include <windows.h>
#include <shellapi.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <tchar.h>
#include <wincodec.h>

#include <aclapi.h>
#include <sddl.h>

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <cwctype>
#include <condition_variable>
#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "phantrix_ovpn_support.h"

#pragma comment(lib, "Advapi32.lib")
#pragma comment(lib, "Gdi32.lib")
#pragma comment(lib, "Ole32.lib")
#pragma comment(lib, "Shell32.lib")
#pragma comment(lib, "Windowscodecs.lib")

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

constexpr char kMethodChannel[] = "dev.phantrix.phantrix/tunnel";
constexpr char kEventChannel[] = "dev.phantrix.phantrix/tunnelEvents";

// How long the app waits for the elevated helper to acknowledge that the engine
// is running before the attempt is reported as failed. Covers the UAC prompt
// and OpenVPN's own start-up, which on a cold machine includes opening the
// adapter. It is a timeout, not an estimate: a stuck launch is a failure, and a
// failure is recoverable in a way "connecting" forever is not.
constexpr DWORD kHelperStartTimeoutMillis = 90000;

// How long to wait for the helper to finish tearing the tunnel down.
constexpr DWORD kHelperStopTimeoutMillis = 45000;

// The app's per-user data directory, without a file name.
//
// %LOCALAPPDATA% rather than a directory beside the executable: a location
// under Program Files is shared by every account on the machine, and the
// profiles written here are not for other accounts to read.
//
// The directory carries an explicit DACL for the current user and LocalSystem
// only. The inherited ACL of %LOCALAPPDATA% already excludes other standard
// users on a default installation, but "already excludes on a default
// installation" is not a guarantee: profiles get moved, inherited ACEs get
// edited, and domain policy gets creative. The explicit DACL is what makes the
// boundary hold regardless of the parent. See
// `phantrix::ovpn::RestrictToUserAndSystem`, which is the one place that logic
// now lives, shared with the OpenVPN path.
std::wstring dataDirectory() {
	return phantrix::ovpn::AppDataDirectory();
}

std::string getString(const EncodableMap& root, const char* key) {
	const auto it = root.find(EncodableValue(key));
	if (it == root.end()) {
		return std::string();
	}
	const auto* text = std::get_if<std::string>(&it->second);
	return text == nullptr ? std::string() : *text;
}

std::vector<std::string> getStrings(const EncodableMap& root, const char* key) {
	std::vector<std::string> values;
	const auto it = root.find(EncodableValue(key));
	if (it == root.end()) {
		return values;
	}
	const auto* list = std::get_if<EncodableList>(&it->second);
	if (list == nullptr) {
		return values;
	}
	for (const EncodableValue& item : *list) {
		if (const auto* text = std::get_if<std::string>(&item)) {
			values.push_back(*text);
		}
	}
	return values;
}

// ---------------------------------------------------------------------------
// The OpenVPN session
// ---------------------------------------------------------------------------

// The state the plugin keeps about one OpenVPN connection, and the pipe it uses
// to learn about it.
//
// Nothing in here runs on the platform thread except `Handle`, `Stop` and
// `Dispose`. The helper talks to a reader thread, which forwards what it reads
// to the platform thread through a message window, so `Publish` is only ever
// called where the Flutter event sink expects it.
struct OpenVpnSession {
	// The pipe the helper connects to. Created by the plugin, closed by the
	// plugin, and never written to after a stop has been requested.
	HANDLE pipe = INVALID_HANDLE_VALUE;
	// The event the reader thread stops on, so stopping it does not mean closing
	// the pipe under a pending read.
	HANDLE readerStop = nullptr;
	// The helper process. Elevated; its exit is what tells the plugin the helper
	// is gone for good.
	HANDLE helper = INVALID_HANDLE_VALUE;
	// The thread reading the pipe.
	HANDLE reader = nullptr;
	// Token the helper must echo. Generated here, passed on its command line.
	std::wstring token;
	// The session directory holding the profile, the status file and the log.
	std::wstring session;
	std::wstring profile;
	std::wstring status;
	std::wstring log;
	// Anonymous credentials for relays whose SoftEther layer challenges the
	// session. VPN Gate accepts any username and password for its anonymous
	// hub, so the file carries the fixed word pair; relays that never ask
	// ignore it entirely, because a client only answers an AUTH request it
	// actually receives.
	std::wstring auth;
	// Set once the helper has acknowledged the engine is running.
	bool started = false;
	// Set when a stop has been asked for, so the reader stops reporting the
	// engine's exit as a failure.
	bool stopping = false;
	// Set when the reader has seen the helper's own teardown acknowledgement.
	bool disconnected = false;
	// Byte counters from the engine's status file, kept for the traffic event
	// the state event carries.
	int64_t rxBytes = 0;
	int64_t txBytes = 0;
	// The engine's last reported handshake time.
	int64_t handshakeAtMillis = 0;
};

// The window class the reader thread posts to.
//
// A real window rather than a thread-pool callback because the Flutter event
// sink is only safe on the platform thread, and the reader is not on it. A
// message-only window (`HWND_MESSAGE`) costs nothing: it is never visible,
// never activated, and has no taskbar presence.
constexpr wchar_t kMessageWindowClass[] = L"PhantrixOvpNMessageWindow";

// The message the engine reader posts. Anything in the application's private
// range is safe; this one is ours alone.
constexpr UINT kTunnelMessageId = WM_APP + 0x4F56;  // 'OV'

// What the reader thread parks on the window for the platform thread to handle.
//
// The struct is heap-allocated by the reader and deleted by the window
// procedure, so nothing aliases it across the two threads.
struct PendingEvent {
	std::string state;
	std::string errorCode;
	std::string message;
	bool hasTraffic = false;
	int64_t rxBytes = 0;
	int64_t txBytes = 0;
	int64_t handshakeAtMillis = 0;
	// When set, the platform thread completes this method result (with the
	// error above, if one was reported) and then deletes it. The method
	// handler releases its unique_ptr into the job that runs on the worker,
	// and only the platform thread may answer the Flutter messenger.
	flutter::MethodResult<EncodableValue>* result = nullptr;
	// "stopped" only: whether a `disconnected` state should follow the
	// completed reply. A stop during an attempt that already reported `failed`
	// must not claim that a tunnel came down.
	bool publishDisconnected = false;
	// The value a method reply carries when the work was a query rather than a
	// state change. Only the platform thread touches it, like every other field
	// here.
	EncodableValue payload;
	bool hasPayload = false;
};

// The rendezvous between a worker waiting for a policy acknowledgement and the
// platform thread that receives it from the helper's reader.
//
// Shared rather than stored by value because the reader may answer after the
// wait has timed out and moved on; the shared object lets the late answer be
// discarded instead of written into freed memory.
struct SplitWait {
	std::mutex mutex;
	std::condition_variable ready;
	bool done = false;
	bool ok = false;
	std::string code;
	std::string message;
};

// One unit of work for the tunnel worker thread.
//
// Everything that can wait on the helper or the engine — launching, the pipe
// handshake, tearing down — belongs to the worker. The platform thread is the
// thread Windows sends window messages to; a plugin method that blocks there
// is a window that stops repainting and earns the "(Not Responding)" title
// while a slow tunnel is torn down. Dart still gets its reply: the worker
// posts it back through the message window.
struct TunnelJob {
	enum class Kind {
		start,
		stop,
		teardownOnly,
		listApps,
		appIcon,
		splitPolicy,
		releaseKillSwitch,
		engageKillSwitch,
		killSwitchMode
	};
	Kind kind = Kind::teardownOnly;
	std::string profile;
	// A single string argument for the icon and policy jobs.
	std::string text;
	// Split-tunnel policy travelling with a start request, or on its own.
	bool splitEnabled = false;
	std::string splitMode;
	std::vector<std::string> splitApps;
	// The kill-switch mode travelling with a start request.
	std::string killSwitch;
	// A stop after a dropped connection: the kill switch keeps blocking.
	bool holdFirewall = false;
	flutter::MethodResult<EncodableValue>* result = nullptr;
	bool publishDisconnected = false;
};

// The directory the plugin's own module lives in.
//
// The engine directory and the helper executable are resolved from it, so a
// poisoned environment cannot make the app launch an attacker-chosen binary.
std::wstring pluginDirectory() {
	wchar_t modulePath[MAX_PATH + 1] = {0};
	HMODULE module = nullptr;
	if (GetModuleHandleExW(
	        GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
	            GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
	        reinterpret_cast<LPCWSTR>(&pluginDirectory), &module) == FALSE) {
		return std::wstring();
	}
	const DWORD length = GetModuleFileNameW(module, modulePath, MAX_PATH);
	if (length == 0 || length > MAX_PATH) {
		return std::wstring();
	}
	std::wstring directory(modulePath, length);
	const size_t slash = directory.find_last_of(L'\\');
	if (slash == std::wstring::npos) {
		return std::wstring();
	}
	directory.resize(slash);
	return directory;
}

// The split-tunnel router the build bundles beside the helper.
bool SplitRouterPresent(const std::wstring& directory) {
	return !directory.empty() &&
	       GetFileAttributesW((directory + L"\\sing-box.exe").c_str()) !=
	           INVALID_FILE_ATTRIBUTES;
}

// The marker the elevated helper writes while kill-switch rules are installed:
// `%ProgramData%\Phantrix\kill-switch`, holding the mode. Readable without
// elevation, which is the point: the app can tell the user that traffic is
// being blocked without asking for administrator rights.
std::wstring KillSwitchMarkerPath() {
	wchar_t buffer[MAX_PATH + 1] = {0};
	const DWORD length = GetEnvironmentVariableW(L"ProgramData", buffer, MAX_PATH);
	const std::wstring root = (length == 0 || length > MAX_PATH)
	                              ? std::wstring(L"C:\\ProgramData")
	                              : std::wstring(buffer, length);
	return root + L"\\Phantrix\\kill-switch";
}

// The mode recorded in the marker, or empty when no rules are installed.
std::string ReadKillSwitchMarker() {
	HANDLE file = CreateFileW(
	    KillSwitchMarkerPath().c_str(), GENERIC_READ,
	    FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
	    OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
	if (file == INVALID_HANDLE_VALUE) {
		return std::string();
	}
	char text[32] = {0};
	DWORD read = 0;
	(void)ReadFile(file, text, sizeof(text) - 1, &read, nullptr);
	CloseHandle(file);
	std::string mode(text, read);
	if (mode != "automatic" && mode != "strict") {
		mode = "automatic";
	}
	return mode;
}

// Runs the helper elevated with `--release-firewall` and waits for it. Used
// when no tunnel session is running to carry the request.
bool LaunchFirewallHelper(const std::wstring& directory,
                          const std::wstring& parameters, bool engage,
                          std::string* errorCode, std::string* errorMessage);

bool LaunchFirewallRelease(const std::wstring& directory, std::string* errorCode,
                           std::string* errorMessage) {
	return LaunchFirewallHelper(directory, L"--release-firewall", false,
	                            errorCode, errorMessage);
}

// Runs the helper elevated with `--engage-firewall`, installing the strict
// kill switch's rules while no tunnel is running.
bool LaunchFirewallEngage(const std::wstring& directory, std::string* errorCode,
                          std::string* errorMessage) {
	wchar_t appPath[MAX_PATH + 1] = {0};
	const DWORD length = GetModuleFileNameW(nullptr, appPath, MAX_PATH);
	std::wstring parameters = L"--engage-firewall";
	if (length > 0 && length < MAX_PATH) {
		parameters += L" --app \"" + std::wstring(appPath, length) + L"\"";
	}
	return LaunchFirewallHelper(directory, parameters, true, errorCode,
	                            errorMessage);
}

bool LaunchFirewallHelper(const std::wstring& directory,
                          const std::wstring& parameters, bool engage,
                          std::string* errorCode, std::string* errorMessage) {
	const std::wstring helper = phantrix::ovpn::HelperExecutable(directory);
	if (helper.empty() ||
	    GetFileAttributesW(helper.c_str()) == INVALID_FILE_ATTRIBUTES) {
		*errorCode = "backend.not_installed";
		*errorMessage = "The tunnel helper is missing from this installation.";
		return false;
	}
	SHELLEXECUTEINFOW execute = {0};
	execute.cbSize = sizeof(execute);
	execute.fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC;
	execute.lpVerb = L"runas";
	execute.lpFile = helper.c_str();
	execute.lpParameters = parameters.c_str();
	execute.lpDirectory = directory.c_str();
	execute.nShow = SW_HIDE;
	if (ShellExecuteExW(&execute) == FALSE || execute.hProcess == nullptr) {
		*errorCode = "permission.denied";
		*errorMessage =
		    engage ? "Windows did not grant administrator rights, so the "
		             "strict kill switch is not blocking traffic yet."
		           : "Windows did not grant administrator rights, so the kill "
		             "switch is still blocking traffic.";
		return false;
	}
	const DWORD waited = WaitForSingleObject(execute.hProcess, 60000);
	DWORD exitCode = 1;
	(void)GetExitCodeProcess(execute.hProcess, &exitCode);
	CloseHandle(execute.hProcess);
	if (waited != WAIT_OBJECT_0 || exitCode != 0) {
		*errorCode = "kill_switch.failed";
		*errorMessage =
		    engage ? "The kill switch's firewall rules could not be installed."
		           : "The kill switch's firewall rules could not be removed.";
		return false;
	}
	return true;
}

// ---------------------------------------------------------------------------
// Installed-application discovery and icons
// ---------------------------------------------------------------------------

// One application either the registry or the Start Menu named.
//
// The path is the only fact that reaches the driver, so a candidate is kept
// only when it names an existing `.exe` outside a short list of things nobody
// means to route: uninstallers, updaters, crash reporters and documentation
// viewers.
struct DiscoveredApp {
	std::wstring name;
	std::wstring path;
};

std::wstring Lower(std::wstring value) {
	std::transform(value.begin(), value.end(), value.begin(),
	               [](wchar_t c) { return static_cast<wchar_t>(towlower(c)); });
	return value;
}

bool IsPlausibleApplicationPath(const std::wstring& path) {
	if (path.size() < 5 || path.size() > 1024) {
		return false;
	}
	const std::wstring lower = Lower(path);
	if (lower.size() < 4 ||
	    lower.compare(lower.size() - 4, 4, L".exe") != 0) {
		return false;
	}
	// The Windows directory holds the operating system's own programs. A user
	// picking `svchost.exe` would be routing something they cannot identify, and
	// those images are already covered by the system policy.
	wchar_t windows[MAX_PATH + 1] = {0};
	if (GetWindowsDirectoryW(windows, MAX_PATH) != 0) {
		const std::wstring system = Lower(std::wstring(windows) + L"\\");
		if (lower.rfind(system, 0) == 0) {
			return false;
		}
	}
	static const wchar_t* const noise[] = {
	    L"unins", L"uninstall", L"setup", L"update", L"updater",
	    L"crash", L"report", L"readme", L"help", L"vcredist",
	};
	for (const wchar_t* fragment : noise) {
		if (lower.find(fragment) != std::wstring::npos) {
			return false;
		}
	}
	const DWORD attributes = GetFileAttributesW(path.c_str());
	return attributes != INVALID_FILE_ATTRIBUTES &&
	       (attributes & FILE_ATTRIBUTE_DIRECTORY) == 0;
}

std::wstring DisplayIconToPath(const std::wstring& icon) {
	std::wstring value = icon;
	const size_t comma = value.find_last_of(L',');
	if (comma != std::wstring::npos) {
		const std::wstring suffix = value.substr(comma + 1);
		if (!suffix.empty() &&
		    suffix.find_first_not_of(L"0123456789- ") == std::wstring::npos) {
			value.resize(comma);
		}
	}
	value = value.size() >= 2 && value.front() == L'"' && value.back() == L'"'
	            ? value.substr(1, value.size() - 2)
	            : value;
	while (!value.empty() && (value.back() == L' ' || value.back() == L'\t')) {
		value.pop_back();
	}
	return value;
}

std::wstring ReadRegistryString(HKEY root, const std::wstring& key,
                                const wchar_t* name) {
	HKEY handle = nullptr;
	if (RegOpenKeyExW(root, key.c_str(), 0, KEY_READ, &handle) !=
	    ERROR_SUCCESS) {
		return std::wstring();
	}
	DWORD type = 0;
	DWORD bytes = 0;
	std::wstring result;
	if (RegQueryValueExW(handle, name, nullptr, &type, nullptr, &bytes) ==
	        ERROR_SUCCESS &&
	    (type == REG_SZ || type == REG_EXPAND_SZ) && bytes >= sizeof(wchar_t) &&
	    bytes <= 32 * 1024) {
		std::vector<wchar_t> buffer(bytes / sizeof(wchar_t) + 1, L'\0');
		if (RegQueryValueExW(handle, name, nullptr, &type,
		                     reinterpret_cast<LPBYTE>(buffer.data()),
		                     &bytes) == ERROR_SUCCESS) {
			result.assign(buffer.data());
			if (type == REG_EXPAND_SZ) {
				wchar_t expanded[2048] = {0};
				if (ExpandEnvironmentStringsW(result.c_str(), expanded,
				                              2048) > 0) {
					result.assign(expanded);
				}
			}
		}
	}
	RegCloseKey(handle);
	return result;
}

DWORD ReadRegistryDword(HKEY root, const std::wstring& key,
                        const wchar_t* name) {
	HKEY handle = nullptr;
	if (RegOpenKeyExW(root, key.c_str(), 0, KEY_READ, &handle) !=
	    ERROR_SUCCESS) {
		return 0;
	}
	DWORD type = 0;
	DWORD value = 0;
	DWORD bytes = sizeof(value);
	const bool ok = RegQueryValueExW(handle, name, nullptr, &type,
	                                 reinterpret_cast<LPBYTE>(&value),
	                                 &bytes) == ERROR_SUCCESS &&
	                type == REG_DWORD;
	RegCloseKey(handle);
	return ok ? value : 0;
}

void AddDiscovered(std::vector<DiscoveredApp>* apps, std::wstring name,
                   std::wstring path) {
	if (apps == nullptr || !IsPlausibleApplicationPath(path)) {
		return;
	}
	const std::wstring canonical = Lower(path);
	for (const DiscoveredApp& existing : *apps) {
		if (Lower(existing.path) == canonical) {
			return;
		}
	}
	if (name.empty()) {
		const size_t separator = path.find_last_of(L'\\');
		name = separator == std::wstring::npos ? path : path.substr(separator + 1);
	}
	name = name.size() > 160 ? name.substr(0, 160) : name;
	apps->push_back(DiscoveredApp{std::move(name), std::move(path)});
}

// Finds a single executable inside an install directory.
//
// Installers put the program at the top level far more often than in a nested
// directory, and a bounded scan keeps enumeration from turning into a walk of
// every file in Program Files.
std::wstring FindExecutableIn(const std::wstring& directory) {
	if (directory.empty()) {
		return std::wstring();
	}
	WIN32_FIND_DATAW data = {0};
	const std::wstring pattern = directory + L"\\*.exe";
	HANDLE search = FindFirstFileW(pattern.c_str(), &data);
	if (search == INVALID_HANDLE_VALUE) {
		return std::wstring();
	}
	std::wstring best;
	int inspected = 0;
	do {
		if ((data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) {
			continue;
		}
		const std::wstring candidate = directory + L"\\" + data.cFileName;
		if (IsPlausibleApplicationPath(candidate)) {
			best = candidate;
			break;
		}
		++inspected;
	} while (inspected < 64 && FindNextFileW(search, &data) != FALSE);
	FindClose(search);
	return best;
}

void EnumerateUninstallKey(HKEY root, REGSAM view, std::vector<DiscoveredApp>* apps) {
	const wchar_t* paths[] = {
	    L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall",
	    L"SOFTWARE\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall",
	};
	for (const wchar_t* base : paths) {
		HKEY key = nullptr;
		if (RegOpenKeyExW(root, base, 0, KEY_READ | view, &key) !=
		    ERROR_SUCCESS) {
			continue;
		}
		DWORD index = 0;
		wchar_t name[512] = {0};
		DWORD nameLength = 512;
		while (RegEnumKeyExW(key, index++, name, &nameLength, nullptr, nullptr,
		                     nullptr, nullptr) == ERROR_SUCCESS) {
			const std::wstring subkey = std::wstring(base) + L"\\" + name;
			nameLength = 512;
			if (ReadRegistryDword(root, subkey, L"SystemComponent") == 1 ||
			    !ReadRegistryString(root, subkey, L"ParentKeyName").empty()) {
				continue;
			}
			const std::wstring release =
			    ReadRegistryString(root, subkey, L"ReleaseType");
			if (!release.empty() &&
			    Lower(release).find(L"update") != std::wstring::npos) {
				continue;
			}
			const std::wstring displayName =
			    ReadRegistryString(root, subkey, L"DisplayName");
			if (displayName.empty() ||
			    Lower(displayName).find(L"phantrix") != std::wstring::npos) {
				continue;
			}
			std::wstring path = DisplayIconToPath(
			    ReadRegistryString(root, subkey, L"DisplayIcon"));
			if (!IsPlausibleApplicationPath(path)) {
				path = FindExecutableIn(
				    ReadRegistryString(root, subkey, L"InstallLocation"));
			}
			AddDiscovered(apps, displayName, path);
		}
		RegCloseKey(key);
	}
}

void EnumerateShortcutFolder(REFKNOWNFOLDERID folder,
                             std::vector<DiscoveredApp>* apps, int* budget) {
	PWSTR folderPath = nullptr;
	if (SHGetKnownFolderPath(folder, KF_FLAG_DEFAULT, nullptr, &folderPath) !=
	    S_OK) {
		return;
	}
	const std::wstring root(folderPath);
	CoTaskMemFree(folderPath);
	if (root.empty() || budget == nullptr || *budget <= 0) {
		return;
	}

	std::vector<std::wstring> pending = {root};
	while (!pending.empty() && *budget > 0) {
		const std::wstring directory = pending.back();
		pending.pop_back();
		const std::wstring pattern = directory + L"\\*";
		WIN32_FIND_DATAW data = {0};
		HANDLE search = FindFirstFileW(pattern.c_str(), &data);
		if (search == INVALID_HANDLE_VALUE) {
			continue;
		}
		do {
			if (*budget <= 0) {
				break;
			}
			if ((data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) {
				if (wcscmp(data.cFileName, L".") != 0 &&
				    wcscmp(data.cFileName, L"..") != 0) {
					pending.push_back(directory + L"\\" + data.cFileName);
				}
				continue;
			}
			const std::wstring lower = Lower(data.cFileName);
			if (lower.size() < 4 ||
			    lower.compare(lower.size() - 4, 4, L".lnk") != 0) {
				continue;
			}
			--*budget;
			const std::wstring shortcut = directory + L"\\" + data.cFileName;
			IShellLinkW* link = nullptr;
			if (CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER,
			                     IID_PPV_ARGS(&link)) != S_OK ||
			    link == nullptr) {
				continue;
			}
			IPersistFile* file = nullptr;
			if (SUCCEEDED(link->QueryInterface(IID_PPV_ARGS(&file))) &&
			    file != nullptr) {
				if (SUCCEEDED(file->Load(shortcut.c_str(), STGM_READ))) {
					wchar_t target[1024] = {0};
					if (SUCCEEDED(link->GetPath(target, 1024, nullptr,
					                            SLGP_RAWPATH))) {
						std::wstring name = data.cFileName;
						name.resize(name.size() - 4);
						if (Lower(name).find(L"uninstall") ==
						    std::wstring::npos) {
							AddDiscovered(apps, name, target);
						}
					}
				}
				file->Release();
			}
			link->Release();
		} while (FindNextFileW(search, &data) != FALSE);
		FindClose(search);
	}
}

std::vector<DiscoveredApp> DiscoverInstalledApps() {
	std::vector<DiscoveredApp> apps;
	EnumerateUninstallKey(HKEY_LOCAL_MACHINE, KEY_WOW64_64KEY, &apps);
	EnumerateUninstallKey(HKEY_LOCAL_MACHINE, KEY_WOW64_32KEY, &apps);
	EnumerateUninstallKey(HKEY_CURRENT_USER, 0, &apps);
	int budget = 600;
	EnumerateShortcutFolder(FOLDERID_CommonPrograms, &apps, &budget);
	EnumerateShortcutFolder(FOLDERID_Programs, &apps, &budget);
	std::sort(apps.begin(), apps.end(),
	          [](const DiscoveredApp& left, const DiscoveredApp& right) {
		          return Lower(left.name) < Lower(right.name);
	          });
	return apps;
}

std::string Base64Encode(const std::vector<uint8_t>& bytes) {
	static const char kAlphabet[] =
	    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
	std::string out;
	out.reserve(((bytes.size() + 2) / 3) * 4);
	for (size_t i = 0; i < bytes.size(); i += 3) {
		const uint32_t first = bytes[i];
		const uint32_t second = i + 1 < bytes.size() ? bytes[i + 1] : 0;
		const uint32_t third = i + 2 < bytes.size() ? bytes[i + 2] : 0;
		const uint32_t value = (first << 16) | (second << 8) | third;
		out.push_back(kAlphabet[(value >> 18) & 0x3F]);
		out.push_back(kAlphabet[(value >> 12) & 0x3F]);
		out.push_back(i + 1 < bytes.size() ? kAlphabet[(value >> 6) & 0x3F]
		                                  : '=');
		out.push_back(i + 2 < bytes.size() ? kAlphabet[value & 0x3F] : '=');
	}
	return out;
}

// Extracts a file's icon as a PNG.
//
// The bytes are base64 rather than a raw blob because the standard method
// channel carries strings and typed lists comfortably but not arbitrary binary
// buffers, and a 32x32 PNG is small enough that base64's third is irrelevant.
std::string IconPngBase64(const std::wstring& path) {
	SHFILEINFOW info = {0};
	if (SHGetFileInfoW(path.c_str(), 0, &info, sizeof(info),
	                   SHGFI_ICON | SHGFI_LARGEICON) == 0 ||
	    info.hIcon == nullptr) {
		return std::string();
	}
	std::string result;
	IWICImagingFactory* factory = nullptr;
	IWICBitmap* bitmap = nullptr;
	IWICStream* stream = nullptr;
	IWICBitmapEncoder* encoder = nullptr;
	IWICBitmapFrameEncode* frame = nullptr;
	IStream* memory = nullptr;
	do {
		if (CoCreateInstance(CLSID_WICImagingFactory, nullptr,
		                     CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory)) !=
		    S_OK) {
			break;
		}
		if (factory->CreateBitmapFromHICON(info.hIcon, &bitmap) != S_OK) {
			break;
		}
		if (CreateStreamOnHGlobal(nullptr, TRUE, &memory) != S_OK) {
			break;
		}
		if (factory->CreateStream(&stream) != S_OK) {
			break;
		}
		if (stream->InitializeFromIStream(memory) != S_OK) {
			break;
		}
		if (factory->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder) !=
		    S_OK) {
			break;
		}
		if (encoder->Initialize(stream, WICBitmapEncoderNoCache) != S_OK) {
			break;
		}
		IPropertyBag2* properties = nullptr;
		if (encoder->CreateNewFrame(&frame, &properties) != S_OK) {
			break;
		}
		if (properties != nullptr) {
			properties->Release();
			properties = nullptr;
		}
		if (frame->Initialize(nullptr) != S_OK ||
		    frame->WriteSource(bitmap, nullptr) != S_OK ||
		    frame->Commit() != S_OK || encoder->Commit() != S_OK) {
			break;
		}
		STATSTG stat = {0};
		if (memory->Stat(&stat, STATFLAG_NONAME) != S_OK ||
		    stat.cbSize.QuadPart <= 0 ||
		    stat.cbSize.QuadPart > 1024 * 1024) {
			break;
		}
		LARGE_INTEGER start = {0};
		if (memory->Seek(start, STREAM_SEEK_SET, nullptr) != S_OK) {
			break;
		}
		std::vector<uint8_t> bytes(static_cast<size_t>(stat.cbSize.QuadPart));
		ULONG read = 0;
		if (memory->Read(bytes.data(), static_cast<ULONG>(bytes.size()),
		                 &read) != S_OK ||
		    read != bytes.size()) {
			break;
		}
		result = Base64Encode(bytes);
	} while (false);
	if (frame != nullptr) {
		frame->Release();
	}
	if (encoder != nullptr) {
		encoder->Release();
	}
	if (stream != nullptr) {
		stream->Release();
	}
	if (memory != nullptr) {
		memory->Release();
	}
	if (bitmap != nullptr) {
		bitmap->Release();
	}
	if (factory != nullptr) {
		factory->Release();
	}
	DestroyIcon(info.hIcon);
	return result;
}

// Ensures COM is ready on the calling thread and reverses only its own
// initialization. Flutter's platform thread may already be apartment-threaded;
// an RPC_E_CHANGED_MODE answer means someone else owns that decision and this
// function must not undo it.
struct ComScope {
	HRESULT result = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
	~ComScope() {
		if (SUCCEEDED(result)) {
			CoUninitialize();
		}
	}
};

std::wstring PickExecutableFile() {
	ComScope com;
	IFileOpenDialog* dialog = nullptr;
	if (CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER,
	                     IID_PPV_ARGS(&dialog)) != S_OK ||
	    dialog == nullptr) {
		return std::wstring();
	}
	std::wstring chosen;
	do {
		COMDLG_FILTERSPEC filters[] = {
		    {L"Applications", L"*.exe"},
		    {L"All files", L"*.*"},
		};
		dialog->SetFileTypes(2, filters);
		dialog->SetTitle(L"Choose an application");
		FILEOPENDIALOGOPTIONS options = 0;
		if (FAILED(dialog->GetOptions(&options))) {
			break;
		}
		options |= FOS_FORCEFILESYSTEM | FOS_FILEMUSTEXIST | FOS_PATHMUSTEXIST;
		if (FAILED(dialog->SetOptions(options))) {
			break;
		}
		if (FAILED(dialog->Show(GetActiveWindow()))) {
			break;
		}
		IShellItem* item = nullptr;
		if (FAILED(dialog->GetResult(&item)) || item == nullptr) {
			break;
		}
		PWSTR path = nullptr;
		if (SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &path)) &&
		    path != nullptr) {
			chosen.assign(path);
			CoTaskMemFree(path);
		}
		item->Release();
	} while (false);
	dialog->Release();
	return chosen;
}

// Launches the helper and waits for it to say the engine is running.
//
// `runas` is the documented way to ask Windows for a one-off elevation prompt
// for a program whose manifest asks for it. The app itself is never elevated,
// and the prompt is never suppressed: if the user cancels, the launch fails and
// that is reported as `permission.denied` rather than as a tunnel that is
// connecting.
bool LaunchHelper(const std::wstring& directory, const std::wstring& pipeName,
                  const std::wstring& token, DWORD parentPid,
                  HANDLE* helperProcess, std::string* errorCode,
                  std::string* errorMessage) {
	const std::wstring helper = phantrix::ovpn::HelperExecutable(directory);
	if (helper.empty() ||
	    GetFileAttributesW(helper.c_str()) == INVALID_FILE_ATTRIBUTES) {
		*errorCode = "backend.not_installed";
		*errorMessage =
		    "The tunnel helper that runs the engine with administrator rights "
		    "is missing from this installation.";
		return false;
	}

	std::wstring parameters = std::wstring(L"--pipe \"") + pipeName +
	                          L"\" --token \"" + token + L"\" --parent \"" +
	                          std::to_wstring(parentPid) + L"\"";

	SHELLEXECUTEINFOW execute = {0};
	execute.cbSize = sizeof(execute);
	execute.fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC;
	execute.hwnd = nullptr;
	execute.lpVerb = L"runas";
	execute.lpFile = helper.c_str();
	execute.lpParameters = parameters.c_str();
	execute.lpDirectory = directory.c_str();
	execute.nShow = SW_HIDE;
	if (ShellExecuteExW(&execute) == FALSE) {
		const DWORD error = GetLastError();
		if (error == ERROR_CANCELLED) {
			// The user dismissed the consent dialog. That is a decision, not a
			// fault, and it is reported as one.
			*errorCode = "permission.denied";
			*errorMessage =
			    "Windows did not grant administrator rights, so the tunnel was "
			    "not created.";
		} else {
			*errorCode = "permission.denied";
			*errorMessage =
			    "Windows refused to start the tunnel helper. Administrator "
			    "rights are required, and the helper must be present.";
		}
		return false;
	}
	if (execute.hProcess == nullptr) {
		*errorCode = "backend.launch_failed";
		*errorMessage = "The tunnel helper started but could not be monitored.";
		return false;
	}
	*helperProcess = execute.hProcess;
	return true;
}

} // namespace

class PhantrixWindowsPlugin : public flutter::Plugin {
 public:
	static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar) {
		auto plugin = std::make_unique<PhantrixWindowsPlugin>();

		auto methodChannel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
				registrar->messenger(), kMethodChannel,
				&flutter::StandardMethodCodec::GetInstance());
		auto eventChannel = std::make_unique<flutter::EventChannel<EncodableValue>>(
				registrar->messenger(), kEventChannel,
				&flutter::StandardMethodCodec::GetInstance());

		PhantrixWindowsPlugin* raw = plugin.get();
		eventChannel->SetStreamHandler(
				std::make_unique<flutter::StreamHandlerFunctions<EncodableValue>>(
						[raw](const EncodableValue*,
						     std::unique_ptr<flutter::EventSink<EncodableValue>>&& events)
							->std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
							raw->events_ = std::move(events);
							return nullptr;
						},
						[raw](const EncodableValue*)
							->std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
							raw->events_.reset();
							return nullptr;
						}));

		methodChannel->SetMethodCallHandler(
				[raw](const flutter::MethodCall<EncodableValue>& call,
				      std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
					raw->Handle(call, std::move(result));
				});

		plugin->methodChannel_ = std::move(methodChannel);
		plugin->eventChannel_ = std::move(eventChannel);
		registrar->AddPlugin(std::move(plugin));
	}

	// The plugin's message-only window and its tunnel worker are created here,
	// on the platform thread, and live as long as the plugin. The window is
	// created once rather than per session because the worker posts method
	// replies through it even when no session was ever started; and it stays on
	// this thread because that is where the Flutter messenger expects its
	// answers.
	PhantrixWindowsPlugin() {
		WNDCLASSEXW windowClass = {0};
		windowClass.cbSize = sizeof(windowClass);
		windowClass.lpfnWndProc = MessageWindowProc;
		windowClass.hInstance = GetModuleHandleW(nullptr);
		windowClass.lpszClassName = kMessageWindowClass;
		RegisterClassExW(&windowClass);
		messageWindow_ =
		    CreateWindowExW(0, kMessageWindowClass, L"", 0, 0, 0, 0, 0,
		                    HWND_MESSAGE, nullptr, GetModuleHandleW(nullptr),
		                    nullptr);
		if (messageWindow_ != nullptr) {
			SetWindowLongPtrW(messageWindow_, GWLP_USERDATA,
			                  reinterpret_cast<LONG_PTR>(this));
		}
		tunnelWorker_ = std::thread(&PhantrixWindowsPlugin::TunnelWorkerMain,
		                            this);
	}

	// Releases the engine's resources when the plugin is torn down. Without
	// this the reader thread would outlive its owner, holding a thread and a
	// message window that can no longer report.
	~PhantrixWindowsPlugin() {
		// The worker is asked to stop before anything is joined or destroyed:
		// a job that would wait on a helper with no audience has nothing left
		// to report to.
		{
			std::lock_guard<std::mutex> lock(queueMutex_);
			stopping_ = true;
			queue_.clear();
		}
		queueSignal_.notify_all();
		if (tunnelWorker_.joinable()) {
			tunnelWorker_.join();
		}
		// Nothing else can touch the session now, so the last teardown runs
		// here: blocking while the application is closing is fine, and leaving
		// an elevated helper behind is not.
		//
		// Closing the app lifts the kill switch in every mode, strict
		// included: the rules do not outlive the app. If rules remain after
		// the helper is gone (a held block with no helper), an elevated
		// release removes them.
		TeardownOpenVpn(false);
		if (!ReadKillSwitchMarker().empty()) {
			std::string code;
			std::string message;
			(void)LaunchFirewallRelease(pluginDirectory(), &code, &message);
		}
		if (messageWindow_ != nullptr) {
			SetWindowLongPtrW(messageWindow_, GWLP_USERDATA, 0);
			DestroyWindow(messageWindow_);
			messageWindow_ = nullptr;
		}
	}

 private:
	// Queues a job for the tunnel worker. Called from the platform thread.
	void EnqueueJob(TunnelJob job) {
		{
			std::lock_guard<std::mutex> lock(queueMutex_);
			if (stopping_) {
				delete job.result;
				return;
			}
			queue_.push_back(std::move(job));
		}
		queueSignal_.notify_one();
	}

	// Posts a heap PendingEvent to the plugin's message window, where the
	// platform thread consumes and deletes it. Safe from any thread.
	void PostEvent(PendingEvent* pending) {
		if (messageWindow_ == nullptr) {
			delete pending->result;
			delete pending;
			return;
		}
		PostMessageW(messageWindow_, kTunnelMessageId, 0,
		             reinterpret_cast<LPARAM>(pending));
	}

	// Reports a failure the way the helper's own failures arrive: through the
	// window, so the state bookkeeping happens on the platform thread.
	void PostFailure(const std::string& code, const std::string& message) {
		auto* pending = new PendingEvent();
		pending->state = "failed";
		pending->errorCode = code;
		pending->message = message;
		PostEvent(pending);
	}

	// The tunnel worker's loop. Every job that can wait on the helper — and
	// only those — runs here, one at a time, so starts and stops cannot race
	// each other for the engine.
	void TunnelWorkerMain() {
		for (;;) {
			TunnelJob job;
			{
				std::unique_lock<std::mutex> lock(queueMutex_);
				queueSignal_.wait(lock, [this] {
					return stopping_ || !queue_.empty();
				});
				if (stopping_) {
					// Shutdown: a job that would wait on the helper has no
					// audience any more. The replies in the dropped jobs
					// belong to the closing application.
					return;
				}
				job = std::move(queue_.front());
				queue_.pop_front();
			}
			switch (job.kind) {
				case TunnelJob::Kind::listApps: {
					EncodableList list;
					for (const DiscoveredApp& app : DiscoverInstalledApps()) {
						EncodableMap entry;
						entry[EncodableValue("name")] =
						    EncodableValue(phantrix::ovpn::WideToUtf8(app.name));
						entry[EncodableValue("path")] =
						    EncodableValue(phantrix::ovpn::WideToUtf8(app.path));
						list.push_back(EncodableValue(entry));
					}
					auto* pending = new PendingEvent();
					pending->state = "value";
					pending->hasPayload = true;
					pending->payload = EncodableValue(list);
					pending->result = job.result;
					PostEvent(pending);
					break;
				}
				case TunnelJob::Kind::appIcon: {
					auto* pending = new PendingEvent();
					pending->state = "value";
					pending->hasPayload = true;
					const std::string icon =
					    IconPngBase64(phantrix::ovpn::Utf8ToWide(job.text));
					pending->payload =
					    icon.empty() ? EncodableValue() : EncodableValue(icon);
					pending->result = job.result;
					PostEvent(pending);
					break;
				}
				case TunnelJob::Kind::splitPolicy: {
					std::string code;
					std::string message;
					(void)ApplySplitPolicy(job.splitEnabled, job.splitMode,
					                       job.splitApps, &code, &message);
					auto* pending = new PendingEvent();
					pending->state = "start-finished";
					pending->errorCode = code;
					pending->message = message;
					pending->result = job.result;
					PostEvent(pending);
					break;
				}
				case TunnelJob::Kind::start: {
					std::string code;
					std::string message;
					const bool started = StartOpenVpn(
					    job.profile, job.splitEnabled, job.splitMode, job.splitApps,
					    job.killSwitch, &code, &message);
					if (!started) {
						// The same failure the helper would have reported,
						// through the same path, so Dart sees one shape.
						PostFailure(code, message);
						TeardownOpenVpn();
					}
					auto* pending = new PendingEvent();
					pending->state = "start-finished";
					pending->errorCode = code;
					pending->message = message;
					pending->result = job.result;
					PostEvent(pending);
					break;
				}
				case TunnelJob::Kind::stop: {
					TeardownOpenVpn(job.holdFirewall);
					// Automatic-mode rules held after a drop belong to no
					// running helper. A disconnect is the moment they end.
					if (!job.holdFirewall &&
					    ReadKillSwitchMarker() == "automatic") {
						std::string code;
						std::string message;
						(void)LaunchFirewallRelease(pluginDirectory(), &code,
						                            &message);
					}
					auto* pending = new PendingEvent();
					pending->state = "stopped";
					pending->result = job.result;
					pending->publishDisconnected = job.publishDisconnected;
					PostEvent(pending);
					break;
				}
				case TunnelJob::Kind::teardownOnly:
					TeardownOpenVpn(job.holdFirewall);
					break;
				case TunnelJob::Kind::releaseKillSwitch: {
					// A running session is stopped first; it carries the
					// release itself. Anything still installed after that
					// (strict mode, or a session that ended holding) needs
					// its own elevated run.
					TeardownOpenVpn(false);
					std::string code;
					std::string message;
					if (!ReadKillSwitchMarker().empty()) {
						(void)LaunchFirewallRelease(pluginDirectory(), &code,
						                            &message);
					}
					auto* pending = new PendingEvent();
					pending->state = "start-finished";
					pending->errorCode = code;
					pending->message = message;
					pending->result = job.result;
					PostEvent(pending);
					break;
				}
				case TunnelJob::Kind::killSwitchMode: {
					// Written to the running helper, which rebuilds the firewall
					// rules in place. Nothing waits for an acknowledgement: the
					// app re-reads `killSwitchState`, which is the marker the
					// helper writes only after the rules are committed.
					std::string code;
					std::string message;
					bool sent = false;
					if (openVpn_.pipe != nullptr && openVpn_.started) {
						sent = phantrix::ovpn::WriteMessage(
						    openVpn_.pipe,
						    phantrix::ovpn::MakeMessage(
						        phantrix::ovpn::MessageType::kKillSwitch,
						        {job.killSwitch}));
					}
					if (!sent) {
						code = "kill_switch.no_tunnel";
						message =
						    "The kill switch cannot change while no tunnel is "
						    "running.";
					}
					auto* pending = new PendingEvent();
					pending->state = "start-finished";
					pending->errorCode = code;
					pending->message = message;
					pending->result = job.result;
					PostEvent(pending);
					break;
				}
				case TunnelJob::Kind::engageKillSwitch: {
					// Only without a tunnel: a running session already carries
					// its own rules and decides what stays when it ends.
					std::string code;
					std::string message;
					const bool sessionRunning =
					    openVpn_.pipe != nullptr || openVpn_.helper != nullptr;
					if (!sessionRunning && ReadKillSwitchMarker() != "strict") {
						(void)LaunchFirewallEngage(pluginDirectory(), &code,
						                           &message);
					}
					auto* pending = new PendingEvent();
					pending->state = "start-finished";
					pending->errorCode = code;
					pending->message = message;
					pending->result = job.result;
					PostEvent(pending);
					break;
				}
			}
		}
	}

	void Publish(const std::string& state) {
		if (!events_) {
			return;
		}
		EncodableMap map;
		map[EncodableValue("state")] = EncodableValue(state);
		events_->Success(EncodableValue(map));
	}

	void Fail(const std::string& code, const std::string& message) {
		if (!events_) {
			return;
		}
		EncodableMap map;
		map[EncodableValue("state")] = EncodableValue("failed");
		map[EncodableValue("errorCode")] = EncodableValue(code);
		map[EncodableValue("message")] = EncodableValue(message);
		events_->Success(EncodableValue(map));
	}

	// Reports the counters the engine wrote to its own status file.
	//
	// Called from the platform thread only, because the Flutter event sink is
	// not safe to call from anywhere else and this is the only place in the
	// OpenVPN path that will look like a "connected" reply to it.
	void PublishTraffic(int64_t rxBytes, int64_t txBytes, int64_t handshakeAtMillis);

	// Reports the engine's own handshake: its "Initialization Sequence
	// Completed" detection, forwarded by the helper as a state message.
	//
	// The state message is the handshake's first and most reliable report, and
	// it must be published here, not only the periodic counters: a plugin that
	// published only the counters would leave the app waiting for a state the
	// engine had already sent — until the app's deadline tore down a working
	// tunnel and the attempt loop relaunched the helper (and its elevation
	// prompt) over a tunnel that had connected every time.
	void PublishHandshaked(int64_t handshakeAtMillis);

	// Starts the OpenVPN engine through the elevated helper.
	//
	// Returns false with a code and a user-facing sentence. The profile is not
	// parsed here: it is written to a private file and its path, never its
	// contents, travels to the engine.
	bool StartOpenVpn(const std::string& profile, bool splitEnabled,
	                  const std::string& splitMode,
	                  const std::vector<std::string>& splitApps,
	                  const std::string& killSwitch, std::string* errorCode,
	                  std::string* errorMessage);

	// Sends one policy to the running helper and waits for its acknowledgement.
	//
	// The acknowledgement is the point: a write that succeeded only means the
	// bytes entered the pipe, not that the driver installed a filter. The method
	// result is completed from the platform thread when the helper answers.
	bool ApplySplitPolicy(bool enabled, const std::string& mode,
	                      const std::vector<std::string>& apps,
	                      std::string* errorCode, std::string* errorMessage);

	// Handles one message from the helper. Runs on the reader thread and fills
	// in the event that is posted to the platform thread.
	void OnHelperMessage(const phantrix::ovpn::Message& message,
	                    PendingEvent* pending);

	// Releases every resource the OpenVPN session holds: stops the engine,
	// waits for the helper, closes the pipe, removes the session directory.
	// Safe to call when nothing is running. `holdFirewall` asks the helper to
	// leave the kill switch blocking (a dropped connection, not a disconnect).
	void TeardownOpenVpn(bool holdFirewall = false);

	// The reader thread's entry point. Reads the pipe until it goes away,
	// forwarding each message to the platform thread.
	static DWORD WINAPI OpenVpnReaderThread(LPVOID context);

	// The message window's procedure. Runs on the platform thread, which is the
	// only thread allowed to touch the Flutter event sink, and looks the plugin
	// instance up from the window's user data.
	static LRESULT CALLBACK MessageWindowProc(HWND window, UINT message,
	                                          WPARAM wparam, LPARAM lparam);

	void Handle(const flutter::MethodCall<EncodableValue>& call,
	            std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
		const auto& method = call.method_name();

		if (method == "listInstalledApps") {
			// Enumerating the shell is the one part of this feature that can be
			// slow on a machine with many applications, so it runs on a worker
			// and answers through the same window every other cross-thread reply
			// uses. A list is not worth a frozen window.
			TunnelJob job;
			job.kind = TunnelJob::Kind::listApps;
			job.result = result.release();
			EnqueueJob(std::move(job));
			return;
		}

		if (method == "appIcon") {
			const auto* path = std::get_if<std::string>(call.arguments());
			if (path == nullptr || path->empty()) {
				result->Success(EncodableValue());
				return;
			}
			// Icon extraction costs a COM round trip and a PNG encode. It runs
			// on the worker for the same reason discovery does; the UI asks
			// only for rows it is about to draw.
			TunnelJob job;
			job.kind = TunnelJob::Kind::appIcon;
			job.text = *path;
			job.result = result.release();
			EnqueueJob(std::move(job));
			return;
		}

		if (method == "pickExecutable") {
			// The dialog needs an owner window and a message pump, so it stays
			// on the platform thread. It blocks that thread only while the user
			// is actually choosing, which is the one time a frozen window is
			// the dialog itself.
			const std::wstring chosen = PickExecutableFile();
			if (chosen.empty()) {
				result->Success(EncodableValue());
				return;
			}
			result->Success(EncodableValue(phantrix::ovpn::WideToUtf8(chosen)));
			return;
		}

		if (method == "capabilities") {
			// Honest about what this backend can actually do. The kill switch is
			// user-mode firewall rules the elevated helper installs, so it is
			// available whenever the engine is. Per-app routing needs the
			// bundled sing-box router as well.
			//
			// The engine is answered from what is on disk rather than from what
			// the build expects. The OpenVPN bundle is fetched and verified by
			// `tools/fetch_openvpn_bundle.ps1` before the build, so a supported
			// build has it; an unsupported one reports false and the Dart layer
			// refuses an OpenVPN server with an explanation instead of
			// attempting a tunnel that cannot start.
			const std::wstring directory = pluginDirectory();
			const bool openVpnPresent =
			    phantrix::ovpn::OpenVpnBundlePresent(directory);
			const bool splitDriverPresent = SplitRouterPresent(directory);
			const std::string engineName =
			    openVpnPresent ? "openvpn-community" : "none";
			std::string limitations;
			if (openVpnPresent) {
				limitations =
				    "OpenVPN tunnels run the official community openvpn.exe "
				    "through a small helper that asks for administrator rights; "
				    "the profile is written to a private file and the engine "
				    "reads that file, so IPv6 policy is whatever the server's "
				    "configuration carried. Split tunnelling routes each "
				    "application through the bundled sing-box router (no own "
				    "driver) and applies only while a tunnel is up. The kill "
				    "switch is Windows Filtering Platform rules; the local "
				    "network and DHCP stay reachable. "
				    "Windows' DNS client multiplexes every process through one "
				    "service, so per-application DNS cannot be separated; DNS "
				    "stays on the tunnel while split tunnelling is active.";
				if (!splitDriverPresent) {
					limitations +=
					    " The split-tunnel router is not bundled in this build.";
				}
			} else {
				limitations =
				    "The OpenVPN engine is not bundled in this build, so no "
				    "tunnel can be started. Use a build that bundles the "
				    "engine. There is no kill switch and no per-app routing.";
			}
			EncodableMap map;
			map[EncodableValue("platform")] = EncodableValue("windows");
			map[EncodableValue("killSwitch")] = EncodableValue(openVpnPresent);
			map[EncodableValue("ipv6Block")] = EncodableValue(false);
			map[EncodableValue("vpnDns")] = EncodableValue(true);
			map[EncodableValue("perApp")] =
			    EncodableValue(openVpnPresent && splitDriverPresent);
			map[EncodableValue("lanBypass")] = EncodableValue(false);
			map[EncodableValue("alwaysOn")] = EncodableValue(false);
			map[EncodableValue("tray")] = EncodableValue(false);
			// Start-on-boot is real here: a per-user entry in the shell's own
			// start-up list needs no administrator and no installer, which is
			// the whole cost of it.
			map[EncodableValue("bootStart")] = EncodableValue(true);
			map[EncodableValue("openVpn")] = EncodableValue(openVpnPresent);
			map[EncodableValue("engine")] = EncodableValue(engineName);
			map[EncodableValue("limitations")] = EncodableValue(limitations);
			result->Success(EncodableValue(map));
			return;
		}

		if (method == "setBootStart") {
			// Start-on-boot on Windows is one per-user value under the
			// shell's own start-up key — not a scheduled task and not a
			// service. It needs no administrator and it leaves no trace
			// once removed, which is exactly the amount of the system this
			// app is willing to touch.
			//
			// The stored command points at the executable that is running
			// right now rather than at an assumed install directory: that is
			// the copy of the app the user actually uses, wherever they
			// keep it.
			const bool* enabled = std::get_if<bool>(call.arguments());
			if (enabled == nullptr) {
				result->Error("boot.argument_missing",
				              "The start-up request said neither on nor off.",
				              nullptr);
				return;
			}
			HKEY key = nullptr;
			const LSTATUS opened = RegCreateKeyExW(
			    HKEY_CURRENT_USER,
			    L"Software\\Microsoft\\Windows\\CurrentVersion\\Run", 0,
			    nullptr, 0, KEY_SET_VALUE, nullptr, &key, nullptr);
			if (opened != ERROR_SUCCESS) {
				result->Error(
				    "boot.registry_failed",
				    "Windows would not open the start-up list for this account.",
				    nullptr);
				return;
			}
			LSTATUS written = ERROR_SUCCESS;
			if (*enabled) {
				std::vector<wchar_t> path(32768, L'\0');
				const DWORD length =
				    GetModuleFileNameW(nullptr, path.data(),
				                       static_cast<DWORD>(path.size()));
				if (length == 0 || length == path.size()) {
					written = ERROR_FILE_INVALID;
				} else {
					// Quoted: the installation directory may contain
					// spaces, which the shell would otherwise read as
					// argument separators.
					const std::wstring command =
					    L"\"" + std::wstring(path.data(), length) + L"\"";
					written = RegSetValueExW(
					    key, L"Phantrix", 0, REG_SZ,
					    reinterpret_cast<const BYTE*>(command.c_str()),
					    static_cast<DWORD>((command.size() + 1) *
					                       sizeof(wchar_t)));
				}
			} else {
				written = RegDeleteValueW(key, L"Phantrix");
				if (written == ERROR_FILE_NOT_FOUND) {
					// Nothing to remove is the state that was asked for.
					written = ERROR_SUCCESS;
				}
			}
			RegCloseKey(key);
			if (written != ERROR_SUCCESS) {
				result->Error("boot.registry_failed",
				              "Windows would not record the start-up entry.",
				              nullptr);
				return;
			}
			result->Success(EncodableValue(true));
			return;
		}

		if (method == "requestPermission") {
			// There is no separate consent step to ask about: the consent dialog
			// is raised at the moment the tunnel is created, by this app's helper
			// via `runas`. Reporting whether the engine is even present is the
			// useful answer.
			const std::wstring directory = pluginDirectory();
			result->Success(
			    EncodableValue(phantrix::ovpn::OpenVpnBundlePresent(directory)));
			return;
		}

		if (method == "applySplitTunnel") {
			// A live policy change is a pipe message, not a new tunnel. It is
			// refused when nothing is running: there is no interface to route
			// into, and answering success for rules that are not in force is
			// the one lie this feature cannot afford.
			const auto* root = std::get_if<EncodableMap>(call.arguments());
			if (root == nullptr || !openVpn_.started) {
				result->Error(
				    "split.not_connected",
				    "Split tunnelling can only be changed while a tunnel is "
				    "connected.");
				return;
			}
			TunnelJob job;
			job.kind = TunnelJob::Kind::splitPolicy;
			job.splitEnabled = false;
			if (const auto it = root->find(EncodableValue("enabled"));
			    it != root->end()) {
				if (const auto* value = std::get_if<bool>(&it->second)) {
					job.splitEnabled = *value;
				}
			}
			job.splitMode = getString(*root, "mode");
			if (const auto it = root->find(EncodableValue("apps"));
			    it != root->end()) {
				if (const auto* list = std::get_if<EncodableList>(&it->second)) {
					for (const EncodableValue& item : *list) {
						if (const auto* app = std::get_if<std::string>(&item)) {
							job.splitApps.push_back(*app);
						}
					}
				}
			}
			job.result = result.release();
			EnqueueJob(std::move(job));
			return;
		}

		if (method == "startTunnel") {
			// The request carries a complete serialized profile. Nothing else
			// can start a tunnel on this backend.
			const auto* root = std::get_if<EncodableMap>(call.arguments());
			const std::string ovpnConfig =
			    root == nullptr ? std::string() : getString(*root, "ovpnConfig");
			if (ovpnConfig.empty()) {
				const std::string message =
				    "The request carried no OpenVPN profile to run.";
				Fail("ovpn.config_invalid", message);
				result->Error("ovpn.config_invalid", message);
				return;
			}
			// The launch — the elevation prompt, the pipe handshake, the
			// profile write — waits on the system, sometimes for a long time.
			// It runs on the tunnel worker; the reply is posted back and
			// completed on this thread when the launch has actually resolved.
			TunnelJob job;
			job.kind = TunnelJob::Kind::start;
			job.profile = ovpnConfig;
			// The routing mode is carried by which list is present, which is
			// the shape the bridge has always described: a request names either
			// the apps that use the tunnel or the apps that bypass it, never
			// both. No list means split tunnelling stays off for this attempt.
			const std::vector<std::string> allowed =
			    getStrings(*root, "allowedApps");
			const std::vector<std::string> disallowed =
			    getStrings(*root, "disallowedApps");
			if (!allowed.empty() && disallowed.empty()) {
				job.splitEnabled = true;
				job.splitMode = "include";
				job.splitApps = allowed;
			} else if (!disallowed.empty() && allowed.empty()) {
				job.splitEnabled = true;
				job.splitMode = "exclude";
				job.splitApps = disallowed;
			}
			job.killSwitch = getString(*root, "killSwitch");
			job.result = result.release();
			EnqueueJob(std::move(job));
			return;
		}

		if (method == "killSwitchState") {
			// Whether kill-switch rules are installed right now, read from the
			// marker the helper keeps. No elevation needed.
			const std::string mode = ReadKillSwitchMarker();
			EncodableMap map;
			map[EncodableValue("active")] = EncodableValue(!mode.empty());
			map[EncodableValue("mode")] =
			    mode.empty() ? EncodableValue() : EncodableValue(mode);
			result->Success(EncodableValue(map));
			return;
		}

		if (method == "engageKillSwitch") {
			// Installs strict rules without a tunnel. Needs administrator
			// rights, so it runs on the worker like the release.
			TunnelJob job;
			job.kind = TunnelJob::Kind::engageKillSwitch;
			job.result = result.release();
			EnqueueJob(std::move(job));
			return;
		}

		if (method == "setKillSwitchMode") {
			TunnelJob job;
			job.kind = TunnelJob::Kind::killSwitchMode;
			if (const auto* root = std::get_if<EncodableMap>(call.arguments())) {
				job.killSwitch = getString(*root, "killSwitch");
			}
			job.result = result.release();
			EnqueueJob(std::move(job));
			return;
		}

		if (method == "releaseKillSwitch") {
			// Lifts the rules without a tunnel. Needs administrator rights, so
			// it runs on the worker: the consent prompt can take a while.
			TunnelJob job;
			job.kind = TunnelJob::Kind::releaseKillSwitch;
			job.result = result.release();
			EnqueueJob(std::move(job));
			return;
		}

		if (method == "stopTunnel") {
			// There is one engine, and stopping it when it is not up is a
			// bounded no-op — but the bound is the helper's own shutdown time,
			// which is not this thread's to spend. The worker tears the
			// session down and the reply follows it.
			//
			// Only reported once: a stop during a failed attempt has already
			// published `failed`, and a `disconnected` after it would tell the
			// user that a tunnel came down which never came up.
			TunnelJob job;
			job.kind = TunnelJob::Kind::stop;
			if (const auto* root = std::get_if<EncodableMap>(call.arguments())) {
				if (const auto it = root->find(EncodableValue("keepBlocking"));
				    it != root->end()) {
					if (const auto* value = std::get_if<bool>(&it->second)) {
						job.holdFirewall = *value;
					}
				}
			}
			job.result = result.release();
			job.publishDisconnected = !openVpnReportedFailure_;
			EnqueueJob(std::move(job));
			return;
		}

		if (method == "openVpnSettings") {
			// No single VPN settings page exists across Windows versions, and
			// opening an arbitrary one would be guesswork. The UI says so.
			Fail("unsupported", "Windows has no single VPN settings page to open.");
			result->Success();
			return;
		}

		if (method == "appDataDirectory") {
			// The per-user directory the app stores its settings and cached
			// profiles in. It has to come from the native side because only the
			// native side knows where the platform keeps it.
			const std::wstring directory = dataDirectory();
			if (directory.empty()) {
				result->Error(
						"app_directory",
						"The per-user application directory could not be created.",
						nullptr);
				return;
			}
			// The Windows channel carries narrow strings, so the wide path is
			// converted to UTF-8 explicitly. `%LOCALAPPDATA%` can contain a
			// non-ASCII account name, and a lossy conversion would silently
			// point the app at the wrong directory.
			const int needed = WideCharToMultiByte(
					CP_UTF8, 0, directory.c_str(), -1, nullptr, 0, nullptr, nullptr);
			if (needed <= 1) {
				result->Error(
						"app_directory",
						"The per-user application directory name could not be read.",
						nullptr);
				return;
			}
			std::string narrow(static_cast<size_t>(needed), '\0');
			WideCharToMultiByte(CP_UTF8, 0, directory.c_str(), -1, narrow.data(),
			                    needed, nullptr, nullptr);
			// Drop the terminator: `needed` counts it, but the string's length
			// must not.
			narrow.resize(static_cast<size_t>(needed - 1));
			result->Success(EncodableValue(narrow));
			return;
		}

		result->NotImplemented();
	}

	std::unique_ptr<flutter::MethodChannel<EncodableValue>> methodChannel_;
	std::unique_ptr<flutter::EventChannel<EncodableValue>> eventChannel_;
	std::unique_ptr<flutter::EventSink<EncodableValue>> events_;

	// The OpenVPN session, and the one bit of bookkeeping that is not inside
	// it: whether the reader thread has already reported a failure for this
	// attempt, so a later stop publishes exactly one outcome.
	OpenVpnSession openVpn_;
	bool openVpnReportedFailure_ = false;

	// The policy acknowledgement currently awaited, if any.
	std::mutex splitWaitMutex_;
	std::shared_ptr<SplitWait> splitWait_;

	// The message-only window every cross-thread report lands on. Created once
	// on the platform thread and never destroyed until the plugin is.
	HWND messageWindow_ = nullptr;

	// The tunnel worker: a thread and a queue, because everything that waits
	// on the helper must not wait on the platform thread.
	std::thread tunnelWorker_;
	std::mutex queueMutex_;
	std::condition_variable queueSignal_;
	std::deque<TunnelJob> queue_;
	bool stopping_ = false;
};

// ---------------------------------------------------------------------------
// The OpenVPN session's own methods
// ---------------------------------------------------------------------------

LRESULT CALLBACK PhantrixWindowsPlugin::MessageWindowProc(HWND window,
                                                         UINT message,
                                                         WPARAM wparam,
                                                         LPARAM lparam) {
	if (message != kTunnelMessageId) {
		return DefWindowProcW(window, message, wparam, lparam);
	}
	auto* pending = reinterpret_cast<PendingEvent*>(lparam);
	if (pending == nullptr) {
		return 0;
	}
	auto* plugin = reinterpret_cast<PhantrixWindowsPlugin*>(
	    GetWindowLongPtrW(window, GWLP_USERDATA));
	if (plugin == nullptr) {
		// The window outlived the plugin, which can only happen during teardown.
		// The event is dropped rather than answered from a stale pointer.
		delete pending;
		return 0;
	}
	if (pending->state == "split-result") {
		// The wait was answered on the reader thread; this thread only retires
		// the event. A refusal is already carried into the method result by the
		// worker that waited for it.
		delete pending;
		return 0;
	}
	if (pending->state == "value") {
		// A query answered on the worker: discovery, an icon, a policy change.
		if (pending->result != nullptr) {
			if (pending->hasPayload) {
				pending->result->Success(pending->payload);
			} else {
				pending->result->Success();
			}
			delete pending->result;
		}
		delete pending;
		return 0;
	}
	if (pending->state == "stopped") {
		// The worker has finished tearing the session down. The method reply
		// is completed now, on the platform thread, and the state follows.
		if (pending->result != nullptr) {
			pending->result->Success();
			delete pending->result;
		}
		if (pending->publishDisconnected && !plugin->openVpnReportedFailure_) {
			plugin->Publish("disconnected");
		}
		plugin->openVpnReportedFailure_ = false;
		delete pending;
		return 0;
	}
	if (pending->state == "start-finished") {
		// The engine launch resolved on the worker. A code means the launch
		// itself refused; otherwise the tunnel is merely starting, and whether
		// it connects is the helper's report to make, not this reply's.
		if (pending->result != nullptr) {
			if (pending->errorCode.empty()) {
				pending->result->Success();
			} else {
				pending->result->Error(pending->errorCode, pending->message);
			}
			delete pending->result;
		}
		delete pending;
		return 0;
	}
	if (pending->state == "traffic") {
		plugin->PublishTraffic(pending->rxBytes, pending->txBytes,
		                       pending->handshakeAtMillis);
	} else if (pending->state == "handshaked") {
		// The engine's handshake report. Without this branch the state fell
		// through every case below and was silently dropped: the app stayed in
		// "Negotiating" against a tunnel that had connected, and its deadline
		// then tore that tunnel down and started again — the loop of elevation
		// prompts that never reached "Connected".
		plugin->PublishHandshaked(pending->handshakeAtMillis);
	} else if (pending->state == "disconnected") {
		plugin->openVpn_.disconnected = true;
		plugin->Publish("disconnected");
	} else if (pending->state == "reconnecting") {
		plugin->Publish("reconnecting");
	} else if (pending->state == "established") {
		plugin->Publish("established");
	} else if (pending->state == "connecting") {
		plugin->Publish("connecting");
	} else if (pending->state == "disconnecting") {
		plugin->Publish("disconnecting");
	} else if (pending->state == "preparing") {
		plugin->Publish("preparing");
	} else if (!pending->errorCode.empty()) {
		plugin->openVpnReportedFailure_ = true;
		plugin->Fail(pending->errorCode, pending->message);
	}
	if (plugin->openVpn_.disconnected || plugin->openVpnReportedFailure_) {
		// Nothing further is expected from the helper for this attempt: it has
		// either torn the tunnel down or reported that it failed. The session
		// is released, but by the worker: the teardown waits on the helper's
		// exit, and waiting here would be the window hanging on its own
		// thread — the freeze that made a failed attempt feel like a crash.
		// A connection that had come up and then failed is a drop: the kill
		// switch keeps blocking until the user reconnects or disconnects. One
		// that never came up is released (strict mode keeps it regardless).
		TunnelJob job{TunnelJob::Kind::teardownOnly};
		job.holdFirewall = plugin->openVpnReportedFailure_ &&
		                   plugin->openVpn_.handshakeAtMillis > 0;
		plugin->EnqueueJob(std::move(job));
	}
	delete pending;
	return 0;
}

DWORD WINAPI PhantrixWindowsPlugin::OpenVpnReaderThread(LPVOID context) {
	auto* plugin = reinterpret_cast<PhantrixWindowsPlugin*>(context);
	// The pipe is read here and written from the platform thread, so the read is
	// overlapped: a pending *blocking* read on a handle holds that handle's file
	// lock, which would make a write from the platform thread — the stop, for
	// instance — hang. This is not a theoretical concern: it is what a disconnect
	// would deadlock on.
	HANDLE pipe = plugin->openVpn_.pipe;
	std::vector<uint8_t> carry;
	// Whether the helper itself has already said how this attempt ended. The
	// end of the stream after such a word is not a helper that vanished
	// without reporting — it is the quiet that follows the report.
	bool reported = false;
	uint8_t buffer[4096] = {0};
	OVERLAPPED overlap = {0};
	overlap.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
	for (;;) {
		ResetEvent(overlap.hEvent);
		DWORD read = 0;
		const BOOL ok = ReadFile(pipe, buffer, sizeof(buffer), &read, &overlap);
		const DWORD error = ok == FALSE ? GetLastError() : ERROR_SUCCESS;
		if (error == ERROR_IO_PENDING) {
			HANDLE waits[2] = {overlap.hEvent, plugin->openVpn_.readerStop};
			const DWORD waited = WaitForMultipleObjects(2, waits, FALSE, INFINITE);
			if (waited == WAIT_OBJECT_0 + 1) {
				break;
			}
			if (GetOverlappedResult(pipe, &overlap, &read, FALSE) == FALSE) {
				break;
			}
		} else if (error != ERROR_SUCCESS) {
			break;
		}
		if (read == 0) {
			break;
		}
		carry.insert(carry.end(), buffer, buffer + read);
		for (;;) {
			phantrix::ovpn::Message message;
			if (!phantrix::ovpn::TakeMessage(&carry, &message)) {
				break;
			}
			auto* pending = new PendingEvent();
			plugin->OnHelperMessage(message, pending);
			if (pending->state == "failed" ||
			    pending->state == "disconnected") {
				reported = true;
			}
			plugin->PostEvent(pending);
		}
		if (plugin->openVpn_.stopping) {
			break;
		}
	}
	CancelIo(pipe);
	CloseHandle(overlap.hEvent);
	if (plugin->openVpn_.stopping || reported) {
		// The end of the stream was asked for, or already answered. A stop is
		// waiting on this reader, or the helper has said how the attempt
		// ended. Posting `helper_lost` on top of that told the user "The
		// tunnel helper stopped without reporting a result" about a helper
		// that had just reported one — which is how every deliberate
		// disconnect read.
		return 0;
	}
	// End of stream without a word. If the helper went away without tearing
	// anything down, the engine may still be running; that is reported as a
	// failure rather than left as silence.
	auto* pending = new PendingEvent();
	pending->state = "failed";
	pending->errorCode = "ovpn.helper_lost";
	pending->message = "The tunnel helper stopped without reporting a result.";
	plugin->PostEvent(pending);
	return 0;
}
void PhantrixWindowsPlugin::TeardownOpenVpn(bool holdFirewall) {
	if (openVpn_.pipe == nullptr && openVpn_.helper == nullptr &&
	    openVpn_.reader == nullptr) {
		// Nothing was ever started. Cheap out rather than doing the I/O below.
		if (!openVpn_.session.empty()) {
			(void)phantrix::ovpn::RemoveTree(openVpn_.session);
			openVpn_.session.clear();
		}
		return;
	}

	if (openVpn_.pipe != nullptr && openVpn_.pipe != INVALID_HANDLE_VALUE) {
		if (!openVpn_.stopping && openVpn_.started) {
			// Ask the helper to stop the engine and tell us when it has.
			phantrix::ovpn::Message stop = phantrix::ovpn::MakeMessage(
			    phantrix::ovpn::MessageType::kStop,
			    holdFirewall ? std::vector<std::string>{"hold"}
			                 : std::vector<std::string>{});
			(void)phantrix::ovpn::WriteMessage(openVpn_.pipe, stop);
		}
	}
	// The reader is stopped before the pipe is closed, because a handle with a
	// pending read cannot be torn down cleanly by closing it.
	openVpn_.stopping = true;
	if (openVpn_.readerStop != nullptr) {
		SetEvent(openVpn_.readerStop);
	}
	if (openVpn_.reader != nullptr) {
		WaitForSingleObject(openVpn_.reader, kHelperStopTimeoutMillis);
		CloseHandle(openVpn_.reader);
		openVpn_.reader = nullptr;
	}

	if (openVpn_.pipe != nullptr && openVpn_.pipe != INVALID_HANDLE_VALUE) {
		CloseHandle(openVpn_.pipe);
		openVpn_.pipe = nullptr;
	}
	if (openVpn_.readerStop != nullptr) {
		CloseHandle(openVpn_.readerStop);
		openVpn_.readerStop = nullptr;
	}

	if (openVpn_.helper != nullptr) {
		// The helper exits on its own once the engine is gone. The wait is
		// bounded, and a helper that outlives it is killed: an elevated process
		// with no peer to talk to is exactly what must not survive.
		if (WaitForSingleObject(openVpn_.helper, kHelperStopTimeoutMillis) !=
		    WAIT_OBJECT_0) {
			TerminateProcess(openVpn_.helper, 1);
		}
		CloseHandle(openVpn_.helper);
		openVpn_.helper = nullptr;
	}

	// The session directory holds the profile, which holds the user's key, and
	// the engine's own log. It does not outlive the tunnel it belonged to —
	// but the engine log's words outlive the tunnel: the last few sessions'
	// logs are archived under the app's private logs directory first, so a
	// failure stays diagnosable after the profile that caused it is gone.
	if (!openVpn_.session.empty()) {
		phantrix::ovpn::ArchiveEngineLog(openVpn_.session + L"\\openvpn.log");
		(void)phantrix::ovpn::RemoveTree(openVpn_.session);
		openVpn_.session.clear();
	}

	openVpn_.started = false;
	openVpn_.stopping = false;
	openVpn_.token.clear();
	openVpn_.profile.clear();
	openVpn_.status.clear();
	openVpn_.log.clear();
	openVpn_.auth.clear();
	openVpn_.rxBytes = 0;
	openVpn_.txBytes = 0;
	openVpn_.handshakeAtMillis = 0;
	openVpn_.disconnected = false;
}

void PhantrixWindowsPlugin::OnHelperMessage(
    const phantrix::ovpn::Message& message, PendingEvent* pending) {
	const auto& fields = message.fields;
	const auto field = [&fields](size_t index) -> std::string {
		return index < fields.size() ? fields[index] : std::string();
	};
	switch (message.type) {
		case phantrix::ovpn::MessageType::kStarted: {
			openVpn_.started = true;
			pending->state = "connecting";
			return;
		}
		case phantrix::ovpn::MessageType::kState: {
			const std::string& state = field(0);
			openVpn_.handshakeAtMillis = std::atoll(field(1).c_str());
			pending->state = state;
			pending->handshakeAtMillis = openVpn_.handshakeAtMillis;
			return;
		}
		case phantrix::ovpn::MessageType::kTraffic: {
			openVpn_.rxBytes = std::atoll(field(0).c_str());
			openVpn_.txBytes = std::atoll(field(1).c_str());
			pending->state = "traffic";
			pending->hasTraffic = true;
			pending->rxBytes = openVpn_.rxBytes;
			pending->txBytes = openVpn_.txBytes;
			pending->handshakeAtMillis = openVpn_.handshakeAtMillis;
			return;
		}
		case phantrix::ovpn::MessageType::kFailed: {
			pending->state = "failed";
			pending->errorCode = field(0);
			pending->message = field(1);
			return;
		}
		case phantrix::ovpn::MessageType::kDisconnected: {
			openVpn_.disconnected = true;
			pending->state = "disconnected";
			return;
		}
		case phantrix::ovpn::MessageType::kSplitApplied: {
			// The helper answers the policy request it was sent. The update is
			// delivered to whichever worker is waiting, then the platform thread
			// is told so the event can be retired.
			const bool ok = field(0) == "1";
			const std::string code = field(1);
			const std::string splitMessage = field(2);
			std::shared_ptr<SplitWait> wait;
			{
				std::lock_guard<std::mutex> lock(splitWaitMutex_);
				wait = splitWait_;
			}
			if (wait != nullptr) {
				std::lock_guard<std::mutex> lock(wait->mutex);
				wait->done = true;
				wait->ok = ok;
				wait->code = code;
				wait->message = splitMessage;
				wait->ready.notify_all();
			}
			pending->state = "split-result";
			pending->errorCode = ok ? std::string() : code;
			pending->message = splitMessage;
			return;
		}
		default:
			// A message this plugin has no response to. The helper only sends the
			// types above, so reaching here means the two sides disagree.
			pending->state = "ignored";
			return;
	}
}

void PhantrixWindowsPlugin::PublishTraffic(int64_t rxBytes, int64_t txBytes,
                                           int64_t handshakeAtMillis) {
	if (!events_) {
		return;
	}
	// A repeated `handshaked` with counters attached. The guard in the Dart
	// state machine means an already-verified connection is not re-verified; the
	// point of the repetition is the counters, which otherwise freeze on the
	// first reading and read as fabricated numbers.
	EncodableMap map;
	map[EncodableValue("state")] = EncodableValue("handshaked");
	EncodableMap traffic;
	traffic[EncodableValue("rx")] = EncodableValue(rxBytes);
	traffic[EncodableValue("tx")] = EncodableValue(txBytes);
	map[EncodableValue("traffic")] = EncodableValue(traffic);
	if (handshakeAtMillis > 0) {
		map[EncodableValue("lastHandshakeAtMillis")] =
		    EncodableValue(handshakeAtMillis);
	}
	events_->Success(EncodableValue(map));
}

void PhantrixWindowsPlugin::PublishHandshaked(int64_t handshakeAtMillis) {
	if (!events_) {
		return;
	}
	EncodableMap map;
	map[EncodableValue("state")] = EncodableValue("handshaked");
	if (handshakeAtMillis > 0) {
		map[EncodableValue("lastHandshakeAtMillis")] =
		    EncodableValue(handshakeAtMillis);
	}
	events_->Success(EncodableValue(map));
}

bool PhantrixWindowsPlugin::ApplySplitPolicy(
    bool enabled, const std::string& mode,
    const std::vector<std::string>& apps, std::string* errorCode,
    std::string* errorMessage) {
	if (openVpn_.pipe == nullptr || openVpn_.pipe == INVALID_HANDLE_VALUE ||
	    !openVpn_.started) {
		*errorCode = "split.not_connected";
		*errorMessage =
		    "Split tunnelling can only be changed while a tunnel is connected.";
		return false;
	}
	if (enabled && mode != "include" && mode != "exclude") {
		*errorCode = "split.policy_rejected";
		*errorMessage = "The split-tunnel request named no routing mode.";
		return false;
	}
	auto wait = std::make_shared<SplitWait>();
	{
		std::lock_guard<std::mutex> lock(splitWaitMutex_);
		splitWait_ = wait;
	}
	std::vector<std::string> fields = {enabled ? "1" : "0", mode};
	fields.insert(fields.end(), apps.begin(), apps.end());
	if (!phantrix::ovpn::WriteMessage(
	        openVpn_.pipe,
	        phantrix::ovpn::MakeMessage(
	            phantrix::ovpn::MessageType::kSplitPolicy, fields))) {
		{
			std::lock_guard<std::mutex> lock(splitWaitMutex_);
			if (splitWait_ == wait) {
				splitWait_.reset();
			}
		}
		*errorCode = "ovpn.helper_lost";
		*errorMessage = "The tunnel helper stopped before the policy arrived.";
		return false;
	}
	bool ok = false;
	{
		std::unique_lock<std::mutex> lock(wait->mutex);
		const bool answered =
		    wait->ready.wait_for(lock, std::chrono::seconds(30),
		                         [&wait] { return wait->done; });
		if (answered) {
			ok = wait->ok;
			if (!ok) {
				*errorCode = wait->code.empty() ? "split.policy_rejected"
				                                : wait->code;
				*errorMessage = wait->message.empty()
				                    ? "The platform refused the split-tunnel policy."
				                    : wait->message;
			}
		}
	}
	{
		std::lock_guard<std::mutex> lock(splitWaitMutex_);
		if (splitWait_ == wait) {
			splitWait_.reset();
		}
	}
	if (!ok && errorCode->empty()) {
		*errorCode = "split.policy_timeout";
		*errorMessage =
		    "The split-tunnel driver did not confirm the policy in time.";
	}
	return ok;
}

bool PhantrixWindowsPlugin::StartOpenVpn(const std::string& profile,
                                         bool splitEnabled,
                                         const std::string& splitMode,
                                         const std::vector<std::string>& splitApps,
                                         const std::string& killSwitch,
                                         std::string* errorCode,
                                         std::string* errorMessage) {
	// A second request must not create a second tunnel. The first is still
	// running, and the second is refused rather than allowed to fight it for the
	// default route.
	if (openVpn_.started) {
		*errorCode = "ovpn.already_running";
		*errorMessage = "A tunnel is already running.";
		return false;
	}

	// The profile may not ask the engine to do something this backend will not
	// do for it. Dart already validated it; this is the check on the side that
	// is about to hand the file to an elevated process.
	phantrix::ovpn::ProfileRejection rejection = {nullptr, nullptr};
	if (!phantrix::ovpn::RejectUnsafeDirectives(profile, &rejection)) {
		*errorCode = rejection.code;
		*errorMessage = std::string("The server's configuration asks for something "
		                            "Phantrix will not do: it ") +
		               rejection.reason + std::string(".");
		return false;
	}

	const std::wstring directory = pluginDirectory();
	if (directory.empty()) {
		*errorCode = "backend.not_installed";
		*errorMessage = "The tunnel helper could not be located.";
		return false;
	}
	if (!phantrix::ovpn::OpenVpnBundlePresent(directory)) {
		*errorCode = "backend.not_installed";
		*errorMessage =
		    "The OpenVPN engine is not bundled in this build, so no tunnel can "
		    "be started. Use a build that bundles the engine.";
		return false;
	}

	// The token identifies this session to the helper and names its scratch
	// directory. Generated here, passed on the helper's command line, and echoed
	// back by it as proof it is the process that was launched.
	const std::wstring token = phantrix::ovpn::RandomToken();
	if (token.empty()) {
		*errorCode = "ovpn.token_failed";
		*errorMessage = "The operating system could not produce a session token.";
		return false;
	}
	openVpn_.token = token;

	openVpn_.session = phantrix::ovpn::SessionDirectory(L"session-" + token);
	if (openVpn_.session.empty()) {
		*errorCode = "ovpn.paths_missing";
		*errorMessage = "A private directory for the tunnel could not be created.";
		return false;
	}
	// The session directory is where the profile, the status file and the log
	// live. It is created with an owner-only DACL, so the configuration is not
	// readable by any other account while the helper holds it.
	//
	// The three paths are all inside this one directory, and the helper refuses a
	// start request whose paths are not, so the app cannot make an elevated
	// process read a file it did not choose.
	openVpn_.profile = openVpn_.session + L"\\phantrix.ovpn";
	openVpn_.status = openVpn_.session + L"\\status.txt";
	openVpn_.log = openVpn_.session + L"\\openvpn.log";
	openVpn_.auth = openVpn_.session + L"\\phantrix.auth";
	if (!phantrix::ovpn::WriteRestrictedFile(openVpn_.profile, profile)) {
		// An unsecurable profile is not connected with, and is not left behind.
		(void)phantrix::ovpn::RemoveTree(openVpn_.session);
		openVpn_.session.clear();
		*errorCode = "ovpn.config_invalid";
		*errorMessage = "The tunnel configuration could not be secured on disk.";
		return false;
	}

	// The credential file is an add-on, never a precondition. Whether the
	// engine actually passes `--auth-user-pass` depends on what the relay's
	// own profile asks, which only the engine can see; failing the start over
	// a scratch file the engine may not even use would be the wrong order.
	if (!phantrix::ovpn::WriteRestrictedFile(openVpn_.auth,
	                                         "vpn\nvpn\n")) {
		openVpn_.auth.clear();
	}

	// The pipe is created before the helper is launched, so the helper's
	// connection is not a race against the app's own readiness.
	const std::wstring pipeName = phantrix::ovpn::MakePipeName();
	if (pipeName.empty()) {
		(void)phantrix::ovpn::RemoveTree(openVpn_.session);
		openVpn_.session.clear();
		*errorCode = "ovpn.pipe_failed";
		*errorMessage = "The tunnel's private channel could not be created.";
		return false;
	}
	const std::wstring descriptor =
	    phantrix::ovpn::PipeSecurityDescriptorString();
	if (descriptor.empty()) {
		(void)phantrix::ovpn::RemoveTree(openVpn_.session);
		openVpn_.session.clear();
		*errorCode = "ovpn.pipe_failed";
		*errorMessage = "The tunnel's private channel could not be secured.";
		return false;
	}
	PSECURITY_DESCRIPTOR security = nullptr;
	if (ConvertStringSecurityDescriptorToSecurityDescriptorW(
	        descriptor.c_str(), SDDL_REVISION_1, &security, nullptr) == FALSE) {
		(void)phantrix::ovpn::RemoveTree(openVpn_.session);
		openVpn_.session.clear();
		*errorCode = "ovpn.pipe_failed";
		*errorMessage = "The tunnel's private channel could not be secured.";
		return false;
	}
	SECURITY_ATTRIBUTES attributes = {0};
	attributes.nLength = sizeof(attributes);
	attributes.lpSecurityDescriptor = security;
	attributes.bInheritHandle = FALSE;
	openVpn_.pipe = CreateNamedPipeW(
	    pipeName.c_str(), PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED,
	    PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT, 1, 64 * 1024, 64 * 1024,
	    0, &attributes);
	LocalFree(security);
	if (openVpn_.pipe == INVALID_HANDLE_VALUE) {
		(void)phantrix::ovpn::RemoveTree(openVpn_.session);
		openVpn_.session.clear();
		*errorCode = "ovpn.pipe_failed";
		*errorMessage = "The tunnel's private channel could not be created.";
		return false;
	}
	openVpn_.readerStop = CreateEventW(nullptr, TRUE, FALSE, nullptr);
	if (openVpn_.readerStop == nullptr) {
		CloseHandle(openVpn_.pipe);
		openVpn_.pipe = nullptr;
		(void)phantrix::ovpn::RemoveTree(openVpn_.session);
		openVpn_.session.clear();
		*errorCode = "backend.launch_failed";
		*errorMessage = "The tunnel's private channel could not be created.";
		return false;
	}

	// The message window belongs to the plugin, created once on the platform
	// thread when the plugin was; nothing to create per session.

	if (!LaunchHelper(directory, pipeName, token, GetCurrentProcessId(),
	                  &openVpn_.helper, errorCode, errorMessage)) {
		openVpn_.helper = nullptr;
		TeardownOpenVpn();
		return false;
	}

	// Wait for the helper to connect before writing anything.
	//
	// A pipe instance that no client has connected to rejects writes rather
	// than buffering them, and the helper connects only after it has been
	// launched — which, with `runas`, means after the consent dialog has been
	// answered. Writing the hello message before the connection therefore fails
	// silently, and the helper never authenticates.
	//
	// The wait is overlapped and bounded — up to `kHelperStartTimeoutMillis`,
	// long enough to cover the consent dialog — and it is the tunnel worker's
	// wait, not the platform thread's: a window that cannot repaint for ninety
	// seconds is indistinguishable from a crash.
	HANDLE connected = CreateEventW(nullptr, TRUE, FALSE, nullptr);
	if (connected == nullptr) {
		TeardownOpenVpn();
		*errorCode = "backend.launch_failed";
		*errorMessage = "The tunnel's private channel could not be waited for.";
		return false;
	}
	OVERLAPPED overlap = {0};
	overlap.hEvent = connected;
	if (ConnectNamedPipe(openVpn_.pipe, &overlap) == FALSE) {
		const DWORD connectError = GetLastError();
		if (connectError == ERROR_IO_PENDING) {
			if (WaitForSingleObject(connected, kHelperStartTimeoutMillis) !=
			    WAIT_OBJECT_0) {
				CloseHandle(connected);
				TeardownOpenVpn();
				*errorCode = "ovpn.helper_lost";
				*errorMessage =
				    "The tunnel helper did not connect. Windows may have refused "
				    "to start it, or the consent dialog may still be open.";
				return false;
			}
		} else if (connectError != ERROR_PIPE_CONNECTED) {
			// ERROR_PIPE_CONNECTED means a client connected before this call,
			// which is a success rather than a failure. Anything else is not.
			CloseHandle(connected);
			TeardownOpenVpn();
			*errorCode = "ovpn.helper_lost";
			*errorMessage =
			    "The tunnel helper could not be reached on its private channel.";
			return false;
		}
	}
	CloseHandle(connected);

	// The helper echoes the token before it accepts any other instruction, so
	// the plugin is only ever talking to the process it launched.
	if (!phantrix::ovpn::WriteMessage(
	        openVpn_.pipe,
	        phantrix::ovpn::MakeMessage(phantrix::ovpn::MessageType::kHello,
	                                    {phantrix::ovpn::WideToUtf8(token)}))) {
		*errorCode = "ovpn.helper_lost";
		*errorMessage = "The tunnel helper stopped before it started the engine.";
		TeardownOpenVpn();
		return false;
	}

	std::vector<std::string> startFields = {
	    phantrix::ovpn::WideToUtf8(openVpn_.profile),
	    phantrix::ovpn::WideToUtf8(openVpn_.status),
	    phantrix::ovpn::WideToUtf8(openVpn_.log),
	    splitEnabled ? "1" : "0",
	    splitEnabled ? splitMode : std::string(),
	    killSwitch.empty() ? std::string("off") : killSwitch,
	};
	if (splitEnabled) {
		startFields.insert(startFields.end(), splitApps.begin(),
		                   splitApps.end());
	}
	if (!phantrix::ovpn::WriteMessage(
	        openVpn_.pipe,
	        phantrix::ovpn::MakeMessage(phantrix::ovpn::MessageType::kStart,
	                                    startFields))) {
		*errorCode = "ovpn.helper_lost";
		*errorMessage = "The tunnel helper stopped before it started the engine.";
		TeardownOpenVpn();
		return false;
	}

	// The engine is starting. Whether it ever connects is not known here, and is
	// not claimed: the helper reports that when the engine says so.
	//
	// Posted before the reader thread starts, so the two arrive in the order
	// they always have — the reader's own reports queue up behind them — and
	// posted rather than published because this now runs on the tunnel worker,
	// and the Flutter event sink is only safe on the platform thread.
	auto* preparing = new PendingEvent();
	preparing->state = "preparing";
	PostEvent(preparing);
	auto* connecting = new PendingEvent();
	connecting->state = "connecting";
	PostEvent(connecting);

	openVpn_.reader = CreateThread(nullptr, 0, OpenVpnReaderThread, this, 0, nullptr);
	if (openVpn_.reader == nullptr) {
		*errorCode = "backend.launch_failed";
		*errorMessage = "The tunnel helper could not be monitored.";
		TeardownOpenVpn();
		return false;
	}
	return true;
}

void PhantrixPluginRegisterWithRegistrar(FlutterDesktopPluginRegistrarRef registrar) {
	PhantrixWindowsPlugin::RegisterWithRegistrar(
			flutter::PluginRegistrarManager::GetInstance()
					->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
