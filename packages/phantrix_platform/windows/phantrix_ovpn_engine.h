// The engine driver used by the elevated helper.
//
// This file runs `openvpn.exe` from the bundled community binaries and reads
// what it says. It performs no cryptography, no TLS and no packet handling; the
// official engine does all of that. What this file does is the part a VPN
// product gets wrong:
//
//   * start the engine with an argument array, never through a shell;
//   * decide state from text the engine actually printed, and never invent it;
//   * stop the engine gracefully, and prove it is gone before saying so;
//   * read byte counters from the statistics file the engine writes itself.
//
// ## Why the engine runs as a child of the helper, not as a service
//
// A Windows service would survive the app closing and would need an install
// step with its own elevation. A child process of the elevated helper can be
// started and stopped on demand, and dies with the helper — which itself exits
// when the unelevated app that launched it goes away, because the helper waits
// on the app's process handle for its whole life.
//
// ## Why never `--daemon`
//
// A daemonised `openvpn.exe` detaches from the console it was started from, and
// a detached process cannot be sent a console control event, cannot be waited
// on from this process, and is not a child of anything that can reap it. The
// helper monitors the engine as its own child, which is the only way "the
// tunnel stopped" is a thing this code knows rather than assumes.

#ifndef PHANTRIX_OVPN_ENGINE_H_
#define PHANTRIX_OVPN_ENGINE_H_

#include <windows.h>

#include <cstdint>
#include <functional>
#include <string>
#include <vector>

namespace phantrix {
namespace ovpn {

using StateCallback = std::function<void(const std::string& state,
                                         int64_t handshakeAtMillis)>;
using TrafficCallback = std::function<void(int64_t rxBytes, int64_t txBytes)>;
using FailureCallback =
    std::function<void(const std::string& code, const std::string& message)>;

struct EnginePaths {
  // The profile the engine reads. Written by the plugin, never by this process.
  std::wstring profile;
  // The statistics file the engine writes and this process reads.
  std::wstring status;
  // The log file the engine writes; the helper's own copy of what it saw.
  std::wstring log;
  // The directory holding `openvpn.exe` and `wintun.dll`.
  std::wstring engineDirectory;
  // The name of the Wintun adapter the engine must use. OpenVPN does not
  // create Wintun adapters when it is started directly, so the helper creates
  // one and names it here; empty means "let the engine look for one".
  std::wstring deviceNode;
};

class Engine {
 public:
  Engine(StateCallback onState, TrafficCallback onTraffic,
         FailureCallback onFailure);
  ~Engine();

  // Launches `openvpn.exe`. Returns false with `*errorCode` classed when the
  // process could not be started at all; a process that starts and then fails
  // is reported through the failure callback, because that path has a reason.
  bool Start(const EnginePaths& paths, std::string* errorCode,
             std::string* errorMessage);

  // Asks the engine to stop, waits for it, then kills it if it is still there.
  // Returns the process exit code, or 0xFFFFFFFF when it had to be terminated.
  DWORD Stop();

  // True between a successful Start and the engine process exiting.
  bool running() const { return running_; }

 private:
  // Reads the engine's output line by line and decides what each line means.
  void OnOutputLine(const std::string& line);
  // Classifies every line the reader collected since the last call.
  void DrainLines();
  // Reads whatever the engine has appended to its own log since the last call,
  // and classifies it. --log sends everything the engine prints to that file,
  // so it is the source of truth rather than the pipe.
  void ReadNewLogLines();
  // The thread that reads the engine's output until the pipe reaches end of
  // stream.
  static DWORD WINAPI ReaderThread(LPVOID context);
  // Reads the statistics file. Returns true when it could be parsed.
  bool ReadStatusFile(int64_t* rxBytes, int64_t* txBytes);
  // The monitoring loop: drains output, polls statistics, watches the process.
  void MonitorLoop();
  // Sends the engine's own exit text, classified, once it has gone.
  void ReportExit(DWORD exitCode);

  StateCallback onState_;
  TrafficCallback onTraffic_;
  FailureCallback onFailure_;

  EnginePaths paths_;
  HANDLE process_ = nullptr;
  HANDLE outputRead_ = nullptr;
  HANDLE outputWrite_ = nullptr;
  HANDLE inputRead_ = nullptr;
  HANDLE stopEvent_ = nullptr;
  HANDLE wakeEvent_ = nullptr;
  HANDLE monitorThread_ = nullptr;
  HANDLE readerThread_ = nullptr;

  mutable CRITICAL_SECTION lock_;
  bool running_ = false;
  bool stopRequested_ = false;
  bool connected_ = false;
  bool everConnected_ = false;
  bool failureReported_ = false;
  bool reported_ = false;
  bool readerDone_ = false;
  int64_t lastHandshakeAtMillis_ = 0;
  // How far into the engine's own log this process has already read, and the tail
  // of a line that was cut off mid-write.
  DWORD logOffset_ = 0;
  std::string logCarry_;
  // The last line of engine output that looked like an error, kept so the exit
  // reason can name the cause rather than "it exited".
  std::string lastErrorLine_;
  // The last few lines the engine printed, so a fatal exit can say what came
  // just before OpenVPN's generic "Exiting due to fatal error" sentence.
  std::vector<std::string> recentLines_;
  // Raw lines the reader thread collected and the monitor thread has not yet
  // classified.
  std::vector<std::string> pendingLines_;
};

}  // namespace ovpn
}  // namespace phantrix

#endif  // PHANTRIX_OVPN_ENGINE_H_
