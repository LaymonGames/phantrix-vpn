#include "phantrix_ovpn_engine.h"

#include "phantrix_ovpn_support.h"

#include <cstdio>
#include <cstring>

namespace phantrix {
namespace ovpn {

namespace {

// How long the engine has to exit after a console control event before it is
// killed outright. Ten seconds is generous for a graceful OpenVPN shutdown,
// which normally takes well under a second; it is bounded so a wedged engine
// cannot leave the user pressing Disconnect forever.
constexpr DWORD kGracefulStopMillis = 10000;

// How often the statistics file is read, and how often the loop wakes.
constexpr int64_t kTrafficPollMillis = 1000;
constexpr DWORD kLoopWakeMillis = 200;

// Wraps a command-line argument in quotes. Paths never contain a quote
// character on Windows, and a path that somehow did would be quoted rather than
// able to end its argument.
std::wstring QuoteArgument(const std::wstring& value) {
	std::wstring quoted = L"\"";
	for (const wchar_t c : value) {
		if (c == L'"') {
			quoted += L"\\\"";
		} else {
			quoted.push_back(c);
		}
	}
	quoted += L"\"";
	return quoted;
}

}  // namespace

Engine::Engine(StateCallback onState, TrafficCallback onTraffic,
               FailureCallback onFailure)
		: onState_(std::move(onState)),
			onTraffic_(std::move(onTraffic)),
			onFailure_(std::move(onFailure)) {
	InitializeCriticalSection(&lock_);
	stopEvent_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
	wakeEvent_ = CreateEventW(nullptr, FALSE, FALSE, nullptr);
}

Engine::~Engine() {
	if (monitorThread_ != nullptr) {
		CloseHandle(monitorThread_);
	}
	if (stopEvent_ != nullptr) {
		CloseHandle(stopEvent_);
	}
	if (wakeEvent_ != nullptr) {
		CloseHandle(wakeEvent_);
	}
	if (outputRead_ != nullptr) {
		CloseHandle(outputRead_);
	}
	if (outputWrite_ != nullptr) {
		CloseHandle(outputWrite_);
	}
	if (inputRead_ != nullptr) {
		CloseHandle(inputRead_);
	}
	if (process_ != nullptr) {
		CloseHandle(process_);
	}
	DeleteCriticalSection(&lock_);
}

bool Engine::Start(const EnginePaths& paths, std::string* errorCode,
                   std::string* errorMessage) {
	if (paths.profile.empty() || paths.status.empty() || paths.log.empty() ||
	    paths.engineDirectory.empty()) {
		*errorCode = "ovpn.paths_missing";
		*errorMessage = "The tunnel's file locations could not be chosen.";
		return false;
	}
	if (GetFileAttributesW(paths.profile.c_str()) == INVALID_FILE_ATTRIBUTES) {
		*errorCode = "ovpn.profile_missing";
		*errorMessage = "The tunnel configuration file was not written.";
		return false;
	}
	const std::wstring executable = OpenVpnExecutable(paths.engineDirectory);
	if (GetFileAttributesW(executable.c_str()) == INVALID_FILE_ATTRIBUTES) {
		*errorCode = "backend.not_installed";
		*errorMessage =
		    "The bundled OpenVPN engine is missing. Reinstalling Phantrix "
		    "restores it.";
		return false;
	}

	// An anonymous pipe for the engine's output. The engine writes progress and
	// errors to it, and this process is the only reader. Nothing is ever written
	// the other way.
	SECURITY_ATTRIBUTES pipeAttributes = {0};
	pipeAttributes.nLength = sizeof(pipeAttributes);
	pipeAttributes.bInheritHandle = TRUE;
	if (CreatePipe(&outputRead_, &outputWrite_, &pipeAttributes, 0) == FALSE) {
		*errorCode = "backend.launch_failed";
		*errorMessage = "The engine's output could not be captured.";
		return false;
	}
	// The read end must not be inherited: if it were, the pipe would stay open
	// after the engine exits and the reader would never see end of stream.
	if (SetHandleInformation(outputRead_, HANDLE_FLAG_INHERIT, 0) == FALSE) {
		*errorCode = "backend.launch_failed";
		*errorMessage = "The engine's output could not be captured.";
		return false;
	}

	// stdin points at the NUL device so any read returns end of file
	// immediately. The engine is never given a chance to wait for input this
	// process has no intention of sending.
	inputRead_ = CreateFileW(L"NUL", GENERIC_READ,
	                         FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
	                         OPEN_EXISTING, 0, nullptr);
	if (inputRead_ == INVALID_HANDLE_VALUE) {
		*errorCode = "backend.launch_failed";
		*errorMessage = "The engine's input could not be prepared.";
		return false;
	}

	// The whole command line. Every argument is one this process chose: two
	// fixed flags, and four paths it created itself. Nothing from the profile
	// reaches this line — the profile's contents travel as a file, which is why
	// a value in it cannot end an argument or start a new one.
	std::wstring commandLine = QuoteArgument(executable);
	commandLine += L" --config " + QuoteArgument(paths.profile);
	commandLine += L" --windows-driver wintun";
	if (!paths.deviceNode.empty()) {
		commandLine += L" --dev-node " + QuoteArgument(paths.deviceNode);
	}
	commandLine += L" --status " + QuoteArgument(paths.status) + L" 1";
	commandLine += L" --log " + QuoteArgument(paths.log);

	STARTUPINFOW startup = {0};
	startup.cb = sizeof(startup);
	startup.dwFlags = STARTF_USESTDHANDLES;
	startup.hStdInput = inputRead_;
	startup.hStdOutput = outputWrite_;
	startup.hStdError = outputWrite_;

	PROCESS_INFORMATION process = {0};
	const BOOL created = CreateProcessW(
	    nullptr, commandLine.data(), nullptr, nullptr, TRUE,
	    CREATE_NEW_CONSOLE | CREATE_NEW_PROCESS_GROUP | CREATE_UNICODE_ENVIRONMENT,
	    nullptr, paths.engineDirectory.c_str(), &startup, &process);
	if (created == FALSE) {
		*errorCode = "backend.launch_failed";
		*errorMessage =
		    "Windows would not start the OpenVPN engine. The bundle may have "
		    "been blocked or removed.";
		return false;
	}
	process_ = process.hProcess;
	CloseHandle(process.hThread);

	// The engine's console exists so that it can be asked to stop through a
	// console control event rather than only through a kill. It is hidden: an
	// always-visible console window during a VPN session looks like a bug, and
	// the window is not what makes the event work.
	for (int attempt = 0; attempt < 20; ++attempt) {
		if (AttachConsole(process.dwProcessId) == FALSE) {
			Sleep(100);
			continue;
		}
		HWND consoleWindow = GetConsoleWindow();
		if (consoleWindow != nullptr) {
			ShowWindow(consoleWindow, SW_HIDE);
		}
		FreeConsole();
		break;
	}

paths_ = paths;
	running_ = true;
	stopRequested_ = false;
	connected_ = false;
	everConnected_ = false;
	failureReported_ = false;
	reported_ = false;
	readerDone_ = false;
	lastErrorLine_.clear();
	recentLines_.clear();
	{
		EnterCriticalSection(&lock_);
		pendingLines_.clear();
		LeaveCriticalSection(&lock_);
	}
	ResetEvent(stopEvent_);

	HANDLE reader = CreateThread(nullptr, 0, ReaderThread, this, 0, nullptr);
	if (reader == nullptr) {
		*errorCode = "backend.launch_failed";
		*errorMessage = "The engine could not be monitored.";
		TerminateProcess(process_, 1);
		return false;
	}
	// The monitor thread owns the reader: it waits for it to finish inside
	// DrainLines, and closes its handle there.
	monitorThread_ = CreateThread(nullptr, 0, [](LPVOID context) -> DWORD {
		static_cast<Engine*>(context)->MonitorLoop();
		return 0;
	}, this, 0, nullptr);
	if (monitorThread_ == nullptr) {
		*errorCode = "backend.launch_failed";
		*errorMessage = "The engine could not be monitored.";
		TerminateProcess(process_, 1);
		WaitForSingleObject(reader, 2000);
		CloseHandle(reader);
		return false;
	}
	return true;
}

DWORD Engine::Stop() {
	if (!running_) {
		return 0;
	}
	running_ = false;
	stopRequested_ = true;

	if (process_ != nullptr && outputWrite_ != nullptr) {
		// Closing the engine's stdout is what unblocks the reader thread at the
		// end of the tunnel. It is done before the graceful-stop dance, and only
		// here, so there is exactly one place that can close it.
		CloseHandle(outputWrite_);
		outputWrite_ = nullptr;
	}
	SetEvent(stopEvent_);

	if (process_ != nullptr) {
		// Ask the engine to exit the way its own code asks it to: a console
		// control event, which OpenVPN translates into a signal and handles by
		// closing the tunnel and notifying the peer. Three steps, in order:
		//
		//   1. `SetConsoleCtrlHandler(NULL, TRUE)` — this process must not react
		//      to the event it is about to generate.
		//   2. `AttachConsole(child)` — join the console the engine was given.
		//   3. `GenerateConsoleCtrlEvent(CTRL_BREAK_EVENT, child)` — Ctrl+Break
		//      reaches a process group created with CREATE_NEW_PROCESS_GROUP,
		//      and unlike Ctrl+C it is not filtered out by that flag.
		//
		// The event is addressed to the engine's process group, which is its
		// own pid, so nothing else in the session receives it.
		SetConsoleCtrlHandler(nullptr, TRUE);
		DWORD childPid = GetProcessId(process_);
		if (AttachConsole(childPid) != FALSE) {
			GenerateConsoleCtrlEvent(CTRL_BREAK_EVENT, childPid);
			FreeConsole();
		}

		const int64_t deadline = NowMillis() + kGracefulStopMillis;
		while (NowMillis() < deadline) {
			if (WaitForSingleObject(process_, 100) == WAIT_OBJECT_0) {
				break;
			}
		}
		if (WaitForSingleObject(process_, 0) != WAIT_OBJECT_0) {
			// The graceful path did not finish inside the deadline. A tunnel
			// that will not stop is worse than one killed without notice: the
			// user asked to disconnect and the interface has to go down now.
			TerminateProcess(process_, 1);
		}
		WaitForSingleObject(process_, 2000);
	}

	if (monitorThread_ != nullptr) {
		// Bounded: the monitor thread's only job after the process is gone is
		// to report the exit, which is already known.
		WaitForSingleObject(monitorThread_, 5000);
		CloseHandle(monitorThread_);
		monitorThread_ = nullptr;
	}

	DWORD code = 0;
	if (process_ != nullptr) {
		GetExitCodeProcess(process_, &code);
	}
	return code;
}

DWORD WINAPI Engine::ReaderThread(LPVOID context) {
	Engine* engine = static_cast<Engine*>(context);
	std::string carry;
	char buffer[4096] = {0};
	for (;;) {
		DWORD read = 0;
		const BOOL ok =
		    ReadFile(engine->outputRead_, buffer, sizeof(buffer), &read, nullptr);
		if (ok == FALSE || read == 0) {
			break;
		}
		carry.append(buffer, read);
		size_t start = 0;
		for (;;) {
			const size_t newline = carry.find('\n', start);
			if (newline == std::string::npos) {
				break;
			}
			std::string line = carry.substr(start, newline - start);
			start = newline + 1;
			while (!line.empty() && (line.back() == '\r' || line.back() == ' ')) {
				line.pop_back();
			}
			if (!line.empty()) {
				EnterCriticalSection(&engine->lock_);
				engine->pendingLines_.push_back(std::move(line));
				LeaveCriticalSection(&engine->lock_);
				SetEvent(engine->wakeEvent_);
			}
		}
		carry.erase(0, start);
	}
	EnterCriticalSection(&engine->lock_);
	engine->readerDone_ = true;
	LeaveCriticalSection(&engine->lock_);
	SetEvent(engine->wakeEvent_);
	return 0;
}

void Engine::DrainLines() {
	std::vector<std::string> lines;
	{
		EnterCriticalSection(&lock_);
		lines.swap(pendingLines_);
		LeaveCriticalSection(&lock_);
	}
	for (const std::string& line : lines) {
		OnOutputLine(line);
	}
}
// Reads whatever the engine has appended to its own log since the last call.
//
// --log is what makes this necessary: it redirects everything the engine
// prints into that file, so the pipe carries nothing and the log is the only
// source of truth. Reading it by offset means the engine's own words are what
// the state machine is driven by, rather than this program's guesses about them.
void Engine::ReadNewLogLines() {
	HANDLE file = CreateFileW(paths_.log.c_str(), GENERIC_READ,
	                          FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
	                          OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
	if (file == INVALID_HANDLE_VALUE) {
		// The engine has not created it yet, or has already deleted it. Neither
		// is a failure: a tunnel that has produced no output has nothing to say.
		return;
	}
	LARGE_INTEGER size = {0};
	if (GetFileSizeEx(file, &size) == FALSE) {
		CloseHandle(file);
		return;
	}
	if (size.QuadPart < static_cast<LONGLONG>(logOffset_)) {
		// The engine rewrote rather than appended. Starting over is the honest
		// response; skipping forward would read a gap as a line of text.
		logOffset_ = 0;
		logCarry_.clear();
	}
	if (SetFilePointer(file, static_cast<LONG>(logOffset_), nullptr, FILE_BEGIN) ==
	    INVALID_SET_FILE_POINTER) {
		CloseHandle(file);
		return;
	}
	std::string freshly;
	char buffer[4096] = {0};
	for (;;) {
		DWORD read = 0;
		if (ReadFile(file, buffer, sizeof(buffer), &read, nullptr) == FALSE ||
		    read == 0) {
			break;
		}
		freshly.append(buffer, read);
		if (freshly.size() > 64 * 1024) {
			break;  // Bounded: a pathological engine must not consume memory.
		}
	}
	CloseHandle(file);
	logOffset_ += static_cast<DWORD>(freshly.size());
	freshly = logCarry_ + freshly;
	logCarry_.clear();

	size_t start = 0;
	for (;;) {
		const size_t newline = freshly.find('\n', start);
		if (newline == std::string::npos) {
			break;
		}
		std::string line = freshly.substr(start, newline - start);
		start = newline + 1;
		while (!line.empty() && (line.back() == '\r' || line.back() == ' ')) {
			line.pop_back();
		}
		if (!line.empty()) {
			OnOutputLine(line);
		}
	}
	// What is left has no newline yet, so it is held until the engine finishes
	// writing it. A line split across two reads would otherwise be classified as
	// two lines, and only one of them would say anything.
	logCarry_ = freshly.substr(start);
}

void Engine::MonitorLoop() {
	int64_t lastTrafficPoll = 0;
	HANDLE waits[3] = {stopEvent_, wakeEvent_, process_};
	bool readerOpen = true;
	for (;;) {
		const DWORD wait =
		    WaitForMultipleObjects(3, waits, FALSE, kLoopWakeMillis);
		if (wait == WAIT_FAILED) {
			break;
		}

		DrainLines();
		ReadNewLogLines();
		EnterCriticalSection(&lock_);
		readerOpen = !readerDone_;
		LeaveCriticalSection(&lock_);

		const int64_t now = NowMillis();
		// Counters are only reported while the tunnel is carrying them. While
		// the engine is reconnecting, the file is either stale or half-written,
		// and a series of "handshaked" events is what the Dart side reads as
		// "verify again" — which would turn a reconnect into a leak check per
		// second.
		if (running_ && connected_ && now - lastTrafficPoll >= kTrafficPollMillis) {
			lastTrafficPoll = now;
			int64_t rxBytes = 0;
			int64_t txBytes = 0;
			if (ReadStatusFile(&rxBytes, &txBytes)) {
				onTraffic_(rxBytes, txBytes);
			}
		}

		if (process_ != nullptr &&
		    WaitForSingleObject(process_, 0) == WAIT_OBJECT_0) {
			// The engine is gone. Its last lines may still be in flight through
			// the pipe, and the reader thread may not have read them yet, so the
			// rest of its output is collected before the exit is reported.
			for (int attempt = 0; attempt < 10 && readerOpen; ++attempt) {
				Sleep(50);
				DrainLines();
				ReadNewLogLines();
				EnterCriticalSection(&lock_);
				readerOpen = !readerDone_;
				LeaveCriticalSection(&lock_);
			}
			break;
		}
		// A stop asked for leaves the shutdown to Stop(), which performs it on
		// the caller's thread and joins this thread once the process is gone.
	}

	DWORD code = 0;
	if (process_ != nullptr) {
		GetExitCodeProcess(process_, &code);
	}
	if (!stopRequested_) {
		ReportExit(code);
	}
}

void Engine::OnOutputLine(const std::string& line) {
	const std::string text = RedactForReport(line);
	{
		EnterCriticalSection(&lock_);
		recentLines_.push_back(text);
		if (recentLines_.size() > 6) {
			recentLines_.erase(recentLines_.begin());
		}
		LeaveCriticalSection(&lock_);
	}
	if (line.find("Initialization Sequence Completed") != std::string::npos) {
		if (line.find(" With Errors") != std::string::npos ||
		    line.find(" with errors") != std::string::npos) {
			// The engine finished its TLS handshake and brought the interface
			// up, but a step after that failed — on Windows normally the DNS
			// or a route. That is still a real handshake, so it is reported
			// as one and the app's own verification decides what it is
			// worth. Reporting only "established" here left the app waiting
			// for a handshake that had already happened, until its deadline
			// turned a nearly working tunnel into a timeout with no cause.
			connected_ = true;
			everConnected_ = true;
			lastHandshakeAtMillis_ = NowMillis();
			onState_("handshaked", lastHandshakeAtMillis_);
			return;
		}
		connected_ = true;
		everConnected_ = true;
		lastHandshakeAtMillis_ = NowMillis();
		onState_("handshaked", lastHandshakeAtMillis_);
		return;
	}
	if (line.find("received, process restarting") != std::string::npos ||
	    line.find("Restart pause,") != std::string::npos) {
		// A restart before the first handshake is OpenVPN retrying, which is
		// what `resolv-retry infinite` asks for. Calling that "reconnecting"
		// would describe a tunnel that was never up.
		if (everConnected_) {
			connected_ = false;
			onState_("reconnecting", 0);
		}
		return;
	}
	if (line.find("AUTH: Received control message: AUTH_FAILED") !=
	    std::string::npos) {
		// Terminal by construction: OpenVPN exits after this rather than
		// retrying, because retrying the same credentials cannot help.
		failureReported_ = true;
		onFailure_("ovpn.auth_failed",
		           "The server rejected the username and password.");
		return;
	}
	if (line.find("Options error") != std::string::npos ||
	    line.find("Exiting due to fatal error") != std::string::npos ||
	    line.find("TLS handshake failed") != std::string::npos ||
	    line.find("Cannot load") != std::string::npos ||
	    line.find("Assertion failed") != std::string::npos ||
	    line.find("ERROR:") != std::string::npos ||
	    line.find("Error:") != std::string::npos) {
		// Kept rather than reported immediately: OpenVPN retries through most
		// errors while connecting, and reporting the first one would kill an
		// attempt that was about to succeed. When the process exits, this line
		// is what the failure says.
		//
		// One line must never win that honour: OpenVPN appends the same
		// generic sentence — "Exiting due to fatal error" — after *every*
		// fatal error, immediately after the line that names the cause
		// (src/openvpn/error.c: `msg(M_INFO, "Exiting due to fatal error")`).
		// Letting it overwrite the cause would report the identical sentence
		// to the user no matter what killed the engine, which is exactly what
		// the report exists to avoid.
		const bool genericTerminator =
		    line.find("Exiting due to fatal error") != std::string::npos;
		EnterCriticalSection(&lock_);
		if (!genericTerminator || lastErrorLine_.empty()) {
			lastErrorLine_ = text;
		}
		LeaveCriticalSection(&lock_);
	}
}

bool Engine::ReadStatusFile(int64_t* rxBytes, int64_t* txBytes) {
	HANDLE file = CreateFileW(paths_.status.c_str(), GENERIC_READ,
	                          FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
	                          OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
	if (file == INVALID_HANDLE_VALUE) {
		return false;
	}
	char buffer[4096] = {0};
	DWORD read = 0;
	const BOOL ok = ReadFile(file, buffer, sizeof(buffer) - 1, &read, nullptr);
	CloseHandle(file);
	if (ok == FALSE || read == 0) {
		return false;
	}
	buffer[read] = '\0';

	// The engine rewrites this file in place, so a read can land in the middle
	// of a rewrite and see half of it. The `END` line is the engine's own marker
	// that it finished writing, so a sample without one is discarded rather than
	// reported as a byte count nobody observed.
	const std::string contents(buffer);
	if (contents.find("\nEND") == std::string::npos &&
	    contents.rfind("END", 0) != 0) {
		return false;
	}

	int64_t rx = -1;
	int64_t tx = -1;
	size_t cursor = 0;
	while (cursor < contents.size()) {
		const size_t newline = contents.find('\n', cursor);
		const std::string line =
		    newline == std::string::npos ? contents.substr(cursor)
		                                 : contents.substr(cursor, newline - cursor);
		if (newline == std::string::npos) {
			cursor = contents.size();
		} else {
			cursor = newline + 1;
		}
		auto valueOf = [&line](const char* key) -> int64_t {
			const size_t keyLength = std::strlen(key);
			if (line.compare(0, keyLength, key) != 0) {
				return -1;
			}
			const size_t comma = line.find(',', keyLength);
			if (comma == std::string::npos) {
				return -1;
			}
			return std::atoll(line.c_str() + comma + 1);
		};
		const int64_t readBytes = valueOf("TUN/TAP read bytes,");
		if (readBytes >= 0) {
			rx = readBytes;
		}
		const int64_t writtenBytes = valueOf("TUN/TAP write bytes,");
		if (writtenBytes >= 0) {
			tx = writtenBytes;
		}
	}
	if (rx < 0 || tx < 0) {
		return false;
	}
	*rxBytes = rx;
	*txBytes = tx;
	return true;
}

void Engine::ReportExit(DWORD exitCode) {
	if (reported_) {
		return;
	}
	reported_ = true;
	if (failureReported_) {
		return;  // Already said something more specific than "it exited".
	}
	if (everConnected_) {
		// The tunnel was up and is now gone. That is a failure, not a
		// disconnect: nobody asked for it.
		std::string reason = "The tunnel stopped unexpectedly.";
		{
			EnterCriticalSection(&lock_);
			reason = lastErrorLine_.empty() ? reason : lastErrorLine_;
			LeaveCriticalSection(&lock_);
		}
		onFailure_("ovpn.engine_exited", reason);
		return;
	}
	// It never came up. The reason is whatever the engine last complained about.
	std::string reason = "The OpenVPN engine exited before the tunnel came up.";
	std::string code = "ovpn.engine_exited";
	{
		EnterCriticalSection(&lock_);
		if (!lastErrorLine_.empty()) {
			reason = lastErrorLine_;
		}
		// When all that was captured is the generic terminator, the cause is
		// one of the lines just before it, in words this program does not
		// match on. Report those lines instead of a sentence naming nothing.
		if (lastErrorLine_.empty() ||
		    lastErrorLine_.find("Exiting due to fatal error") !=
		        std::string::npos) {
			std::string detail;
			const size_t count = recentLines_.size();
			const size_t from = count > 4 ? count - 4 : 0;
			for (size_t i = from; i < count; ++i) {
				if (!detail.empty()) {
					detail += " | ";
				}
				detail += recentLines_[i];
			}
			if (!detail.empty()) {
				reason = detail;
			}
		}
		LeaveCriticalSection(&lock_);
	}
	if (reason.find("TLS handshake failed") != std::string::npos ||
	    reason.find("TLS Error") != std::string::npos) {
		code = "ovpn.tls_failed";
	} else if (reason.find("Options error") != std::string::npos) {
		code = "ovpn.config_rejected";
	} else if (reason.find("AUTH_FAILED") != std::string::npos) {
		code = "ovpn.auth_failed";
	} else if (reason.find("wintun") != std::string::npos ||
	           reason.find("Wintun") != std::string::npos ||
	           reason.find("TAP") != std::string::npos ||
	           reason.find("adapter") != std::string::npos) {
		code = "ovpn.driver_failed";
	}
	onFailure_(code, reason);
}

}  // namespace ovpn
}  // namespace phantrix
