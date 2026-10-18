// Linux tunnel backend for Phantrix.
//
// ## What this does
//
// The cryptography, the handshake and the packet routing are performed by the
// **Linux kernel's own WireGuard implementation**, driven through the
// official `wireguard-tools` commands (`wg` and `wg-quick`). This file
// implements no part of the WireGuard protocol and must never do so.
//
// The flow is:
//
//   validated Dart WgConfig
//     -> a `wg-quick` configuration file
//     -> `wg-quick up <file>` (via pkexec)
//     -> the kernel module owns the data path
//
// ## Why the tooling, not a userspace tunnel
//
// WireGuard has been in the Linux kernel since 5.6 and `wireguard-tools` is
// its canonical user-space interface. Using it means the data path is the
// kernel's, which is what every other Linux VPN uses. There is deliberately no
// userspace fallback: shipping a second, separately-audited data path would be
// a large amount of new risk for no benefit, and a system without kernel
// support is reported as unsupported rather than silently downgraded.
//
// ## Privilege
//
// Creating a network interface needs `CAP_NET_ADMIN`. A desktop application
// does not have it, so this backend elevates through `pkexec`, which shows a
// **visible system dialog** naming the program and asking for an
// administrator password. This code never suppresses that prompt, caches a
// credential, or escalates silently. If the user declines, the attempt fails
// and the failure is reported; the app does not pretend the tunnel came up.
//
// ## Injection
//
// The configuration file is read by a process running as root. A newline
// inside any value would therefore be able to append an arbitrary `PostUp`
// directive and gain root command execution, so every value is stripped of
// newlines and written on its own line. This is the single most important
// defensive check in the file.

#include "include/phantrix_platform/phantrix_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <glib.h>
#include <glib/gstdio.h>

#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include <spawn.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

// `open` for the child's /dev/null redirection.
#include <fcntl.h>

// `environ` is declared by POSIX only under a feature-test macro, and the
// Flutter plugin build does not set one. Declaring it directly is the
// portable way to pass the current environment to posix_spawnp.
extern char** environ;

namespace {

// flutter_linux's constructors return the concrete subtype
// (FlMethodSuccessResponse and friends) while the method and event channels
// take the base FlMethodResponse and FlMethodCodec. Those structs are only
// forward declared, so C++ sees no relationship between them and the
// conversion has to be written out.
template <typename T>
FlMethodResponse* asResponse(T* response) {
	return reinterpret_cast<FlMethodResponse*>(response);
}

template <typename T>
FlMethodCodec* asCodec(T* codec) {
	return reinterpret_cast<FlMethodCodec*>(codec);
}

constexpr char kMethodChannelName[] = "dev.phantrix.phantrix/tunnel";
constexpr char kEventChannelName[] = "dev.phantrix.phantrix/tunnelEvents";

// The interface name. Fixed rather than per-server so a running tunnel is
// always findable, and so no request can choose a name that collides with a
// real interface.
constexpr char kInterfaceName[] = "phantrix0";

/// Where the configuration lives between the Dart call and `wg-quick up`.
///
/// The kernel tooling reads from `/etc/wireguard`, which only root may write.
/// A first run therefore has to place the file there, which needs elevation —
/// so the write is folded into the same `pkexec` call that brings the tunnel
/// up, rather than being attempted separately and failing confusingly.
std::string configPath() {
	return std::string("/etc/wireguard/") + kInterfaceName + ".conf";
}

// ---------------------------------------------------------------------------
// Capability probing
// ---------------------------------------------------------------------------

struct ToolAvailability {
	bool wg = false;
	bool wgQuick = false;
	bool kernelSupport = false;
};

/// True when `program` is on PATH.
///
/// GLib's `g_find_program_in_path` is used rather than
/// `std::system("command -v ...")` so nothing is executed
/// and nothing has to be shell-quoted. Searching PATH by
/// hand would be the same work with more ways to get it
/// wrong.
bool isOnPath(const char* program) {
	gchar* found = g_find_program_in_path(program);
	if (found == nullptr) {
		return false;
	}
	g_free(found);
	return true;
}

/// Probes for the official tooling and for kernel support.
///
/// A missing piece is reported as unsupported rather than worked around.
/// Guessing at a substitute would produce an app that appears to work while
/// providing none of the guarantees Phantrix claims.
ToolAvailability probe() {
	ToolAvailability result;
	result.wg = isOnPath("wg");
	result.wgQuick = isOnPath("wg-quick");

	// Either the module is already loaded, or it is built in and therefore
	// visible in /proc/crypto. Reading a file needs no privilege, which keeps
	// this probe usable before any elevation.
	if (g_file_test("/sys/module/wireguard/version", G_FILE_TEST_EXISTS)) {
		result.kernelSupport = true;
	} else {
		FILE* crypto = g_fopen("/proc/crypto", "r");
		if (crypto != nullptr) {
			char line[512];
			while (fgets(line, sizeof(line), crypto) != nullptr) {
				if (strstr(line, "wireguard") != nullptr) {
					result.kernelSupport = true;
					break;
				}
			}
			fclose(crypto);
		}
	}
	return result;
}

// ---------------------------------------------------------------------------
// Configuration file
// ---------------------------------------------------------------------------

/// Strips anything that could terminate a line in a root-privileged file.
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

/// Renders a `wg-quick` configuration.
///
/// A missing MTU is omitted rather than defaulted, so the kernel's own default
/// applies and nothing fictional is written to disk.
std::string renderConfig(const WireGuardInterface& wgInterface,
                         const std::vector<WireGuardPeer>& peers,
                         std::string* errorMessage) {
	if (sanitize(wgInterface.privateKey).empty()) {
		*errorMessage = "The tunnel configuration has no private key.";
		return "";
	}
	if (peers.empty()) {
		*errorMessage = "The tunnel configuration has no peer to connect to.";
		return "";
	}

	std::string out = "[Interface]\n";
	out += "PrivateKey = " + sanitize(wgInterface.privateKey) + "\n";
	for (const auto& address : wgInterface.addresses) {
		out += "Address = " + sanitize(address) + "\n";
	}
	if (!wgInterface.dns.empty()) {
		out += "DNS = ";
		for (size_t i = 0; i < wgInterface.dns.size(); ++i) {
			if (i > 0) {
				out += ", ";
			}
			out += sanitize(wgInterface.dns[i]);
		}
		out += "\n";
	}
	if (wgInterface.mtu > 0) {
		out += "MTU = " + std::to_string(wgInterface.mtu) + "\n";
	}
	out += "\n";

	for (const auto& peer : peers) {
		if (sanitize(peer.publicKey).empty() || peer.allowedIps.empty()) {
			*errorMessage = "A peer in the tunnel configuration is incomplete.";
			return "";
		}
		out += "[Peer]\n";
		out += "PublicKey = " + sanitize(peer.publicKey) + "\n";
		if (!peer.presharedKey.empty()) {
			out += "PresharedKey = " + sanitize(peer.presharedKey) + "\n";
		}
		if (!peer.endpointHost.empty() && peer.endpointPort > 0) {
			out += "Endpoint = " + sanitize(peer.endpointHost) + ":" +
			       std::to_string(peer.endpointPort) + "\n";
		}
		out += "AllowedIPs = ";
		for (size_t i = 0; i < peer.allowedIps.size(); ++i) {
			if (i > 0) {
				out += ", ";
			}
			out += sanitize(peer.allowedIps[i]);
		}
		out += "\n";
		if (peer.persistentKeepalive > 0) {
			out += "PersistentKeepalive = " +
			       std::to_string(peer.persistentKeepalive) + "\n";
		}
		out += "\n";
	}
	return out;
}

// ---------------------------------------------------------------------------
// JSON reading
// ---------------------------------------------------------------------------

FlValue* mapGet(FlValue* map, const char* key) {
	if (map == nullptr || fl_value_get_type(map) != FL_VALUE_TYPE_MAP) {
		return nullptr;
	}
	return fl_value_lookup_string(map, key);
}

std::string getString(FlValue* map, const char* key) {
	FlValue* value = mapGet(map, key);
	if (value == nullptr || fl_value_get_type(value) != FL_VALUE_TYPE_STRING) {
		return "";
	}
	const char* text = fl_value_get_string(value);
	return text == nullptr ? "" : text;
}

int getInt(FlValue* map, const char* key) {
	FlValue* value = mapGet(map, key);
	if (value == nullptr || fl_value_get_type(value) != FL_VALUE_TYPE_INT) {
		return 0;
	}
	return static_cast<int>(fl_value_get_int(value));
}

std::vector<std::string> getStringList(FlValue* map, const char* key) {
	std::vector<std::string> out;
	FlValue* value = mapGet(map, key);
	if (value == nullptr || fl_value_get_type(value) != FL_VALUE_TYPE_LIST) {
		return out;
	}
	for (size_t i = 0; i < fl_value_get_length(value); ++i) {
		FlValue* entry = fl_value_get_list_value(value, i);
		if (fl_value_get_type(entry) == FL_VALUE_TYPE_STRING) {
			const char* text = fl_value_get_string(entry);
			if (text != nullptr) {
				out.push_back(text);
			}
		}
	}
	return out;
}

/// Reads the WireGuard section of a request.
///
/// Returns false with a user-safe reason when the request cannot be used.
/// OpenVPN is reported as unsupported rather than being silently ignored,
/// because this backend cannot speak it.
bool parseRequest(FlValue* args, WireGuardInterface* wgInterface,
                  std::vector<WireGuardPeer>* peers, std::string* errorMessage) {
	if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
		*errorMessage = "The tunnel request was not in a form this platform can read.";
		return false;
	}
	FlValue* wireguard = mapGet(args, "wireguard");
	if (wireguard == nullptr || fl_value_get_type(wireguard) != FL_VALUE_TYPE_MAP) {
		*errorMessage =
		    "This build can only start a WireGuard tunnel on Linux, and the "
		    "selected server offers OpenVPN.";
		return false;
	}

	wgInterface->privateKey = getString(wireguard, "privateKey");
	wgInterface->addresses = getStringList(wireguard, "addresses");
	wgInterface->dns = getStringList(wireguard, "dns");
	wgInterface->mtu = getInt(wireguard, "mtu");

	FlValue* peersValue = mapGet(wireguard, "peers");
	if (peersValue == nullptr || fl_value_get_type(peersValue) != FL_VALUE_TYPE_LIST) {
		*errorMessage = "The tunnel needs at least one peer, and none was supplied.";
		return false;
	}
	if (fl_value_get_length(peersValue) == 0) {
		*errorMessage = "The tunnel needs at least one peer, and none was supplied.";
		return false;
	}

	for (size_t i = 0; i < fl_value_get_length(peersValue); ++i) {
		FlValue* entry = fl_value_get_list_value(peersValue, i);
		if (fl_value_get_type(entry) != FL_VALUE_TYPE_MAP) {
			*errorMessage = "A peer in the tunnel configuration is malformed.";
			return false;
		}
		WireGuardPeer peer;
		peer.publicKey = getString(entry, "publicKey");
		peer.presharedKey = getString(entry, "presharedKey");
		peer.allowedIps = getStringList(entry, "allowedIps");
		peer.persistentKeepalive = getInt(entry, "persistentKeepalive");
		// The endpoint arrives as "host:port" and is split so the value written
		// to disk is rebuilt from two parts rather than passed through whole.
		//
		// `strtoul` rather than `atoi`: `atoi` returns 0 for text that is not a
		// number, and 0 is indistinguishable from a syntactically valid port
		// that is merely absent. A port that does not parse is then refused
		// downstream, because a peer with a broken endpoint cannot be connected
		// to and must not be written to the configuration as though it could.
		const std::string endpoint = getString(entry, "endpoint");
		const size_t colon = endpoint.rfind(':');
		if (colon != std::string::npos && colon + 1 < endpoint.size()) {
			peer.endpointHost = endpoint.substr(0, colon);
			const std::string portText = endpoint.substr(colon + 1);
			char* end = nullptr;
			const unsigned long parsed =
			    std::strtoul(portText.c_str(), &end, 10);
			if (end != portText.c_str() && *end == '\0' && parsed > 0 && parsed <= 65535) {
				peer.endpointPort = static_cast<int>(parsed);
			} else {
				// Keep the host so the error names the peer, but leave the port
				// absent so the peer is refused rather than silently written.
				peer.endpointPort = 0;
			}
		}
		peers->push_back(peer);
	}
	return true;
}

// ---------------------------------------------------------------------------
// Elevated execution
// ---------------------------------------------------------------------------

/// Exit codes from `pkexec` that mean "you did not authorise this".
///
/// 126 is authentication denied and 127 is the same when the
/// helper is missing. They are distinguished from every other
/// failure because they need a different response from the
/// user: an authorisation failure asks them to retry and
/// approve the prompt, a tunnel failure asks them to choose a
/// different server.
constexpr int kPkexecAuthDenied = 126;
constexpr int kPkexecAuthCancelled = 127;

/// Runs `pkexec <argv...>` and returns its exit status.
///
/// ## Why not `std::system`
///
/// The previous implementation built a command string and handed it to
/// `std::system`, which runs `/bin/sh -c`. That is the exact pattern the
/// security review flags: anything reachable from a caller — a path from
/// `g_mkstemp`, a value from the request — becomes shell text. Today the
/// values are constrained enough that it was not exploitable, but the
/// guarantee was accidental rather than structural, and it does not survive
/// the next change to the code.
///
/// `posix_spawn` takes the argument vector as an array. There is no shell, so
/// no character in any argument can mean "end of argument" or "new command".
/// An argument containing a quote, a `$`, a semicolon or a newline is passed
/// to the program as the literal characters of the argument, which is the
/// only safe way to hand untrusted input to a root process.
///
/// ## Output
///
/// The child's stdout and stderr are redirected to /dev/null. `wg-quick`
/// prints progress and, on failure, the underlying error. It does not echo
/// the private key, but capturing the child's output would mean joining it
/// into messages sent to Dart, and a future change to the tooling could
/// change that. Not capturing it removes the question entirely.
int runElevated(const std::vector<std::string>& argv) {
	if (argv.empty() || argv[0].empty()) {
		return kPkexecAuthCancelled;
	}

	// Build the argv pkexec receives: pkexec, then the command.
	std::vector<std::string> storage;
	storage.reserve(argv.size() + 1);
	storage.push_back("pkexec");
	for (const auto& arg : argv) {
		storage.push_back(arg);
	}

	// posix_spawn requires a null-terminated array of C strings that stay
	// alive for the duration of the call. A std::vector rather than a
	// variable-length array: that extension is not standard C++ and the
	// build rejects it.
	std::vector<const char*> execArgv;
	execArgv.reserve(storage.size() + 1);
	for (const auto& arg : storage) {
		execArgv.push_back(arg.c_str());
	}
	execArgv.push_back(nullptr);

	// Silence the child's output by pointing both descriptors at /dev/null
	// rather than by closing them, so a tool that writes a lot does not fill
	// a pipe nobody reads.
	const int devNull = open("/dev/null", O_WRONLY);
	if (devNull < 0) {
		return kPkexecAuthCancelled;
	}

	posix_spawn_file_actions_t actions;
	posix_spawn_file_actions_init(&actions);
	posix_spawn_file_actions_adddup2(&actions, devNull, STDOUT_FILENO);
	posix_spawn_file_actions_adddup2(&actions, devNull, STDERR_FILENO);

	pid_t pid = -1;
	const int spawned = posix_spawnp(&pid, "pkexec", &actions, nullptr,
	                                const_cast<char**>(execArgv.data()), environ);
	posix_spawn_file_actions_destroy(&actions);
	close(devNull);

	if (spawned != 0 || pid < 0) {
		return kPkexecAuthCancelled;
	}

	int status = 0;
	// Wait rather than poll: the caller needs the outcome before it can decide
	// whether the interface came up, and there is nothing else to do on this
	// thread meanwhile.
	while (waitpid(pid, &status, 0) < 0) {
		if (errno != EINTR) {
			// The child is unreapable. Report as unauthenticated so the
			// tunnel is not started on an outcome nobody observed.
			return kPkexecAuthCancelled;
		}
	}
	if (WIFEXITED(status)) {
		return WEXITSTATUS(status);
	}
	// Killed by a signal rather than exiting: pkexec uses this when the agent
	// is unavailable or the session is not local, both of which are
	// authorisation problems rather than tunnel problems.
	return kPkexecAuthDenied;
}

/// Writes the configuration where the kernel tooling can read it.
///
/// Needs root, so it goes through the same elevation as the tunnel itself.
bool writeConfigElevated(const std::string& contents, std::string* errorMessage) {
	const std::string path = configPath();
	// Written to a private temporary file first, then moved into place by a
	// single elevated command, so the file is never briefly world-readable in
	// /etc/wireguard.
	g_autofree gchar* temporary = g_build_filename(g_get_tmp_dir(), "phantrix-XXXXXX", nullptr);
	if (temporary == nullptr) {
		*errorMessage = "The tunnel configuration could not be staged.";
		return false;
	}
	const int fd = g_mkstemp(temporary);
	if (fd < 0) {
		*errorMessage = "The tunnel configuration could not be staged.";
		return false;
	}
	const ssize_t written = write(fd, contents.data(), contents.size());
	// 0600 from the moment it exists: it contains the private key.
	fchmod(fd, S_IRUSR | S_IWUSR);
	close(fd);
	if (written != static_cast<ssize_t>(contents.size())) {
		unlink(temporary);
		*errorMessage = "The tunnel configuration could not be staged completely.";
		return false;
	}

	// `install` is run as argv rather than through `sh -c`, so the
	// destination path and the staged path are arguments. Even a path that
	// somehow contained metacharacters could only name a file, never command.
	const int status = runElevated(
	    {"install", "-o", "root", "-g", "root", "-m", "600", temporary, path});
	unlink(temporary);
	if (status != 0) {
		if (status == kPkexecAuthDenied || status == kPkexecAuthCancelled) {
			*errorMessage =
			    "Administrator permission was not granted, so the tunnel "
			    "configuration could not be written. This needs administrator "
			    "rights.";
		} else {
			*errorMessage =
			    "The tunnel configuration could not be written to /etc/wireguard.";
		}
		return false;
	}
	return true;
}

}  // namespace

// ---------------------------------------------------------------------------
// The per-user data directory
// ---------------------------------------------------------------------------

/// The per-user configuration directory, as a method response.
///
/// `$XDG_CONFIG_HOME` is honoured when set, and `$HOME/.config` is the
/// fallback, which is the XDG default and therefore correct even when the
/// variable is unset. This is the user's own directory tree, so a stored
/// configuration is not readable by other accounts on the machine.
///
/// The directory is created with mode 0700. The XDG specification gives the
/// user's own configuration tree 0700, and a file inside it that holds a
/// private key should not be group- or world-readable even by accident.
static FlMethodResponse* dataDirectoryResponse() {
	const gchar* base = g_getenv("XDG_CONFIG_HOME");
	std::string directory;
	if (base != nullptr && base[0] != '\0') {
		directory = std::string(base) + "/phantrix";
	} else {
		const gchar* home = g_getenv("HOME");
		if (home != nullptr && home[0] != '\0') {
			directory = std::string(home) + "/.config/phantrix";
		}
	}
	if (directory.empty()) {
		return asResponse(fl_method_error_response_new(
		    "app_directory",
		    "No private application directory is available: neither "
		    "XDG_CONFIG_HOME nor HOME is set.",
		    nullptr));
	}

	g_autofree gchar* path = g_build_filename(directory.c_str(), nullptr);
	if (path == nullptr) {
		return asResponse(fl_method_error_response_new(
		    "app_directory", "The application directory path could not be built.", nullptr));
	}
	if (g_mkdir_with_parents(path, S_IRWXU) != 0) {
		// A directory that already exists is a success, not a failure.
		if (errno != EEXIST) {
			return asResponse(fl_method_error_response_new(
			    "app_directory", "The application directory could not be created.", nullptr));
		}
	}
	// Re-applied whether the directory was just created or already existed:
	// an existing directory may predate this hardening, and `g_mkdir_with_
	// parents` only sets the mode on creation. Best-effort — a failure here
	// does not refuse the directory, because the store file itself is
	// restricted to 0600 on every write regardless, and refusing to run over
	// a chmod failure (read-only parent, odd filesystem) would turn a
	// hardening step into a denial of service. The mode can only lose bits
	// to the umask, never gain them, so this cannot weaken anything.
	(void)chmod(path, S_IRWXU);

	g_autoptr(FlValue) value = fl_value_new_string(path);
	return asResponse(fl_method_success_response_new(value));
}

// The plugin object
// ---------------------------------------------------------------------------

// The instance struct. The typedef and the class struct both come from
// G_DECLARE_FINAL_TYPE in the header, so this *completes* the type rather
// than declaring it — which is what makes the G_DEFINE_TYPE below valid.
// Without that declaration the class struct would be undeclared and the
// build would fail on `PhantrixPlatformLinux##Class`.
struct _PhantrixPlatformLinux {
	GObject parent_instance;
	FlMethodChannel* methodChannel;
	FlEventChannel* eventChannel;
	gboolean listening;
	gboolean running;
	gchar* pendingInterface;
};

G_DEFINE_TYPE(PhantrixPlatformLinux, phantrix_platform_linux, G_TYPE_OBJECT)

static void phantrix_platform_linux_dispose(GObject* object) {
	PhantrixPlatformLinux* self = PHANTRIX_PLATFORM_LINUX(object);
	g_clear_object(&self->methodChannel);
	g_clear_object(&self->eventChannel);
	g_clear_pointer(&self->pendingInterface, g_free);
	G_OBJECT_CLASS(phantrix_platform_linux_parent_class)->dispose(object);
}

static void phantrix_platform_linux_class_init(PhantrixPlatformLinuxClass* klass) {
	G_OBJECT_CLASS(klass)->dispose = phantrix_platform_linux_dispose;
}

static void phantrix_platform_linux_init(PhantrixPlatformLinux* self) {
	self->methodChannel = nullptr;
	self->eventChannel = nullptr;
	self->listening = FALSE;
	self->running = FALSE;
	self->pendingInterface = nullptr;
}

static void publishState(PhantrixPlatformLinux* self, FlValue* state) {
	// Nothing to publish to until Dart has listened, and sending with no
	// listener is an error the channel reports against this call.
	if (self->eventChannel == nullptr || !self->listening) {
		return;
	}
	g_autoptr(FlValue) message = fl_value_new_map();
	fl_value_set_string_take(message, "state", fl_value_ref(state));
	g_autoptr(GError) error = nullptr;
	fl_event_channel_send(self->eventChannel, message, nullptr, &error);
}

static void publishFailure(PhantrixPlatformLinux* self, const char* code,
                           const std::string& message) {
	if (self->eventChannel == nullptr || !self->listening) {
		return;
	}
	g_autoptr(FlValue) state = fl_value_new_string("failed");
	publishState(self, state);
	g_autoptr(FlValue) detail = fl_value_new_map();
	fl_value_set_string_take(detail, "state", fl_value_new_string("failed"));
	fl_value_set_string_take(detail, "errorCode", fl_value_new_string(code));
	fl_value_set_string_take(detail, "message", fl_value_new_string(message.c_str()));
	g_autoptr(GError) error = nullptr;
	fl_event_channel_send(self->eventChannel, detail, nullptr, &error);
}

static FlMethodResponse* capabilitiesResponse() {
	g_autoptr(FlValue) result = fl_value_new_map();
	fl_value_set_string_take(result, "platform", fl_value_new_string("linux"));
	fl_value_set_string_take(result, "killSwitch", fl_value_new_bool(FALSE));
	fl_value_set_string_take(result, "ipv6Block", fl_value_new_bool(TRUE));
	fl_value_set_string_take(result, "vpnDns", fl_value_new_bool(TRUE));
	fl_value_set_string_take(result, "perApp", fl_value_new_bool(FALSE));
	fl_value_set_string_take(result, "lanBypass", fl_value_new_bool(TRUE));
	fl_value_set_string_take(result, "alwaysOn", fl_value_new_bool(FALSE));
	fl_value_set_string_take(result, "tray", fl_value_new_bool(FALSE));
	fl_value_set_string_take(result, "bootStart", fl_value_new_bool(FALSE));
	fl_value_set_string_take(result, "engine", fl_value_new_string("linux-kernel-wireguard"));

	// Stated plainly, because these are the limits a user will hit.
	g_autoptr(FlValue) limits = fl_value_new_list();
	fl_value_append_take(limits, fl_value_new_string(
	    "Linux support needs the wireguard-tools package and a kernel with "
	    "WireGuard (5.6 or newer). Adding or removing a tunnel needs "
	    "administrator rights. There is no kill switch: if the tunnel drops, "
	    "traffic returns to the physical interface."));
	fl_value_set_string_take(result, "limitations", fl_value_ref(limits));

	return asResponse(fl_method_success_response_new(result));
}

static FlMethodResponse* startTunnel(PhantrixPlatformLinux* self, FlValue* args) {
	// A second request must not create a second interface.
	if (self->running) {
		g_autoptr(FlValue) state = fl_value_new_string("connecting");
		publishState(self, state);
		return asResponse(fl_method_success_response_new(nullptr));
	}

	const ToolAvailability tools = probe();
	if (!tools.wg || !tools.wgQuick) {
		publishFailure(self, "backend.missing_tools",
		               "This system does not have the WireGuard tools installed "
		               "(the wireguard-tools package), so no tunnel can be created.");
		return asResponse(fl_method_error_response_new(
		    "backend.missing_tools", "WireGuard tools are not installed.", nullptr));
	}
	if (!tools.kernelSupport) {
		publishFailure(self, "backend.no_kernel_support",
		               "This kernel has no WireGuard support. Kernels from Linux 5.6 "
		               "include it; older kernels need the wireguard module.");
		return asResponse(fl_method_error_response_new(
		    "backend.no_kernel_support", "The kernel has no WireGuard support.", nullptr));
	}

	WireGuardInterface wgInterface;
	std::vector<WireGuardPeer> peers;
	std::string error;
	if (!parseRequest(args, &wgInterface, &peers, &error)) {
		publishFailure(self, "wg.config_invalid", error);
		return asResponse(fl_method_error_response_new(
		    "wg.config_invalid", error.c_str(), nullptr));
	}

	// A peer with no usable endpoint is refused here, before anything is
	// written to disk. `wg-quick up` would otherwise accept the file and
	// create a peer that can never be reached: the interface would come up,
	// no handshake would ever complete, and the only outward sign would be
	// a tunnel that looks established and carries nothing.
	for (size_t i = 0; i < peers.size(); ++i) {
		const auto& peer = peers[i];
		if (peer.endpointHost.empty() || peer.endpointPort <= 0) {
			error = "Peer " + std::to_string(i + 1) +
			        " has no usable endpoint, so it could never be reached.";
			publishFailure(self, "wg.peer.endpoint_invalid", error);
			return asResponse(fl_method_error_response_new(
			    "wg.peer.endpoint_invalid", error.c_str(), nullptr));
		}
	}

	const std::string contents = renderConfig(wgInterface, peers, &error);
	if (contents.empty()) {
		publishFailure(self, "wg.config_invalid", error);
		return asResponse(fl_method_error_response_new(
		    "wg.config_invalid", error.c_str(), nullptr));
	}

	if (!writeConfigElevated(contents, &error)) {
		publishFailure(self, "permission.denied", error);
		return asResponse(fl_method_error_response_new(
		    "permission.denied", error.c_str(), nullptr));
	}

	// One elevated command brings the tunnel up. A refusal here is either the
	// user cancelling the prompt or the kernel refusing the interface, and the
	// two are told apart because they need different responses from the user.
	//
	// Both commands are argument vectors, so the destination path is an
	// argument to `install` rather than text in a shell command.
	const int status = runElevated({"wg-quick", "up", configPath()});
	if (status != 0) {
		// Tear down whatever `wg-quick up` left half-raised before reporting
		// failure. Leaving a partial interface up is the worst outcome: the
		// device would have a route that carries nothing while the app
		// believes it failed and disconnected.
		(void)runElevated({"wg-quick", "down", configPath()});
		(void)runElevated({"rm", "-f", configPath()});
		if (status == kPkexecAuthDenied || status == kPkexecAuthCancelled) {
			const std::string message =
			    "Administrator permission was not granted, so the tunnel was not "
			    "created. Creating a network interface requires it.";
			publishFailure(self, "permission.denied", message);
			return asResponse(fl_method_error_response_new(
			    "permission.denied", message.c_str(), nullptr));
		}
		const std::string message =
		    "WireGuard could not bring the tunnel up. The server may be "
		    "unreachable or the configuration may be rejected. Run "
		    "`sudo wg-quick up " + configPath() + "` for the full error.";
		publishFailure(self, "tunnel.failed", message);
		return asResponse(fl_method_error_response_new(
		    "tunnel.failed", message.c_str(), nullptr));
	}

	self->running = TRUE;
	g_free(self->pendingInterface);
	self->pendingInterface = g_strdup(kInterfaceName);

	// The interface exists. Whether a handshake has happened is a separate
	// question, answered by the statistics poll, and is not claimed here.
	g_autoptr(FlValue) state = fl_value_new_string("established");
	publishState(self, state);
	return asResponse(fl_method_success_response_new(nullptr));
}

static FlMethodResponse* stopTunnel(PhantrixPlatformLinux* self) {
	// `wg-quick down` restores the routes and the resolver configuration that
	// `wg-quick up` changed. It is run even when the backend believes nothing
	// is running, because a tunnel that crashed or was torn down by the
	// operating system leaves the frontend flag false while the routes are
	// still diverted. Running the down command twice is harmless; leaving a
	// diverted route pointing at an interface that no longer exists is not.
	(void)runElevated({"wg-quick", "down", configPath()});
	self->running = FALSE;
	// The configuration holds a private key, so it does not survive the tunnel
	// it belonged to. A key left in /etc/wireguard after the user disconnected
	// is a credential sitting on disk.
	(void)runElevated({"rm", "-f", configPath()});
	g_clear_pointer(&self->pendingInterface, g_free);
	g_autoptr(FlValue) state = fl_value_new_string("disconnected");
	publishState(self, state);
	return asResponse(fl_method_success_response_new(nullptr));
}

static void methodCallHandler(FlMethodChannel* channel, FlMethodCall* methodCall,
                              gpointer userData) {
	PhantrixPlatformLinux* self = PHANTRIX_PLATFORM_LINUX(userData);
	const gchar* method = fl_method_call_get_name(methodCall);
	FlValue* args = fl_method_call_get_args(methodCall);

	if (strcmp(method, "capabilities") == 0) {
		g_autoptr(FlMethodResponse) response = capabilitiesResponse();
		g_autoptr(GError) error = nullptr;
		fl_method_call_respond(methodCall, response, &error);
		return;
	}
	if (strcmp(method, "requestPermission") == 0) {
		// There is no consent dialog to pre-empt: pkexec shows its own when
		// the tunnel is created. What can be answered is whether the backend
		// is present at all.
		const ToolAvailability tools = probe();
		g_autoptr(FlValue) result = fl_value_new_bool(tools.wg && tools.wgQuick);
		g_autoptr(FlMethodResponse) response =
		    asResponse(fl_method_success_response_new(result));
		g_autoptr(GError) error = nullptr;
		fl_method_call_respond(methodCall, response, &error);
		return;
	}
	if (strcmp(method, "startTunnel") == 0) {
		g_autoptr(FlMethodResponse) response = startTunnel(self, args);
		g_autoptr(GError) error = nullptr;
		fl_method_call_respond(methodCall, response, &error);
		return;
	}
	if (strcmp(method, "stopTunnel") == 0) {
		g_autoptr(FlMethodResponse) response = stopTunnel(self);
		g_autoptr(GError) error = nullptr;
		fl_method_call_respond(methodCall, response, &error);
		return;
	}
	if (strcmp(method, "openVpnSettings") == 0) {
		// No single settings page exists across distributions, and guessing at
		// one would be worse than saying so.
		publishFailure(self, "unsupported",
		               "Linux has no single VPN settings page to open.");
		g_autoptr(FlMethodResponse) response =
		    asResponse(fl_method_success_response_new(nullptr));
		g_autoptr(GError) error = nullptr;
		fl_method_call_respond(methodCall, response, &error);
		return;
	}
	if (strcmp(method, "appDataDirectory") == 0) {
		g_autoptr(FlMethodResponse) response = dataDirectoryResponse();
		g_autoptr(GError) error = nullptr;
		fl_method_call_respond(methodCall, response, &error);
		return;
	}

	g_autoptr(FlMethodResponse) response =
	    asResponse(fl_method_not_implemented_response_new());
	g_autoptr(GError) error = nullptr;
	fl_method_call_respond(methodCall, response, &error);
}

static FlMethodErrorResponse* eventListen(FlEventChannel* channel, FlValue* args,
                                          gpointer userData) {
	PhantrixPlatformLinux* self = PHANTRIX_PLATFORM_LINUX(userData);
	// Accepting the listen is what allows state to be published; returning an
	// error response here would refuse it. There is no per-listener state to
	// set up, so the callback only records that someone is listening.
	(void)channel;
	(void)args;
	self->listening = TRUE;
	return nullptr;
}

static FlMethodErrorResponse* eventCancel(FlEventChannel* channel, FlValue* args,
                                          gpointer userData) {
	PhantrixPlatformLinux* self = PHANTRIX_PLATFORM_LINUX(userData);
	(void)channel;
	(void)args;
	self->listening = FALSE;
	return nullptr;
}

void phantrix_platform_linux_new(FlPluginRegistrar* registrar) {
	PhantrixPlatformLinux* plugin = PHANTRIX_PLATFORM_LINUX(
	    g_object_new(phantrix_platform_linux_get_type(), nullptr));

	g_autoptr(FlStandardMethodCodec) methodCodec = fl_standard_method_codec_new();
	plugin->methodChannel = fl_method_channel_new(
	    fl_plugin_registrar_get_messenger(registrar), kMethodChannelName,
	    asCodec(methodCodec));
	fl_method_channel_set_method_call_handler(
	    plugin->methodChannel, methodCallHandler, g_object_ref(plugin), g_object_unref);

	g_autoptr(FlStandardMessageCodec) messageCodec = fl_standard_message_codec_new();
	plugin->eventChannel = fl_event_channel_new(
	    fl_plugin_registrar_get_messenger(registrar), kEventChannelName,
	    asCodec(messageCodec));
	fl_event_channel_set_stream_handlers(plugin->eventChannel, eventListen, eventCancel,
	                                     g_object_ref(plugin), g_object_unref);

	g_object_unref(plugin);
}

void phantrix_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
	phantrix_platform_linux_new(registrar);
}
