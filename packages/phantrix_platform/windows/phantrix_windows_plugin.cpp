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
#include <tchar.h>

#include <aclapi.h>
#include <sddl.h>

#include <cstdlib>
#include <algorithm>
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
#pragma comment(lib, "Shell32.lib")

namespace {

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
constexpr DWORD kHelperStopTimeoutMillis = 20000;

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
	enum class Kind { start, stop, teardownOnly };
	Kind kind = Kind::teardownOnly;
	std::string profile;
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
		TeardownOpenVpn();
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
				case TunnelJob::Kind::start: {
					std::string code;
					std::string message;
					const bool started = StartOpenVpn(job.profile, &code, &message);
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
					TeardownOpenVpn();
					auto* pending = new PendingEvent();
					pending->state = "stopped";
					pending->result = job.result;
					pending->publishDisconnected = job.publishDisconnected;
					PostEvent(pending);
					break;
				}
				case TunnelJob::Kind::teardownOnly:
					TeardownOpenVpn();
					break;
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
			// The engine is answered from what is on disk rather than from what
			// the build expects. The OpenVPN bundle is fetched and verified by
			// `tools/fetch_openvpn_bundle.ps1` before the build, so a supported
			// build has it; an unsupported one reports false and the Dart layer
			// refuses an OpenVPN server with an explanation instead of
			// attempting a tunnel that cannot start.
			const std::wstring directory = pluginDirectory();
			const bool openVpnPresent =
			    phantrix::ovpn::OpenVpnBundlePresent(directory);
			const std::string engineName =
			    openVpnPresent ? "openvpn-community" : "none";
			std::string limitations;
			if (openVpnPresent) {
				limitations =
				    "OpenVPN tunnels run the official community openvpn.exe "
				    "through a small helper that asks for administrator rights; "
				    "the profile is written to a private file and the engine "
				    "reads that file, so IPv6 policy is whatever the server's "
				    "configuration carried. There is no kill switch and no "
				    "per-app routing.";
			} else {
				limitations =
				    "The OpenVPN engine is not bundled in this build, so no "
				    "tunnel can be started. Use a build that bundles the "
				    "engine. There is no kill switch and no per-app routing.";
			}
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
			map[EncodableValue("engine")] = EncodableValue(engineName);
			map[EncodableValue("limitations")] = EncodableValue(limitations);
			result->Success(EncodableValue(map));
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
		plugin->EnqueueJob(TunnelJob{TunnelJob::Kind::teardownOnly});
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
void PhantrixWindowsPlugin::TeardownOpenVpn() {
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
