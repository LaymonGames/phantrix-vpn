// Windows tunnel backend for Phantrix.
//
// ## What this does
//
// Drives two engines, and implements neither of them:
//
//   1. the **official WireGuard for Windows** service (`wireguard.exe`), which
//      is the implementation every other Windows VPN product builds on;
//   2. the **official OpenVPN 2.6 community** binaries (`openvpn.exe` plus
//      wintun), bundled into the app next to this plugin.
//
// This file contains no cryptography, no packet handling and no protocol logic.
// Its job is to write a configuration Phantrix has already validated to a file
// in the app's own per-user directory, start the engine, and report back what
// the engine itself said so the UI never guesses.
//
// ## Privilege
//
// Both engines need Administrator. `wireguard.exe /installtunnelservice` is a
// service-manager operation; `openvpn.exe` creates the TUN adapter and
// installs routes. This code never elevates itself and never runs elevated.
//
// Instead, the OpenVPN path launches a **separate helper program**
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
// The OpenVPN profile is written by Dart from a configuration that has already
// passed parsing and validation. It is handed to this code as one string
// (`ovpnConfig`), written to a private file, and its path — never its contents
// — travels to the engine on the command line. A newline inside a value could
// append a directive to an elevated configuration, so the native side re-checks
// the profile for execution-capable directives before it is used, in the helper
// as well as here.
//
// The WireGuard configuration file is read by a process running as LocalSystem,
// and goes through the same treatment: every value is stripped of newlines and
// written on its own line.
//
// ## Tunnel name
//
// Fixed, never caller-supplied, so no request can make an engine act on an
// arbitrary installed tunnel or adapter.

#include <phantrix_platform/phantrix_plugin.h>

#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/method_call.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <flutter/event_stream_handler.h>
#include <flutter/event_stream_handler_functions.h>
#include <windows.h>
#include <shellapi.h>
#include <tchar.h>

#include <aclapi.h>
#include <sddl.h>

#include <cstdlib>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

#include "phantrix_ovpn_support.h"

#pragma comment(lib, "Advapi32.lib")
#pragma comment(lib, "Shell32.lib")

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

constexpr char kMethodChannel[] = "dev.phantrix.phantrix/tunnel";
constexpr char kEventChannel[] = "dev.phantrix.phantrix/tunnelEvents";
constexpr wchar_t kTunnelName[] = L"Phantrix";

// How long the app waits for the elevated helper to acknowledge that the engine
// is running before the attempt is reported as failed. Covers the UAC prompt
// and OpenVPN's own start-up, which on a cold machine includes opening the
// adapter. It is a timeout, not an estimate: a stuck launch is a failure, and a
// failure is recoverable in a way "connecting" forever is not.
constexpr DWORD kHelperStartTimeoutMillis = 90000;

// How long to wait for the helper to finish tearing the tunnel down.
constexpr DWORD kHelperStopTimeoutMillis = 20000;

// How often the WireGuard monitor asks `wg.exe` for the tunnel's handshake and
// counters. Short enough that a completed handshake reaches the UI promptly,
// long enough that polling is not a background load.
constexpr DWORD kWireGuardPollMillis = 1000;

// How long one `wg.exe` query may take before it is killed. `wg show` is a local
// query and answers in milliseconds; the bound exists so a wedged process cannot
// hold the poller, or the stop that waits for it, indefinitely.
constexpr DWORD kWireGuardQueryTimeoutMillis = 4000;

struct WireGuardInterface {
	std::string privateKey;
	std::vector<std::string> addresses;
	std::vector<std::string> dns;
	int mtu = 0;
};

struct WireGuardPeer {
	std::string publicKey;
	std::string presharedKey;
	std::string endpointHost;
	int endpointPort = 0;
	std::vector<std::string> allowedIps;
	int persistentKeepalive = 0;
};

// Strips anything that could terminate a line in a system-privileged file.
std::string sanitize(const std::string& value) {
	std::string out;
	out.reserve(value.size());
	for (const char c : value) {
		if (c == '\n' || c == '\r' || c == '\0') {
			continue;
		}
		out.push_back(c);
	}
	return out;
}

// The app's per-user data directory, without a file name.
//
// %LOCALAPPDATA% rather than a directory beside the executable: a location
// under Program Files is shared by every account on the machine, and a
// configuration file contains a private key.
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

std::wstring configPath() {
	std::wstring directory = dataDirectory();
	if (directory.empty()) {
		return std::wstring();
	}
	return directory + L"\\" + kTunnelName + L".conf";
}

// Locates the official WireGuard service client.
//
// Only the two documented install locations are checked. The path is never
// taken from PATH or from the request, so a poisoned environment cannot make
// this execute an attacker-chosen binary.
std::wstring findWireGuardExe() {
	const wchar_t* candidates[] = {
	    L"C:\\Program Files\\WireGuard\\wireguard.exe",
	    L"C:\\Program Files (x86)\\WireGuard\\wireguard.exe",
	};
	for (const auto* candidate : candidates) {
		if (GetFileAttributesW(candidate) != INVALID_FILE_ATTRIBUTES) {
			return candidate;
		}
	}
	return std::wstring();
}

// Locates the official WireGuard for Windows command-line client.
//
// `wg.exe` ships in the same directory as `wireguard.exe` and is the only
// program this backend parses the output of. Like `findWireGuardExe`, only the
// two documented install locations are checked and the path never comes from
// PATH or from the request.
std::wstring findWireGuardCli() {
	const wchar_t* candidates[] = {
	    L"C:\\Program Files\\WireGuard\\wg.exe",
	    L"C:\\Program Files (x86)\\WireGuard\\wg.exe",
	};
	for (const auto* candidate : candidates) {
		if (GetFileAttributesW(candidate) != INVALID_FILE_ATTRIBUTES) {
			return candidate;
		}
	}
	return std::wstring();
}

// Runs a command with no console window and a bounded wait.
//
// WireGuard's stdout is not a contract and can contain the configuration path,
// so it is discarded rather than surfaced.
DWORD runSilently(const std::wstring& command) {
	STARTUPINFOW startup = {0};
	startup.cb = sizeof(startup);
	PROCESS_INFORMATION process = {0};
	std::wstring buffer = command;
	if (!CreateProcessW(nullptr, buffer.data(), nullptr, nullptr, FALSE, CREATE_NO_WINDOW,
	                    nullptr, nullptr, &startup, &process)) {
		return 0xFFFFFFFF;
	}
	WaitForSingleObject(process.hProcess, 60000);
	DWORD code = 0;
	GetExitCodeProcess(process.hProcess, &code);
	CloseHandle(process.hThread);
	CloseHandle(process.hProcess);
	return code;
}

// Runs a command and captures its standard output.
//
// The one program whose output this backend reads is `wg.exe`, and only in its
// `dump` form, which is documented and machine-readable. The capture is bounded
// twice over — the stored bytes are capped, and the process is killed if it
// outlives `timeoutMillis` — so a wedged process can neither grow the app's
// memory nor hold the polling thread forever.
//
// Returns the process exit code, or 0xFFFFFFFF when it could not be started, did
// not finish in time, or its output could not be read.
DWORD runCapture(const std::wstring& command, std::string* output,
                 DWORD timeoutMillis) {
	output->clear();
	constexpr size_t kMaxOutput = 256 * 1024;

	// The read end is made non-inheritable: if the child inherited it, the pipe
	// would stay open after the child exited and the read below would wait for
	// an end-of-file that never comes.
	SECURITY_ATTRIBUTES attributes = {0};
	attributes.nLength = sizeof(attributes);
	attributes.bInheritHandle = TRUE;
	HANDLE readPipe = nullptr;
	HANDLE writePipe = nullptr;
	if (!CreatePipe(&readPipe, &writePipe, &attributes, 0)) {
		return 0xFFFFFFFF;
	}
	SetHandleInformation(readPipe, HANDLE_FLAG_INHERIT, 0);

	// `wg.exe` reads nothing, but its standard input must still be a valid
	// handle; without one it would inherit whatever console the app was started
	// from, which is exactly the kind of handle a background query must not
	// carry.
	HANDLE nullInput = CreateFileW(L"NUL", GENERIC_READ,
	                               FILE_SHARE_READ | FILE_SHARE_WRITE, &attributes,
	                               OPEN_EXISTING, 0, nullptr);

	STARTUPINFOW startup = {0};
	startup.cb = sizeof(startup);
	startup.dwFlags = STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW;
	startup.wShowWindow = SW_HIDE;
	startup.hStdInput = nullInput == INVALID_HANDLE_VALUE ? nullptr : nullInput;
	startup.hStdOutput = writePipe;
	startup.hStdError = writePipe;

	PROCESS_INFORMATION process = {0};
	std::wstring buffer = command;
	const BOOL started =
	    CreateProcessW(nullptr, buffer.data(), nullptr, nullptr, TRUE,
	                   CREATE_NO_WINDOW, nullptr, nullptr, &startup, &process);
	// The plugin's own copies of the child's ends are no longer needed, whether
	// or not the launch succeeded.
	if (nullInput != INVALID_HANDLE_VALUE) {
		CloseHandle(nullInput);
	}
	CloseHandle(writePipe);
	if (!started) {
		CloseHandle(readPipe);
		return 0xFFFFFFFF;
	}

	const DWORD deadline = GetTickCount() + timeoutMillis;
	char chunk[4096];
	bool timedOut = false;
	for (;;) {
		DWORD available = 0;
		if (!PeekNamedPipe(readPipe, nullptr, 0, nullptr, &available, nullptr)) {
			// The pipe is broken, which is how a closed write end is seen: the
			// child has exited and there is nothing left to read.
			break;
		}
		if (available == 0) {
			if (WaitForSingleObject(process.hProcess, 0) == WAIT_OBJECT_0) {
				// Exited, and every buffered byte has already been drained.
				break;
			}
			if (static_cast<LONG>(GetTickCount() - deadline) >= 0) {
				timedOut = true;
				break;
			}
			Sleep(10);
			continue;
		}
		const DWORD wanted = available < sizeof(chunk)
		                         ? available
		                         : static_cast<DWORD>(sizeof(chunk));
		DWORD read = 0;
		if (!ReadFile(readPipe, chunk, wanted, &read, nullptr) || read == 0) {
			break;
		}
		if (output->size() < kMaxOutput) {
			const size_t room = kMaxOutput - output->size();
			output->append(chunk, read < room ? read : room);
		}
	}

	if (timedOut || WaitForSingleObject(process.hProcess, 0) != WAIT_OBJECT_0) {
		TerminateProcess(process.hProcess, 1);
		WaitForSingleObject(process.hProcess, 5000);
	}
	DWORD code = 0;
	GetExitCodeProcess(process.hProcess, &code);
	CloseHandle(process.hThread);
	CloseHandle(process.hProcess);
	CloseHandle(readPipe);
	return timedOut ? 0xFFFFFFFF : code;
}

std::string getString(const EncodableMap& root, const char* key) {
	const auto it = root.find(EncodableValue(key));
	if (it == root.end()) {
		return std::string();
	}
	const auto* text = std::get_if<std::string>(&it->second);
	return text == nullptr ? std::string() : *text;
}

std::vector<std::string> getStringList(const EncodableMap& root, const char* key) {
	std::vector<std::string> out;
	const auto it = root.find(EncodableValue(key));
	if (it == root.end()) {
		return out;
	}
	const auto* list = std::get_if<EncodableList>(&it->second);
	if (list == nullptr) {
		return out;
	}
	for (const auto& entry : *list) {
		const auto* text = std::get_if<std::string>(&entry);
		if (text != nullptr) {
			out.push_back(*text);
		}
	}
	return out;
}

int getInt(const EncodableMap& root, const char* key) {
	const auto it = root.find(EncodableValue(key));
	if (it == root.end()) {
		return 0;
	}
	if (const auto* number = std::get_if<int32_t>(&it->second)) {
		return *number;
	}
	if (const auto* number64 = std::get_if<int64_t>(&it->second)) {
		return static_cast<int>(*number64);
	}
	return 0;
}

// Reads the WireGuard section of a request.
bool parseRequest(const EncodableValue* arguments, WireGuardInterface* wgInterface,
                  std::vector<WireGuardPeer>* peers, std::string* errorMessage) {
	const auto* root = std::get_if<EncodableMap>(arguments);
	if (root == nullptr) {
		*errorMessage = "The tunnel request was not in a form this platform can read.";
		return false;
	}
	const auto wgIt = root->find(EncodableValue("wireguard"));
	if (wgIt == root->end()) {
		*errorMessage =
				"This build can only start a WireGuard tunnel on Windows, and the "
				"selected server offers OpenVPN.";
		return false;
	}
	const auto* wg = std::get_if<EncodableMap>(&wgIt->second);
	if (wg == nullptr) {
		*errorMessage = "The tunnel configuration was not in a form this platform can read.";
		return false;
	}

	wgInterface->privateKey = getString(*wg, "privateKey");
	wgInterface->addresses = getStringList(*wg, "addresses");
	wgInterface->dns = getStringList(*wg, "dns");
	wgInterface->mtu = getInt(*wg, "mtu");

	const auto peersIt = wg->find(EncodableValue("peers"));
	const auto* peerList = peersIt == wg->end() ? nullptr
	                                            : std::get_if<EncodableList>(&peersIt->second);
	if (peerList == nullptr || peerList->empty()) {
		*errorMessage = "The tunnel needs at least one peer, and none was supplied.";
		return false;
	}
	for (const auto& entry : *peerList) {
		const auto* peerMap = std::get_if<EncodableMap>(&entry);
		if (peerMap == nullptr) {
			*errorMessage = "A peer in the tunnel configuration is malformed.";
			return false;
		}
		WireGuardPeer peer;
		peer.publicKey = getString(*peerMap, "publicKey");
		peer.presharedKey = getString(*peerMap, "presharedKey");
		peer.allowedIps = getStringList(*peerMap, "allowedIps");
		peer.persistentKeepalive = getInt(*peerMap, "persistentKeepalive");
		// The endpoint arrives as "host:port" and is split so the value written
		// to disk is rebuilt from two parts rather than passed through whole.
		const std::string endpoint = getString(*peerMap, "endpoint");
		const auto colon = endpoint.rfind(':');
		if (colon != std::string::npos) {
			peer.endpointHost = endpoint.substr(0, colon);
			peer.endpointPort = std::atoi(endpoint.c_str() + colon + 1);
		}
		peers->push_back(peer);
	}
	return true;
}

// Writes the configuration the Windows service will read.
bool writeConfiguration(const std::wstring& path, const WireGuardInterface& wgInterface,
                        const std::vector<WireGuardPeer>& peers, std::string* errorMessage) {
	if (sanitize(wgInterface.privateKey).empty()) {
		*errorMessage = "The tunnel configuration has no private key.";
		return false;
	}
	if (peers.empty()) {
		*errorMessage = "The tunnel configuration has no peer to connect to.";
		return false;
	}

	std::ostringstream out;
	out << "[Interface]\n";
	out << "PrivateKey = " << sanitize(wgInterface.privateKey) << "\n";
	for (const auto& address : wgInterface.addresses) {
		out << "Address = " << sanitize(address) << "\n";
	}
	if (!wgInterface.dns.empty()) {
		out << "DNS = ";
		for (size_t i = 0; i < wgInterface.dns.size(); ++i) {
			if (i > 0) {
				out << ", ";
			}
			out << sanitize(wgInterface.dns[i]);
		}
		out << "\n";
	}
	if (wgInterface.mtu > 0) {
		out << "MTU = " << wgInterface.mtu << "\n";
	}
	out << "\n";

	for (const auto& peer : peers) {
		if (sanitize(peer.publicKey).empty() || peer.allowedIps.empty()) {
			*errorMessage = "A peer in the tunnel configuration is incomplete.";
			return false;
		}
		out << "[Peer]\n";
		out << "PublicKey = " << sanitize(peer.publicKey) << "\n";
		if (!peer.presharedKey.empty()) {
			out << "PresharedKey = " << sanitize(peer.presharedKey) << "\n";
		}
		if (!peer.endpointHost.empty() && peer.endpointPort > 0) {
			out << "Endpoint = " << sanitize(peer.endpointHost) << ":" << peer.endpointPort << "\n";
		}
		out << "AllowedIPs = ";
		for (size_t i = 0; i < peer.allowedIps.size(); ++i) {
			if (i > 0) {
				out << ", ";
			}
			out << sanitize(peer.allowedIps[i]);
		}
		out << "\n";
		if (peer.persistentKeepalive > 0) {
			out << "PersistentKeepalive = " << peer.persistentKeepalive << "\n";
		}
		out << "\n";
	}

	HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
	                          FILE_ATTRIBUTE_NORMAL, nullptr);
	if (file == INVALID_HANDLE_VALUE) {
		*errorMessage = "The tunnel configuration could not be written.";
		return false;
	}
	const std::string contents = out.str();
	DWORD written = 0;
	WriteFile(file, contents.data(), static_cast<DWORD>(contents.size()), &written, nullptr);
	CloseHandle(file);
	if (written != contents.size()) {
		DeleteFileW(path.c_str());
		*errorMessage = "The tunnel configuration could not be written completely.";
		return false;
	}
	// The file inherits the directory's restricted DACL on creation — but
	// `CREATE_ALWAYS` truncates an existing file *without replacing its ACL*,
	// so a configuration left over from before the hardening, or one whose
	// permissions were changed externally, would keep them. The explicit
	// restriction closes that gap. When it cannot be applied the file is
	// deleted rather than left with unknown permissions: failing to connect
	// is recoverable, a readable private key is not.
	if (!phantrix::ovpn::RestrictToUserAndSystem(path, false)) {
		DeleteFileW(path.c_str());
		*errorMessage = "The tunnel configuration could not be secured.";
		return false;
	}
	return true;
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
	// A message-only window the reader thread posts to, so events reach the
	// Flutter event sink on the platform thread.
	HWND messageWindow = nullptr;
	// Token the helper must echo. Generated here, passed on its command line.
	std::wstring token;
	// The session directory holding the profile, the status file and the log.
	std::wstring session;
	std::wstring profile;
	std::wstring status;
	std::wstring log;
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

// The message the engine readers post. Anything in the application's private
// range is safe; this one is ours alone. It is shared by both engines because
// only one tunnel runs at a time and the posted payload already carries its own
// meaning.
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
};

// ---------------------------------------------------------------------------
// Reading the WireGuard engine's own statistics
// ---------------------------------------------------------------------------

bool isAllDigits(const std::string& value) {
	if (value.empty()) {
		return false;
	}
	for (const char c : value) {
		if (c < '0' || c > '9') {
			return false;
		}
	}
	return true;
}

std::string trim(const std::string& value) {
	size_t begin = 0;
	size_t end = value.size();
	const auto blank = [](char c) {
		return c == ' ' || c == '\t' || c == '\r' || c == '\n';
	};
	while (begin < end && blank(value[begin])) {
		++begin;
	}
	while (end > begin && blank(value[end - 1])) {
		--end;
	}
	return value.substr(begin, end - begin);
}

std::vector<std::string> splitOn(const std::string& value, char separator) {
	std::vector<std::string> fields;
	size_t start = 0;
	for (;;) {
		const size_t at = value.find(separator, start);
		if (at == std::string::npos) {
			fields.push_back(value.substr(start));
			return fields;
		}
		fields.push_back(value.substr(start, at - start));
		start = at + 1;
	}
}

// What `wg show <interface> dump` said about the tunnel's peers.
struct WireGuardDump {
	// True when at least one peer line was recognized. This is what makes the
	// interface's existence evidence rather than a guess.
	bool parsed = false;
	// True when a peer reported a completed handshake.
	bool handshaked = false;
	int64_t handshakeAtMillis = 0;
	int64_t rxBytes = 0;
	int64_t txBytes = 0;
};

// Parses the tab-separated `dump` form of `wg show`.
//
// The first line describes the interface; every later non-empty line describes
// one peer with eight fields:
//
//   publickey  presharedkey  endpoint  allowedips  latest-handshake  rx  tx  keepalive
//
// `latest-handshake` is seconds since the Unix epoch and is 0 until a handshake
// has happened; the byte counts are the peer's totals. With more than one peer
// the counters are summed and the newest handshake wins, because the app cares
// whether *a* peer answered, not which one. The three fields this reads are
// required to be all digits before they are converted, so a localized or
// reworded `dump` line yields no numbers rather than a wrong one.
WireGuardDump parseDumpStats(const std::string& text) {
	WireGuardDump dump;
	size_t start = 0;
	int lineIndex = 0;
	while (start <= text.size()) {
		size_t end = text.find('\n', start);
		const bool last = end == std::string::npos;
		if (last) {
			end = text.size();
		}
		const std::string line = trim(text.substr(start, end - start));
		if (lineIndex > 0 && !line.empty()) {
			const std::vector<std::string> fields = splitOn(line, '\t');
			if (fields.size() >= 7) {
				const std::string handshake = trim(fields[4]);
				const std::string rx = trim(fields[5]);
				const std::string tx = trim(fields[6]);
				if (isAllDigits(handshake) && isAllDigits(rx) && isAllDigits(tx)) {
					dump.parsed = true;
					dump.rxBytes += std::atoll(rx.c_str());
					dump.txBytes += std::atoll(tx.c_str());
					const int64_t handshakeSeconds = std::atoll(handshake.c_str());
					if (handshakeSeconds > 0) {
						dump.handshaked = true;
						const int64_t millis = handshakeSeconds * 1000;
						if (millis > dump.handshakeAtMillis) {
							dump.handshakeAtMillis = millis;
						}
					}
				}
			}
		}
		++lineIndex;
		if (last) {
			break;
		}
		start = end + 1;
	}
	return dump;
}

// The state a running WireGuard tunnel keeps so its progress can be reported.
//
// WireGuard for Windows exposes no stream to subscribe to: its service owns the
// tunnel, and the only thing this backend can do is ask the official `wg.exe`
// what it knows — which is exactly what the WireGuard UI itself does. A thread
// polls it and posts what it finds to the platform thread, because the Flutter
// event sink is only safe there.
struct WireGuardSession {
	// The poller thread.
	HANDLE thread = nullptr;
	// Signalled to ask the poller to stop.
	HANDLE stopEvent = nullptr;
	// The message window the poller posts to, on the platform thread.
	HWND messageWindow = nullptr;
	// The `wg.exe` found beside `wireguard.exe` when the tunnel started.
	std::wstring cli;
	// The interface name `wg.exe` accepted, cached once a query succeeds. The
	// service may expose the tunnel as the bare name or as the service name, so
	// both are tried before either is believed.
	std::wstring interfaceName;
};

// Queries the running tunnel's statistics.
//
// Tries the cached interface name first, then both forms if none is cached yet,
// and remembers whichever one answered. Returns false when the interface cannot
// be queried at all, which is reported as silence, not as a failure: the poller
// keeps trying until the tunnel stops or a query succeeds.
bool ReadWireGuardStats(WireGuardSession* session, WireGuardDump* dump) {
	*dump = WireGuardDump();
	if (session->cli.empty()) {
		return false;
	}
	std::vector<std::wstring> names;
	if (!session->interfaceName.empty()) {
		names.push_back(session->interfaceName);
	} else {
		names.push_back(std::wstring(kTunnelName));
		names.push_back(L"WireGuardTunnel$" + std::wstring(kTunnelName));
	}
	for (const auto& name : names) {
		const std::wstring command =
		    L"\"" + session->cli + L"\" show \"" + name + L"\" dump";
		std::string output;
		if (runCapture(command, &output, kWireGuardQueryTimeoutMillis) != 0) {
			continue;
		}
		const WireGuardDump parsed = parseDumpStats(output);
		if (!parsed.parsed) {
			continue;
		}
		session->interfaceName = name;
		*dump = parsed;
		return true;
	}
	return false;
}

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

	// Releases both engines' resources when the plugin is torn down. Without
	// this the WireGuard poller and the OpenVPN reader would outlive their
	// owner, holding a thread and a message window that can no longer report.
	~PhantrixWindowsPlugin() {
		StopWireGuardMonitor();
		TeardownOpenVpn();
	}

 private:
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

	// OpenVPN: reports the engine's state and counters, then tears the session
	// down so nothing is left holding a handle.
	void FailOpenVpn(const std::string& code, const std::string& message);

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
	bool StartOpenVpn(const std::string& profile, std::string* errorCode,
	                  std::string* errorMessage);

	// Handles one message from the helper. Runs on the reader thread and fills
	// in the event that is posted to the platform thread.
	void OnHelperMessage(const phantrix::ovpn::Message& message,
	                    PendingEvent* pending);

	// Releases every resource the OpenVPN session holds: stops the engine,
	// waits for the helper, closes the pipe, removes the session directory.
	// Safe to call when nothing is running.
	void TeardownOpenVpn();

	// Starts polling the running WireGuard tunnel through `wg.exe`, so a
	// completed handshake reaches Dart instead of the attempt failing on
	// silence. Restarts the poller if one is already running.
	void StartWireGuardMonitor();

	// Stops the poller and releases everything it holds. Safe to call when none
	// is running.
	void StopWireGuardMonitor();

	// The poller thread's entry point: asks `wg.exe` for the tunnel's handshake
	// and counters on an interval and forwards what it finds to the platform
	// thread.
	static DWORD WINAPI WireGuardMonitorThread(LPVOID context);

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

		if (method == "capabilities") {
			// Honest about what this backend can actually do. No kill switch and
			// no per-app routing: Windows has no equivalent of Android's per-app
			// VpnService, and a kill switch is not something this implementation
			// provides, so it is reported false rather than approximated.
			//
			// `openVpn` is answered from what is on disk rather than from what the
			// build expects. The bundle is fetched and verified by
			// `tools/fetch_openvpn_bundle.ps1` before the build, so a supported
			// build has it; an unsupported one reports false and the Dart layer
			// refuses an OpenVPN server with an explanation instead of attempting
			// a tunnel that cannot start.
			const std::wstring directory = pluginDirectory();
			const bool openVpnPresent =
			    phantrix::ovpn::OpenVpnBundlePresent(directory);
			EncodableMap map;
			map[EncodableValue("platform")] = EncodableValue("windows");
			map[EncodableValue("killSwitch")] = EncodableValue(false);
			map[EncodableValue("ipv6Block")] = EncodableValue(false);
			map[EncodableValue("vpnDns")] = EncodableValue(true);
			map[EncodableValue("perApp")] = EncodableValue(false);
			map[EncodableValue("lanBypass")] = EncodableValue(false);
			map[EncodableValue("alwaysOn")] = EncodableValue(false);
			map[EncodableValue("tray")] = EncodableValue(false);
			map[EncodableValue("bootStart")] = EncodableValue(false);
			map[EncodableValue("openVpn")] = EncodableValue(openVpnPresent);
			map[EncodableValue("engine")] = EncodableValue(
					openVpnPresent ? "openvpn-community + wireguard-for-windows"
					               : "wireguard-for-windows");
			map[EncodableValue("limitations")] = EncodableValue(
					openVpnPresent
					    ? "OpenVPN tunnels run the official community openvpn.exe "
					      "through a small helper that asks for administrator "
					      "rights; the profile is written to a private file and "
					      "the engine reads that file, so IPv6 policy is whatever "
					      "the server's configuration carried. WireGuard needs "
					      "WireGuard for Windows installed separately. There is no "
					      "kill switch and no per-app routing."
					    : "Windows support requires WireGuard for Windows to be "
					      "installed and administrator rights to add or remove a "
					      "tunnel. The OpenVPN engine is not bundled in this "
					      "build, so only WireGuard servers can be used. There is "
					      "no kill switch and no per-app routing.");
			result->Success(EncodableValue(map));
			return;
		}

		if (method == "requestPermission") {
			// There is no separate consent step to ask about: the consent dialog
			// is raised at the moment the tunnel is created — by WireGuard's own
			// manifest, or by this app's helper via `runas`. Reporting whether a
			// backend is even present is the useful answer.
			const std::wstring directory = pluginDirectory();
			result->Success(EncodableValue(
				    phantrix::ovpn::OpenVpnBundlePresent(directory) ||
				    !findWireGuardExe().empty()));
			return;
		}

		if (method == "startTunnel") {
			// An OpenVPN request carries a complete serialized profile and never
			// a WireGuard section, so the two are told apart by what is present
			// rather than by a flag.
			const auto* root = std::get_if<EncodableMap>(call.arguments());
			const std::string ovpnConfig =
			    root == nullptr ? std::string() : getString(*root, "ovpnConfig");
			if (!ovpnConfig.empty()) {
				// A WireGuard poller must not survive into an OpenVPN session:
				// it would keep querying an interface that is being removed and
				// report counters for an engine that is gone.
				StopWireGuardMonitor();
				std::string code;
				std::string error;
				if (!StartOpenVpn(ovpnConfig, &code, &error)) {
					FailOpenVpn(code, error);
					result->Error(code, error);
				} else {
					result->Success();
				}
				return;
			}

			WireGuardInterface wgInterface;
			std::vector<WireGuardPeer> peers;
			std::string error;
			if (!parseRequest(call.arguments(), &wgInterface, &peers, &error)) {
				Fail("wg.config_invalid", error);
				result->Error("wg.config_invalid", error);
				return;
			}
			// An OpenVPN tunnel must be fully stopped before a WireGuard one is
			// started. Two tunnels both holding the default route is not a
			// preference, it is a broken network, and the user has no way to tell
			// which one they are leaking through.
			TeardownOpenVpn();
			// A failure left over from an earlier OpenVPN attempt must not follow
			// this one: the WireGuard monitor's traffic events would each be read
			// as that old failure arriving again and tear down a session that is
			// working. The flag describes the current attempt, so it is cleared
			// when the attempt changes engines.
			openVpnReportedFailure_ = false;
			const auto exe = findWireGuardExe();
			if (exe.empty()) {
				const std::string message =
						"WireGuard for Windows is not installed. Install it from "
						"wireguard.com, then try again.";
				Fail("backend.not_installed", message);
				result->Error("backend.not_installed", message);
				return;
			}
			const auto path = configPath();
			if (path.empty() || !writeConfiguration(path, wgInterface, peers, &error)) {
				Fail("wg.config_invalid", error);
				result->Error("wg.config_invalid", error);
				return;
			}
			// This is the operation that needs administrator rights. WireGuard's
			// own manifest triggers the UAC prompt; it is not suppressed.
			const DWORD status =
					runSilently(L"\"" + exe + L"\" /installtunnelservice \"" + path + L"\"");
			if (status != 0) {
				DeleteFileW(path.c_str());
				const std::string message =
						"Windows refused to add the tunnel. This needs administrator "
						"rights, and WireGuard for Windows must be installed.";
				Fail("permission.denied", message);
				result->Error("permission.denied", message);
				return;
			}
			up_ = true;
			// The service is installed and running. Whether a handshake has
			// happened is not yet known, and is not claimed here: Dart requires a
			// handshake before it will report connected. The monitor below is what
			// turns the engine's own answer into that report — without it the
			// tunnel can be perfectly up and Dart still times out on silence,
			// because nothing in this backend ever asked.
			StartWireGuardMonitor();
			Publish("established");
			result->Success();
			return;
		}

		if (method == "stopTunnel") {
			// Both engines are stopped, whichever was running. They cannot run at
			// the same time — two default routes through two adapters is not a
			// tunnel, it is a broken network — so stopping both is the only order
			// that is safe: stopping an engine that is not up is a no-op for
			// WireGuard and a bounded wait for OpenVPN.
			StopWireGuardMonitor();
			TeardownOpenVpn();
			if (up_) {
				const auto exe = findWireGuardExe();
				if (!exe.empty()) {
					runSilently(L"\"" + exe + L"\" /uninstalltunnelservice \"" +
					            std::wstring(kTunnelName) + L"\"");
				}
				up_ = false;
			}
			const auto path = configPath();
			if (!path.empty()) {
				DeleteFileW(path.c_str());
			}
			// Only reported once. A stop during a failed OpenVPN attempt has
			// already published `failed` from the reader thread, and a
			// `disconnected` after it would tell the user that a tunnel came down
			// which never came up.
			if (!openVpnReportedFailure_) {
				Publish("disconnected");
			}
			openVpnReportedFailure_ = false;
			result->Success();
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
			// The per-user directory the app stores its settings and imported
			// configurations in. It has to come from the native side because
			// only the native side knows where the platform keeps it.
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
	bool up_ = false;

	// The OpenVPN session, and the one bit of bookkeeping that is not inside
	// it: whether the reader thread has already reported a failure for this
	// attempt, so a later stop publishes exactly one outcome.
	OpenVpnSession openVpn_;
	bool openVpnReportedFailure_ = false;

	// The WireGuard handshake monitor. Unlike OpenVPN there is no helper to talk
	// to: `wg.exe` is polled instead, and only the platform thread publishes.
	WireGuardSession wireGuard_;
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
		// either torn the tunnel down or reported that it failed. The session is
		// released here rather than waiting for the app to call stop, because a
		// failed tunnel that is not cleaned up is a leaked handle and a leaked
		// session directory.
		plugin->TeardownOpenVpn();
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
			PostMessageW(plugin->openVpn_.messageWindow, kTunnelMessageId, 0,
			             reinterpret_cast<LPARAM>(pending));
		}
		if (plugin->openVpn_.stopping) {
			break;
		}
	}
	CancelIo(pipe);
	CloseHandle(overlap.hEvent);
	// End of stream. If the helper went away without tearing anything down, the
	// engine may still be running; that is reported as a failure rather than
	// left as silence.
	auto* pending = new PendingEvent();
	pending->state = "failed";
	pending->errorCode = "ovpn.helper_lost";
	pending->message = "The tunnel helper stopped without reporting a result.";
	PostMessageW(plugin->openVpn_.messageWindow, kTunnelMessageId, 0,
	             reinterpret_cast<LPARAM>(pending));
	return 0;
}
void PhantrixWindowsPlugin::TeardownOpenVpn() {
	if (openVpn_.pipe == nullptr && openVpn_.helper == nullptr &&
	    openVpn_.reader == nullptr && openVpn_.messageWindow == nullptr) {
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
			phantrix::ovpn::Message stop =
			    phantrix::ovpn::MakeMessage(phantrix::ovpn::MessageType::kStop, {});
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
	// the engine's own log. It does not outlive the tunnel it belonged to.
	if (!openVpn_.session.empty()) {
		(void)phantrix::ovpn::RemoveTree(openVpn_.session);
		openVpn_.session.clear();
	}

	if (openVpn_.messageWindow != nullptr) {
		SetWindowLongPtrW(openVpn_.messageWindow, GWLP_USERDATA, 0);
		DestroyWindow(openVpn_.messageWindow);
		openVpn_.messageWindow = nullptr;
	}

	openVpn_.started = false;
	openVpn_.stopping = false;
	openVpn_.token.clear();
	openVpn_.profile.clear();
	openVpn_.status.clear();
	openVpn_.log.clear();
	openVpn_.rxBytes = 0;
	openVpn_.txBytes = 0;
	openVpn_.handshakeAtMillis = 0;
	openVpn_.disconnected = false;
}

void PhantrixWindowsPlugin::FailOpenVpn(const std::string& code,
                                        const std::string& message) {
	Fail(code, message);
	TeardownOpenVpn();
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

// ---------------------------------------------------------------------------
// The WireGuard handshake monitor
// ---------------------------------------------------------------------------
//
// WireGuard for Windows reports nothing back to the process that installed the
// tunnel: `wireguard.exe /installtunnelservice` returns once the service is
// running, and the tunnel's progress afterwards lives only in the service. Left
// at that, the app has no way to tell a tunnel that handshook from one that is
// silently failing, and the only possible answer is the app's own timeout — the
// exact "engine never reported a handshake" failure this monitor exists to
// remove.
//
// The official `wg.exe` is that missing channel, and it is the same one the
// WireGuard UI uses to show live statistics. The poller below reads it and does
// not interpret it beyond the documented `dump` fields.

DWORD WINAPI PhantrixWindowsPlugin::WireGuardMonitorThread(LPVOID context) {
	auto* plugin = reinterpret_cast<PhantrixWindowsPlugin*>(context);
	WireGuardSession& session = plugin->wireGuard_;
	for (;;) {
		const DWORD waited =
		    WaitForSingleObject(session.stopEvent, kWireGuardPollMillis);
		if (waited != WAIT_TIMEOUT) {
			// Signalled to stop, or the wait itself failed. Either way this
			// thread has nothing left to do.
			break;
		}
		WireGuardDump dump;
		if (!ReadWireGuardStats(&session, &dump) || !dump.handshaked) {
			// No handshake yet, or the interface cannot be queried. Silence is
			// the honest report: the app's own deadline decides when it is
			// fatal, and this thread must not invent an answer to fill the gap.
			continue;
		}
		auto* pending = new PendingEvent();
		pending->state = "traffic";
		pending->hasTraffic = true;
		pending->rxBytes = dump.rxBytes;
		pending->txBytes = dump.txBytes;
		pending->handshakeAtMillis = dump.handshakeAtMillis;
		if (PostMessageW(session.messageWindow, kTunnelMessageId, 0,
		                 reinterpret_cast<LPARAM>(pending)) == FALSE) {
			// The window is gone, so there is nowhere to report to and this
			// thread can only leak from here on.
			delete pending;
			break;
		}
	}
	return 0;
}

void PhantrixWindowsPlugin::StartWireGuardMonitor() {
	// A poller from a previous attempt must not survive into this one, or two
	// threads would report the same interface under two sessions.
	StopWireGuardMonitor();

	const std::wstring cli = findWireGuardCli();
	if (cli.empty()) {
		// The tunnel is up but `wg.exe` is missing, which can only be a
		// repackaged WireGuard install. Nothing is guessed from it: the app's
		// own deadline remains the arbiter, exactly as before this monitor.
		return;
	}

	// The message window is created here, on the platform thread, because that
	// is where its messages are dispatched and where the event sink may be
	// touched. The window class is the one the OpenVPN reader already registers;
	// registering it twice is harmless.
	WNDCLASSEXW windowClass = {0};
	windowClass.cbSize = sizeof(windowClass);
	windowClass.lpfnWndProc = MessageWindowProc;
	windowClass.hInstance = GetModuleHandleW(nullptr);
	windowClass.lpszClassName = kMessageWindowClass;
	RegisterClassExW(&windowClass);
	wireGuard_.messageWindow =
	    CreateWindowExW(0, kMessageWindowClass, L"", 0, 0, 0, 0, 0, HWND_MESSAGE,
	                    nullptr, GetModuleHandleW(nullptr), nullptr);
	if (wireGuard_.messageWindow == nullptr) {
		return;
	}
	SetWindowLongPtrW(wireGuard_.messageWindow, GWLP_USERDATA,
	                  reinterpret_cast<LONG_PTR>(this));

	wireGuard_.stopEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
	if (wireGuard_.stopEvent == nullptr) {
		SetWindowLongPtrW(wireGuard_.messageWindow, GWLP_USERDATA, 0);
		DestroyWindow(wireGuard_.messageWindow);
		wireGuard_.messageWindow = nullptr;
		return;
	}

	wireGuard_.cli = cli;
	wireGuard_.interfaceName.clear();
	wireGuard_.thread =
	    CreateThread(nullptr, 0, WireGuardMonitorThread, this, 0, nullptr);
	if (wireGuard_.thread == nullptr) {
		CloseHandle(wireGuard_.stopEvent);
		wireGuard_.stopEvent = nullptr;
		SetWindowLongPtrW(wireGuard_.messageWindow, GWLP_USERDATA, 0);
		DestroyWindow(wireGuard_.messageWindow);
		wireGuard_.messageWindow = nullptr;
		wireGuard_.cli.clear();
	}
}

void PhantrixWindowsPlugin::StopWireGuardMonitor() {
	if (wireGuard_.stopEvent != nullptr) {
		SetEvent(wireGuard_.stopEvent);
	}
	if (wireGuard_.thread != nullptr) {
		// The poller is bounded by the query timeout, so a wait longer than
		// that always ends. A thread that still did not stop is left closed over
		// rather than waited on forever: the app is being torn down, and a
		// detached poller that can no longer post anywhere is the lesser harm.
		WaitForSingleObject(wireGuard_.thread,
		                    kWireGuardQueryTimeoutMillis + 2000);
		CloseHandle(wireGuard_.thread);
		wireGuard_.thread = nullptr;
	}
	if (wireGuard_.stopEvent != nullptr) {
		CloseHandle(wireGuard_.stopEvent);
		wireGuard_.stopEvent = nullptr;
	}
	if (wireGuard_.messageWindow != nullptr) {
		// The user data is cleared first, so a message already queued for this
		// window cannot be answered from a plugin that is going away.
		SetWindowLongPtrW(wireGuard_.messageWindow, GWLP_USERDATA, 0);
		DestroyWindow(wireGuard_.messageWindow);
		wireGuard_.messageWindow = nullptr;
	}
	wireGuard_.cli.clear();
	wireGuard_.interfaceName.clear();
}

bool PhantrixWindowsPlugin::StartOpenVpn(const std::string& profile,
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
		    "The OpenVPN engine is not bundled in this build. Only WireGuard "
		    "servers can be used here.";
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
	if (!phantrix::ovpn::WriteRestrictedFile(openVpn_.profile, profile)) {
		// An unsecurable profile is not connected with, and is not left behind.
		(void)phantrix::ovpn::RemoveTree(openVpn_.session);
		openVpn_.session.clear();
		*errorCode = "ovpn.config_invalid";
		*errorMessage = "The tunnel configuration could not be secured on disk.";
		return false;
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

	// The message window is created on the platform thread, which is where the
	// app's message loop runs and therefore where its messages are dispatched.
	WNDCLASSEXW windowClass = {0};
	windowClass.cbSize = sizeof(windowClass);
	windowClass.lpfnWndProc = MessageWindowProc;
	windowClass.hInstance = GetModuleHandleW(nullptr);
	windowClass.lpszClassName = kMessageWindowClass;
	RegisterClassExW(&windowClass);
	openVpn_.messageWindow =
	    CreateWindowExW(0, kMessageWindowClass, L"", 0, 0, 0, 0, 0, HWND_MESSAGE,
	                    nullptr, GetModuleHandleW(nullptr), nullptr);
	if (openVpn_.messageWindow == nullptr) {
		CloseHandle(openVpn_.pipe);
		openVpn_.pipe = nullptr;
		(void)phantrix::ovpn::RemoveTree(openVpn_.session);
		openVpn_.session.clear();
		*errorCode = "backend.launch_failed";
		*errorMessage = "The tunnel's message window could not be created.";
		return false;
	}
	SetWindowLongPtrW(openVpn_.messageWindow, GWLP_USERDATA,
	                  reinterpret_cast<LONG_PTR>(this));

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
	// The wait is overlapped and bounded: an unbounded hold on the platform
	// thread would be a connect button that does nothing, and the user cannot
	// tell that apart from a crash.
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

	const std::vector<std::string> startFields = {
	    phantrix::ovpn::WideToUtf8(openVpn_.profile),
	    phantrix::ovpn::WideToUtf8(openVpn_.status),
	    phantrix::ovpn::WideToUtf8(openVpn_.log),
	};
	if (!phantrix::ovpn::WriteMessage(
	        openVpn_.pipe,
	        phantrix::ovpn::MakeMessage(phantrix::ovpn::MessageType::kStart,
	                                    startFields))) {
		*errorCode = "ovpn.helper_lost";
		*errorMessage = "The tunnel helper stopped before it started the engine.";
		TeardownOpenVpn();
		return false;
	}

	openVpn_.reader = CreateThread(nullptr, 0, OpenVpnReaderThread, this, 0, nullptr);
	if (openVpn_.reader == nullptr) {
		*errorCode = "backend.launch_failed";
		*errorMessage = "The tunnel helper could not be monitored.";
		TeardownOpenVpn();
		return false;
	}

	// The engine is starting. Whether it ever connects is not known here, and is
	// not claimed: the helper reports that when the engine says so.
	Publish("preparing");
	Publish("connecting");
	return true;
}

void PhantrixPluginRegisterWithRegistrar(FlutterDesktopPluginRegistrarRef registrar) {
	PhantrixWindowsPlugin::RegisterWithRegistrar(
			flutter::PluginRegistrarManager::GetInstance()
					->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
