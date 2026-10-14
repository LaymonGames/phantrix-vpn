// Support shared by the Windows OpenVPN plugin and its elevated helper.
//
// Everything in this file exists to answer four questions, and the answers are
// the same on both sides of the named pipe:
//
//   1. Where may files live? (`AppDataDirectory`, `SessionDirectory`)
//   2. What may a profile contain? (`RejectUnsafeDirectives`)
//   3. How is a message framed? (`WriteMessage`, `ReadMessage`)
//   4. What is safe to repeat out loud? (`RedactForReport`)
//
// The helper runs elevated and consumes the profile, so the check in (2) is run
// on both sides — once before the file is written, once again by the process
// that is about to hand it to a system-privileged `openvpn.exe`. The plugin
// already normalises the profile in Dart; this is defence in depth for the case
// where that assumption turns out to be wrong.

#ifndef PHANTRIX_OVPN_SUPPORT_H_
#define PHANTRIX_OVPN_SUPPORT_H_

#include <windows.h>

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>
namespace phantrix {
namespace ovpn {

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------

// The app's per-user data directory, created if necessary.
//
// `%LOCALAPPDATA%\Phantrix` rather than a directory beside the executable: a
// location under Program Files is shared by every account on the machine, and a
// directory that holds an OpenVPN profile holds a private key.
std::wstring AppDataDirectory();

// The directory one connection's scratch files live in, created if necessary.
// It is created with an explicit DACL (see `RestrictToUserAndSystem`).
std::wstring SessionDirectory(const std::wstring& sessionId);

// Deletes a directory tree. Used to remove the session directory, which holds
// the profile and the engine's log, after the tunnel stops.
bool RemoveTree(const std::wstring& path);

// The directory containing the bundled OpenVPN binaries, given the directory
// the calling module lives in.
//
// The bundle is `<app bundle>\openvpn\`, which is where the build puts it
// (`install(DIRECTORY bundle/openvpn ...)` in the plugin's CMakeLists). It is
// always resolved *relative to a module on disk*, never from PATH and never from
// the request, so a poisoned environment cannot make the app execute an
// attacker-chosen binary.
std::wstring OpenVpnDirectory(const std::wstring& moduleDirectory);
std::wstring OpenVpnExecutable(const std::wstring& moduleDirectory);
std::wstring HelperExecutable(const std::wstring& moduleDirectory);

// True when the bundled engine is present on disk.
bool OpenVpnBundlePresent(const std::wstring& moduleDirectory);

// ---------------------------------------------------------------------------
// Permissions
// ---------------------------------------------------------------------------

// Restricts `path` to the current user and LocalSystem, and nothing else.
bool RestrictToUserAndSystem(const std::wstring& path, bool isDirectory);

// Writes `contents` to `path` with an owner-only DACL, deleting the file if the
// DACL cannot be applied. A profile that cannot be secured must not be left
// behind, and must not be connected with either.
bool WriteRestrictedFile(const std::wstring& path, const std::string& contents);

// ---------------------------------------------------------------------------
// Profile safety
// ---------------------------------------------------------------------------

struct ProfileRejection {
  // A stable machine code, forwarded to Dart as the error code.
  const char* code;
  // A human sentence naming the directive and what it would have done. It is
  // shown to the user, so it names the behaviour rather than the line.
  const char* reason;
};

// Rejects a profile that asks the engine to do something this backend will not
// do for it. Returns false with `*out` filled in when it finds one.
//
// The profile is written by Dart from a validated configuration, so this should
// never fire. It exists because the file is read by an elevated process, and
// "the other side already checked" is not a security property.
bool RejectUnsafeDirectives(const std::string& profile, ProfileRejection* out);

// ---------------------------------------------------------------------------
// Report safety
// ---------------------------------------------------------------------------

// The longest line of engine output that may reach the UI.
constexpr size_t kMaxReportChars = 400;

// Turns a line of the engine's log into something safe to show a user.
//
// The engine's log is not a trusted source: it echoes the server's answers,
// including the reason string that comes back with `AUTH_FAILED`. Anything that
// looks like credential material is replaced wholesale, and what remains is
// truncated to one bounded line.
std::string RedactForReport(const std::string& line);

// ---------------------------------------------------------------------------
// Named pipe messages
// ---------------------------------------------------------------------------

// The pipe the plugin creates and the helper connects to. The full name is
// built per session with the process id and a random token: pipes are
// machine-wide rather than session-wide, so a fixed name would let a stale
// helper from an earlier run answer a request nobody made.
constexpr wchar_t kPipePrefix[] = L"\\\\.\\pipe\\PhantrixTunnel-";

// A per-session token the helper must echo before the plugin believes anything
// it says. It is generated by the plugin and passed as an argument to the one
// helper it launches, so the plugin is only ever talking to the process it
// started. It is not a boundary against a program already running as the same
// user — the pipe's DACL is not either — and is not described as one.
std::wstring MakePipeName();

// The security descriptor the pipe is created with.
//
// Two properties matter:
//
//   * The DACL grants the current user and LocalSystem only, and is marked
//     protected so a permissive parent cannot widen it.
//   * The mandatory label is **Medium**. A process may not write to an object
//     labelled above its own integrity level, so this stops a Low-integrity
//     process (an AppContainer / Protected mode browser) on the same session
//     from injecting states into a running tunnel. The elevated helper runs
//     High, which is *above* Medium and therefore unaffected.
std::wstring PipeSecurityDescriptorString();

// A token meaning "this is a Phantrix tunnel message and nothing else".
constexpr uint32_t kMessageMagic = 0x54475456;  // 'VTGT', little-endian.

// Every message the two sides exchange is one of these. There is deliberately
// no "arbitrary command" type: the only instruction the helper will act on is
// `kStop`.
enum class MessageType : uint16_t {
  kStart = 1,        // plugin -> helper: paths, and nothing else
  kStarted = 2,      // helper -> plugin: the engine process is running
  kState = 3,        // helper -> plugin: a state label, and a handshake time
  kTraffic = 4,      // helper -> plugin: counters read from the status file
  kFailed = 5,       // helper -> plugin: engine-reported code and reason
  kExited = 6,       // helper -> plugin: the engine process has gone
  kStop = 7,         // plugin -> helper: tear the tunnel down
  kDisconnected = 8, // helper -> plugin: teardown complete, exiting
  kShutdown = 9,     // plugin -> helper: exit without touching the tunnel
  kHello = 10,       // helper -> plugin: the session token, echoed
};

// One framed message.
//
// Fields are length-prefixed UTF-8 strings rather than a `key=value` text
// format, so a value containing `=` or `,` is a value and not a separator. The
// only strings that ever travel are ones this program generated: paths it chose,
// states it decided, and reasons the engine produced.
struct Message {
  MessageType type = MessageType::kShutdown;
  std::vector<std::string> fields;
};

// Writes one message. Returns false when the pipe is gone, which is how the
// plugin learns the helper has died.
bool WriteMessage(HANDLE pipe, const Message& message);

// Extracts one complete framed message from the front of `carry`, removing the
// bytes it consumed.
//
// A byte-mode pipe does not preserve message boundaries, so one read is not one
// message: a reader appends what it reads to a carry buffer and calls this until
// it empties. This is what both sides' reader threads use.
bool TakeMessage(std::vector<uint8_t>* carry, Message* message);

// Reads one message on a blocking pipe. Not used by either side's reader thread,
// which must keep the handle free for writes; it exists for code that reads a
// pipe nothing else is using.
bool ReadMessage(HANDLE pipe, Message* message);

// Convenience for the common one-field and two-field messages.
Message MakeMessage(MessageType type, std::vector<std::string> fields = {});

// ---------------------------------------------------------------------------
// Small conversions
// ---------------------------------------------------------------------------

std::wstring Utf8ToWide(const std::string& value);
std::string WideToUtf8(const std::wstring& value);

// A random 128-bit token in lowercase hex, used in the pipe name and as the
// session's scratch directory name.
std::wstring RandomToken();

// Unix milliseconds, from the system clock, of "now".
int64_t NowMillis();

}  // namespace ovpn
}  // namespace phantrix

#endif  // PHANTRIX_OVPN_SUPPORT_H_
