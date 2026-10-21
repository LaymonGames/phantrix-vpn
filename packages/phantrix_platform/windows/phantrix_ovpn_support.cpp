#include "phantrix_ovpn_support.h"

#include <aclapi.h>
#include <sddl.h>

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <random>
#include <vector>
#include <cwchar>

#pragma comment(lib, "Advapi32.lib")

namespace phantrix {
namespace ovpn {

namespace {

// The per-user directory this app owns everything under.
constexpr wchar_t kAppDirectoryName[] = L"Phantrix";

// Below the app directory: the OpenVPN session workspace. Named for the
// protocol rather than for the engine, because the directory outlives whichever
// engine is in it.
constexpr wchar_t kOpenVpnRootName[] = L"openvpn";

// The bundled engine's directory, relative to the application's own bundle.
constexpr wchar_t kOpenVpnBundleName[] = L"openvpn";

// The helper's file name, relative to the application's own bundle.
constexpr wchar_t kHelperName[] = L"phantrix_ovpn_helper.exe";

// The engine's executable, relative to the bundled engine directory.
constexpr wchar_t kOpenVpnExecutableName[] = L"openvpn.exe";

// Integrity SIDs are `S-1-16-<level>`.
//   0x1000 Low, 0x2000 Medium, 0x3000 High, 0x4000 System.
constexpr wchar_t kMediumIntegritySid[] = L"S-1-16-8192";

bool DirectoryExists(const std::wstring& path) {
	const DWORD attributes = GetFileAttributesW(path.c_str());
	return attributes != INVALID_FILE_ATTRIBUTES &&
	       (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0 &&
	       (attributes & FILE_ATTRIBUTE_REPARSE_POINT) == 0;
}

// Creates `path` and every parent that is missing. Returns false only when the
// directory could not be created and does not already exist.
bool CreateDirectoryTree(const std::wstring& path) {
	if (GetFileAttributesW(path.c_str()) != INVALID_FILE_ATTRIBUTES) {
		return DirectoryExists(path);
	}
	size_t cursor = path.find(L'\\', 3);  // Skip the drive root.
	while (cursor != std::wstring::npos) {
		const std::wstring parent = path.substr(0, cursor);
		if (!parent.empty() && !DirectoryExists(parent)) {
			if ((!CreateDirectoryW(parent.c_str(), nullptr) &&
			     GetLastError() != ERROR_ALREADY_EXISTS) || !DirectoryExists(parent)) {
				return false;
			}
		}
		cursor = path.find(L'\\', cursor + 1);
	}
	if ((!CreateDirectoryW(path.c_str(), nullptr) &&
	     GetLastError() != ERROR_ALREADY_EXISTS) || !DirectoryExists(path)) {
		return false;
	}
	return true;
}

// Deletes one file, ignoring "not there".
void DeleteFileQuietly(const std::wstring& path) {
	DeleteFileW(path.c_str());
}

}  // namespace

std::wstring AppDataDirectory() {
	wchar_t buffer[MAX_PATH + 1] = {0};
	const DWORD length =
	    GetEnvironmentVariableW(L"LOCALAPPDATA", buffer, MAX_PATH);
	if (length == 0 || length > MAX_PATH) {
		return std::wstring();
	}
	std::wstring directory(buffer, length);
	directory += L"\\";
	directory += kAppDirectoryName;
	if (!CreateDirectoryTree(directory)) {
		return std::wstring();
	}
	// Applied whether the directory was just created or already existed: an
	// existing directory may predate this hardening, and its ACL is whatever
	// the parent gave it at creation time.
	if (!RestrictToUserAndSystem(directory, true)) {
		return std::wstring();
	}
	return directory;
}

std::wstring SessionDirectory(const std::wstring& sessionId) {
	if (sessionId.size() != 40 || sessionId.substr(0, 8) != L"session-" ||
	    sessionId.find_first_not_of(L"0123456789abcdef", 8) != std::wstring::npos) {
		return std::wstring();
	}
	const std::wstring app = AppDataDirectory();
	if (app.empty() || sessionId.empty()) {
		return std::wstring();
	}
	const std::wstring root = app + L"\\" + kOpenVpnRootName;
	if (!CreateDirectoryTree(root)) {
		return std::wstring();
	}
	// Restricted too: the `openvpn` root itself is created by this code, so its
	// ACL is the one this code chose rather than one inherited from a parent.
	if (!RestrictToUserAndSystem(root, true)) {
		return std::wstring();
	}
	const std::wstring session = root + L"\\" + sessionId;
	if (!CreateDirectoryTree(session)) {
		return std::wstring();
	}
	if (!RestrictToUserAndSystem(session, true)) {
		return std::wstring();
	}
	return session;
}

bool RemoveTree(const std::wstring& path) {
	if (path.empty()) {
		return true;
	}
	// Never enumerate a junction/symlink: cleanup must remove the link, not
	// recursively delete the target with the helper's elevated privileges.
	const DWORD attributes = GetFileAttributesW(path.c_str());
	if (attributes != INVALID_FILE_ATTRIBUTES &&
	    (attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
		return (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0
		           ? RemoveDirectoryW(path.c_str()) != FALSE
		           : DeleteFileW(path.c_str()) != FALSE;
	}
	const std::wstring search = path + L"\\*";
	WIN32_FIND_DATAW entry = {0};
	HANDLE find = FindFirstFileW(search.c_str(), &entry);
	if (find == INVALID_HANDLE_VALUE) {
		// Nothing to enumerate, so either the directory is already gone — which
		// is the state the caller asked for — or it never existed. Both are the
		// requested outcome rather than a failure.
		return GetFileAttributesW(path.c_str()) == INVALID_FILE_ATTRIBUTES ||
		       RemoveDirectoryW(path.c_str()) != FALSE;
	}
	bool ok = true;
	do {
		const wchar_t* name = entry.cFileName;
		if (wcscmp(name, L".") == 0 || wcscmp(name, L"..") == 0) {
			continue;
		}
		const std::wstring child = path + L"\\" + name;
		if ((entry.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) {
			ok = RemoveTree(child) && ok;
		} else {
			DeleteFileQuietly(child);
		}
	} while (FindNextFileW(find, &entry) != FALSE);
	FindClose(find);
	ok = RemoveDirectoryW(path.c_str()) != FALSE && ok;
	return ok;
}

std::wstring OpenVpnDirectory(const std::wstring& moduleDirectory) {
	if (moduleDirectory.empty()) {
		return std::wstring();
	}
	// Two layouts exist and both are legitimate, so the engine is looked for
	// in both rather than one being assumed. The engine is fetched as a tree
	// (`bundle/openvpn/`), and a deployment that preserves it installs the
	// engine beside the plugin inside an `openvpn\` subdirectory — but the
	// Flutter generated-plugin rule copies every bundled library flat, next
	// to the executable, and that is what `flutter build windows` produces.
	// Hard-coding the subdirectory meant the probe failed on every real
	// build: capabilities then reported this build WireGuard-only, the
	// server list refused every relay, and `startTunnel` rejected the
	// session before elevation was ever asked for — all while the engine
	// sat on disk a directory away. Prefer the subdirectory when it holds
	// the engine, fall back to the flat copy beside the plugin, and report
	// the subdirectory when neither has it so the missing-bundle message
	// names the documented layout; the callers' presence checks turn that
	// into "the engine is not installed" either way.
	const std::wstring nested = moduleDirectory + L"\\" + kOpenVpnBundleName;
	if (GetFileAttributesW((nested + L"\\" + kOpenVpnExecutableName).c_str()) !=
	    INVALID_FILE_ATTRIBUTES) {
		return nested;
	}
	if (GetFileAttributesW((moduleDirectory + L"\\" + kOpenVpnExecutableName).c_str()) !=
	    INVALID_FILE_ATTRIBUTES) {
		return moduleDirectory;
	}
	return nested;
}

std::wstring OpenVpnExecutable(const std::wstring& moduleDirectory) {
	const std::wstring directory = OpenVpnDirectory(moduleDirectory);
	if (directory.empty()) {
		return std::wstring();
	}
	return directory + L"\\" + kOpenVpnExecutableName;
}

std::wstring HelperExecutable(const std::wstring& moduleDirectory) {
	if (moduleDirectory.empty()) {
		return std::wstring();
	}
	return moduleDirectory + L"\\" + kHelperName;
}

bool OpenVpnBundlePresent(const std::wstring& moduleDirectory) {
	const std::wstring executable = OpenVpnExecutable(moduleDirectory);
	if (executable.empty()) {
		return false;
	}
	// The engine loads `wintun.dll` from its own directory when handed
	// `--windows-driver wintun`, so the driver is part of "present" and not a
	// separate question.
	const std::wstring directory = OpenVpnDirectory(moduleDirectory);
	const std::wstring wintun = directory + L"\\wintun.dll";
	return GetFileAttributesW(executable.c_str()) != INVALID_FILE_ATTRIBUTES &&
	       GetFileAttributesW(wintun.c_str()) != INVALID_FILE_ATTRIBUTES;
}

bool RestrictToUserAndSystem(const std::wstring& path, bool isDirectory) {
	// The SID of whoever runs this process. TOKEN_QUERY on the own process token
	// cannot fail under normal conditions, but every allocation below is still
	// checked, because an unchecked SID is how a DACL ends up granting access to
	// nobody — or to everybody.
	HANDLE processToken = nullptr;
	if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &processToken)) {
		return false;
	}
	DWORD userSidLength = 0;
	GetTokenInformation(processToken, TokenUser, nullptr, 0, &userSidLength);
	std::vector<BYTE> userSidBuffer(userSidLength);
	TOKEN_USER* tokenUser =
	    reinterpret_cast<TOKEN_USER*>(userSidBuffer.data());
	if (userSidLength == 0 ||
	    !GetTokenInformation(processToken, TokenUser, tokenUser, userSidLength,
	                         &userSidLength)) {
		CloseHandle(processToken);
		return false;
	}
	CloseHandle(processToken);
	PSID userSid = tokenUser->User.Sid;

	BYTE systemSidBuffer[SECURITY_MAX_SID_SIZE];
	DWORD systemSidLength = SECURITY_MAX_SID_SIZE;
	PSID systemSid = systemSidBuffer;
	if (!CreateWellKnownSid(WinLocalSystemSid, nullptr, systemSid,
	                        &systemSidLength)) {
		return false;
	}

	EXPLICIT_ACCESS_W entries[2] = {};
	entries[0].grfAccessPermissions = GENERIC_ALL;
	entries[0].grfAccessMode = GRANT_ACCESS;
	entries[0].grfInheritance =
	    isDirectory ? (SUB_CONTAINERS_AND_OBJECTS_INHERIT) : NO_INHERITANCE;
	entries[0].Trustee.pMultipleTrustee = nullptr;
	entries[0].Trustee.MultipleTrusteeOperation = NO_MULTIPLE_TRUSTEE;
	entries[0].Trustee.TrusteeForm = TRUSTEE_IS_SID;
	entries[0].Trustee.TrusteeType = TRUSTEE_IS_USER;
	entries[0].Trustee.ptstrName = reinterpret_cast<LPWSTR>(userSid);

	entries[1] = entries[0];
	entries[1].Trustee.TrusteeType = TRUSTEE_IS_WELL_KNOWN_GROUP;
	entries[1].Trustee.ptstrName = reinterpret_cast<LPWSTR>(systemSid);

	PACL acl = nullptr;
	if (SetEntriesInAclW(2, entries, nullptr, &acl) != ERROR_SUCCESS) {
		return false;
	}
	const DWORD status = SetNamedSecurityInfoW(
	    const_cast<LPWSTR>(path.c_str()), SE_FILE_OBJECT,
	    OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION |
	        PROTECTED_DACL_SECURITY_INFORMATION,
	    userSid, nullptr, acl, nullptr);
	LocalFree(acl);
	return status == ERROR_SUCCESS;
}

bool WriteRestrictedFile(const std::wstring& path, const std::string& contents) {
	if (path.empty() || contents.empty()) {
		return false;
	}
	HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr,
	                          CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
	if (file == INVALID_HANDLE_VALUE) {
		return false;
	}
	DWORD written = 0;
	const BOOL wrote = WriteFile(file, contents.data(),
	                             static_cast<DWORD>(contents.size()), &written,
	                             nullptr);
	CloseHandle(file);
	if (wrote == FALSE || written != contents.size()) {
		DeleteFileQuietly(path);
		return false;
	}
	// The file inherits the directory's restricted DACL on creation — but
	// `CREATE_ALWAYS` truncates an existing file *without replacing its ACL*,
	// so a profile left over from an earlier run, or one whose permissions were
	// changed externally, would keep them. The explicit restriction closes that
	// gap. When it cannot be applied the file is deleted rather than left with
	// unknown permissions.
	if (!RestrictToUserAndSystem(path, false)) {
		DeleteFileQuietly(path);
		return false;
	}
	return true;
}

// How many past sessions' engine logs are worth keeping for diagnosis.
constexpr size_t kKeptEngineLogs = 3;

void ArchiveEngineLog(const std::wstring& sessionLogPath) {
	if (sessionLogPath.empty()) {
		return;
	}
	const std::wstring app = AppDataDirectory();
	if (app.empty()) {
		return;
	}
	const std::wstring logsDirectory = app + L"\\logs";
	if (!CreateDirectoryW(logsDirectory.c_str(), nullptr) &&
	    GetLastError() != ERROR_ALREADY_EXISTS) {
		return;
	}

	HANDLE source = CreateFileW(sessionLogPath.c_str(), GENERIC_READ,
	                            FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
	                            OPEN_EXISTING, 0, nullptr);
	if (source == INVALID_HANDLE_VALUE) {
		return;
	}
	LARGE_INTEGER size = {0};
	if (GetFileSizeEx(source, &size) == FALSE || size.QuadPart <= 0) {
		CloseHandle(source);
		return;
	}
	// One session's log is a few kilobytes at the engine's default verbosity.
	// The cap only matters when something goes wrong inside the engine and it
	// repeats itself; the tail is where the cause lives, so the head is what
	// gets dropped.
	const int64_t kMaxLogBytes = 512 * 1024;
	const int64_t skip =
	    size.QuadPart > kMaxLogBytes ? size.QuadPart - kMaxLogBytes : 0;
	if (skip > 0 &&
	    SetFilePointerEx(source, *reinterpret_cast<const LARGE_INTEGER*>(&skip),
	                     nullptr, FILE_BEGIN) == FALSE) {
		CloseHandle(source);
		return;
	}
	const DWORD toRead = static_cast<DWORD>(
	    size.QuadPart > kMaxLogBytes ? kMaxLogBytes : size.QuadPart);
	std::string contents;
	if (skip > 0) {
		contents += "\n[older engine output trimmed]\n";
	}
	contents.resize(contents.size() + toRead);
	DWORD read = 0;
	const BOOL ok =
	    ReadFile(source, contents.data() + contents.size() - toRead, toRead,
	             &read, nullptr);
	CloseHandle(source);
	if (ok == FALSE || read == 0) {
		return;
	}
	if (skip > 0) {
		contents.resize(contents.size() - toRead + read);
	} else {
		contents.resize(read);
	}

	SYSTEMTIME now = {0};
	GetLocalTime(&now);
	wchar_t stamp[40] = {0};
	swprintf(stamp, 40, L"engine-%04u%02u%02u-%02u%02u%02u.log", now.wYear,
	         now.wMonth, now.wDay, now.wHour, now.wMinute, now.wSecond);
	if (!WriteRestrictedFile(logsDirectory + L"\\" + stamp, contents)) {
		return;
	}

	WIN32_FIND_DATAW found = {0};
	HANDLE scan = FindFirstFileW((logsDirectory + L"\\engine-*.log").c_str(),
	                             &found);
	if (scan == INVALID_HANDLE_VALUE) {
		return;
	}
	std::vector<std::wstring> names;
	do {
		names.push_back(found.cFileName);
	} while (FindNextFileW(scan, &found));
	FindClose(scan);
	std::sort(names.begin(), names.end());
	for (size_t index = 0; names.size() >= kKeptEngineLogs &&
	                       index < names.size() - kKeptEngineLogs;
	     ++index) {
		DeleteFileW((logsDirectory + L"\\" + names[index]).c_str());
	}
}

namespace {

// A directive this backend refuses to run for anybody.
//
// Each entry names a directive that can make an *elevated* `openvpn.exe` do
// something the caller chose: run a program, read or write a file, open a local
// socket, or ask for a credential this backend cannot supply. The list is
// named rejections give actionable errors. An allow-list below also rejects
// every option the normalised profile format does not need, including future
// engine options. A deny-list alone is not an elevation boundary.
struct ForbiddenDirective {
	const char* name;
	const char* code;
	const char* reason;
};

const ForbiddenDirective kForbiddenDirectives[] = {
    {"up", "ovpn.script_directive",
     "runs a program on the user's machine when the tunnel comes up"},
    {"down", "ovpn.script_directive",
     "runs a program when the tunnel goes down"},
    {"route-up", "ovpn.script_directive", "runs a program after routing is set"},
    {"route-pre-down", "ovpn.script_directive",
     "runs a program before routing is removed"},
    {"ipchange", "ovpn.script_directive",
     "runs a program when the tunnel address changes"},
    {"tls-verify", "ovpn.script_directive",
     "runs a program to verify the server certificate"},
    {"tls-crypt-v2-verify", "ovpn.script_directive",
     "runs a program to verify a server key"},
    {"client-connect", "ovpn.script_directive", "runs a program on connect"},
    {"client-disconnect", "ovpn.script_directive",
     "runs a program on disconnect"},
    {"client-crresponse", "ovpn.script_directive",
     "runs a program to answer a challenge"},
    {"auth-user-pass-verify", "ovpn.script_directive",
     "runs a program to check credentials"},
    {"learn-address", "ovpn.script_directive",
     "runs a program when an address is learned"},
    {"script-security", "ovpn.script_directive",
     "enables the directives above; it is granted to nobody"},
    {"plugin", "ovpn.script_directive", "loads code into the engine process"},
    {"config", "ovpn.unsupported_directive",
     "reads another file, so it can change what the engine is told"},
    {"management", "ovpn.unsupported_directive",
     "opens a local socket, and that socket can push configuration"},
    {"daemon", "ovpn.unsupported_directive",
     "detaches the engine, so the helper could no longer monitor it"},
    {"cd", "ovpn.unsupported_directive",
     "changes the engine's working directory, which is how it resolves files"},
    {"chroot", "ovpn.unsupported_directive",
     "changes the engine's root directory"},
    {"log", "ovpn.unsupported_directive",
     "redirects the engine's log somewhere this helper did not choose"},
    {"log-append", "ovpn.unsupported_directive",
     "appends to a file this helper did not choose"},
    {"status", "ovpn.unsupported_directive",
     "redirects the statistics file this helper reads"},
    {"status-version", "ovpn.unsupported_directive",
     "changes the format of the statistics file this helper reads"},
    {"dev-node", "ovpn.unsupported_directive",
     "names an adapter by path rather than letting the engine create one"},
    {"bind", "ovpn.unsupported_directive",
     "chooses a local address for an elevated process to bind"},
    {"lport", "ovpn.unsupported_directive",
     "chooses a local port for an elevated process to bind"},
    {"askpass", "ovpn.script_directive", "runs a program to read a password"},
    {"setenv", "ovpn.script_directive",
     "plants variables the directives above are constructed from"},
    {"setenv-safe", "ovpn.script_directive",
     "plants variables the directives above are constructed from"},
};

std::string LowercaseAscii(const std::string& value) {
	std::string out = value;
	for (char& c : out) {
		c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
	}
	return out;
}

// The first token of a configuration line, lowercased and without the leading
// dashes OpenVPN also accepts. Returns an empty string for a line that is blank
// or a comment, which is how such a line is skipped.
std::string DirectiveOf(const std::string& line) {
	size_t index = 0;
	while (index < line.size() &&
	       std::isspace(static_cast<unsigned char>(line[index])) != 0) {
		++index;
	}
	if (index >= line.size()) {
		return std::string();
	}
	const char first = line[index];
	if (first == '#' || first == ';') {
		return std::string();
	}
	size_t end = index;
	while (end < line.size() &&
	       std::isspace(static_cast<unsigned char>(line[end])) == 0) {
		++end;
	}
	std::string token = line.substr(index, end - index);
	while (!token.empty() && token.front() == '-') {
		token.erase(token.begin());
	}
	return LowercaseAscii(token);
}

// The remainder of a configuration line after its first token, trimmed.
std::string ArgumentsOf(const std::string& line) {
	size_t index = line.find_first_not_of(" \t");
	if (index == std::string::npos) {
		return std::string();
	}
	index = line.find_first_of(" \t", index);
	if (index == std::string::npos) {
		return std::string();
	}
	while (index < line.size() &&
	       std::isspace(static_cast<unsigned char>(line[index])) != 0) {
		++index;
	}
	std::string rest = line.substr(index);
	while (!rest.empty() &&
	       std::isspace(static_cast<unsigned char>(rest.back())) != 0) {
		rest.pop_back();
	}
	return rest;
}

// Strips a trailing comment and carriage return from a configuration line.
//
// `#` inside a value (a certificate, a URL) is legal, and this backend does not
// need to know about those: the directive list is matched on the first token
// only, so leaving a comment in place changes nothing except the token's
// argument text, which is only compared against emptiness.
std::string TrimLine(const std::string& line) {
	std::string out = line;
	while (!out.empty() && (out.back() == '\r' || out.back() == '\n')) {
		out.pop_back();
	}
	return out;
}

const char* kSecretMarkers[] = {
    "-----begin", "private key", "pem", "password", "secret", "token",
    "auth-user-pass", "askpass", "credential",
};

}  // namespace

bool RejectUnsafeDirectives(const std::string& profile,
                            ProfileRejection* out) {
	const auto reject = [out](const char* code, const char* reason) {
		if (out != nullptr) {
			*out = {code, reason};
		}
		return false;
	};
	if (profile.empty() || profile.size() > kMaxProfileBytes) {
		return reject("ovpn.profile_size", "exceeds the supported profile size");
	}
	if (profile.find('\0') != std::string::npos) {
		return reject("ovpn.profile_invalid", "contains an embedded null byte");
	}
	std::string inlineTag;
	bool client = false;
	bool tun = false;
	bool remote = false;
	bool serverCertificate = false;
	bool ca = false;
	size_t cursor = 0;
	while (cursor <= profile.size()) {
		const size_t newline = profile.find('\n', cursor);
		const std::string line = TrimLine(
		    newline == std::string::npos ? profile.substr(cursor)
	                                     : profile.substr(cursor, newline - cursor));
		if (newline == std::string::npos) {
			cursor = profile.size() + 1;
		} else {
			cursor = newline + 1;
		}
		const size_t first = line.find_first_not_of(" \t");
		const size_t last = line.find_last_not_of(" \t");
		const std::string trimmed = first == std::string::npos
		                                ? std::string()
		                                : line.substr(first, last - first + 1);
		if (trimmed.find('\r') != std::string::npos) {
			return reject("ovpn.profile_invalid", "contains a misplaced carriage return");
		}
		if (!inlineTag.empty()) {
			if (trimmed == "</" + inlineTag + ">") {
				inlineTag.clear();
			} else if (trimmed.find('<') != std::string::npos ||
			           trimmed.find('>') != std::string::npos) {
				return reject("ovpn.profile_invalid", "contains an invalid inline block");
			}
			continue;
		}
		if (!trimmed.empty() && trimmed.front() == '<') {
			for (const char* tag : {"ca", "cert", "key", "tls-auth", "tls-crypt",
			                        "tls-crypt-v2", "extra-certs"}) {
				if (trimmed == std::string("<") + tag + ">") {
					inlineTag = tag;
					ca = ca || inlineTag == "ca";
					break;
				}
			}
			if (inlineTag.empty()) {
				return reject("ovpn.profile_invalid", "contains an unsupported inline block");
			}
			continue;
		}
		const std::string directive = DirectiveOf(trimmed);
		if (directive.empty()) {
			continue;
		}
		for (const auto& forbidden : kForbiddenDirectives) {
			if (directive != forbidden.name) {
				continue;
			}
			if (out != nullptr) {
				out->code = forbidden.code;
				out->reason = forbidden.reason;
			}
			return false;
		}
		const std::string arguments = ArgumentsOf(trimmed);
		if (directive == "auth-user-pass") {
			return arguments.empty()
			           ? reject("ovpn.credentials_missing",
			                    "requires credentials this build cannot supply")
			           : reject("ovpn.unsupported_directive",
			                    "reads a credential file this helper did not choose");
		}
		// No backslash escapes/continuations or quoted directive aliases.
		// Values may be quoted (pull-filter and certificate names), but a
		// directive itself must be one of the serializer's literal names.
		if (trimmed.find('\\') != std::string::npos) {
			return reject("ovpn.profile_invalid", "contains unsupported escape syntax");
		}
		bool allowed = false;
		for (const char* option : {"remote", "proto", "auth", "data-ciphers",
		                          "data-ciphers-fallback", "tls-version-min",
		                          "tls-cert-profile", "verify-x509-name", "verb"}) {
			allowed = allowed || (directive == option && !arguments.empty());
		}
		for (const char* option : {"client", "nobind", "persist-key", "persist-tun",
		                          "block-ipv6"}) {
			allowed = allowed || (directive == option && arguments.empty());
		}
		allowed = allowed ||
		          (directive == "dev" && arguments == "tun") ||
		          (directive == "remote-cert-tls" && arguments == "server") ||
		          (directive == "key-direction" &&
		           (arguments == "0" || arguments == "1")) ||
		          (directive == "resolv-retry" && arguments == "infinite") ||
		          (directive == "pull-filter" &&
		           arguments == "ignore \"redirect-gateway\"") ||
		          (directive == "redirect-gateway" &&
		           arguments == "def1 bypass-dhcp");
		if (!allowed) {
			return reject("ovpn.unsupported_directive",
			              "contains an option outside the normalised profile format");
		}
		client = client || directive == "client";
		tun = tun || directive == "dev";
		remote = remote || directive == "remote";
		serverCertificate = serverCertificate || directive == "remote-cert-tls";
	}
	if (!inlineTag.empty() || !client || !tun || !remote || !ca ||
	    !serverCertificate) {
		return reject("ovpn.profile_invalid",
		              "omits required tunnel or server-authentication settings");
	}
	return true;
}

LockedSessionFiles::~LockedSessionFiles() { Close(); }

void LockedSessionFiles::Close() {
	for (auto it = handles_.rbegin(); it != handles_.rend(); ++it) {
		CloseHandle(*it);
	}
	handles_.clear();
}

bool LockedSessionFiles::Open(const std::wstring& session,
                              const std::wstring& profile,
                              const std::wstring& status,
                              const std::wstring& log,
                              ProfileRejection* rejection) {
	Close();
	const auto fail = [this, rejection](const char* code, const char* reason) {
		Close();
		if (rejection != nullptr) {
			*rejection = {code, reason};
		}
		return false;
	};
	if (session.find(L'\0') != std::wstring::npos ||
	    profile != session + L"\\phantrix.ovpn" ||
	    status != session + L"\\status.txt" || log != session + L"\\openvpn.log") {
		return fail("ovpn.paths_rejected", "uses unexpected session file locations");
	}
	// Lock the app directory, the OpenVPN root and the session, not merely
	// their names. OPEN_REPARSE_POINT prevents following a junction.
	std::wstring directory = session;
	std::vector<std::wstring> directories;
	for (int i = 0; i < 3; ++i) {
		const size_t slash = directory.find_last_of(L'\\');
		if (slash == std::wstring::npos || slash < 3) {
			return fail("ovpn.paths_rejected", "uses an invalid session directory");
		}
		directories.push_back(directory);
		directory.resize(slash);
	}
	for (auto it = directories.rbegin(); it != directories.rend(); ++it) {
		HANDLE handle = CreateFileW(
		    it->c_str(), FILE_READ_ATTRIBUTES, FILE_SHARE_READ, nullptr, OPEN_EXISTING,
		    FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
		if (handle == INVALID_HANDLE_VALUE) {
			return fail("ovpn.paths_rejected", "cannot lock its session directory");
		}
		handles_.push_back(handle);
		BY_HANDLE_FILE_INFORMATION info = {};
		if (!GetFileInformationByHandle(handle, &info) ||
		    (info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) == 0 ||
		    (info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
			return fail("ovpn.paths_rejected", "uses a linked session directory");
		}
	}
	for (const auto& path : {profile, status, log}) {
		const bool isProfile = path == profile;
		HANDLE handle = CreateFileW(
		    path.c_str(), isProfile ? GENERIC_READ : FILE_READ_ATTRIBUTES,
		    isProfile ? FILE_SHARE_READ : FILE_SHARE_READ | FILE_SHARE_WRITE,
		    nullptr, isProfile ? OPEN_EXISTING : OPEN_ALWAYS,
		    FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
		if (handle == INVALID_HANDLE_VALUE) {
			return fail("ovpn.paths_rejected", "cannot lock a session file");
		}
		handles_.push_back(handle);
		BY_HANDLE_FILE_INFORMATION info = {};
		if (!GetFileInformationByHandle(handle, &info) ||
		    (info.dwFileAttributes &
		     (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY)) != 0 ||
		    info.nNumberOfLinks != 1) {
			return fail("ovpn.paths_rejected", "uses a linked session file");
		}
		if (isProfile) {
			LARGE_INTEGER size = {};
			if (!GetFileSizeEx(handle, &size) || size.QuadPart <= 0 ||
			    size.QuadPart > static_cast<LONGLONG>(kMaxProfileBytes)) {
				return fail("ovpn.profile_size", "exceeds the supported profile size");
			}
			std::string contents(static_cast<size_t>(size.QuadPart), '\0');
			DWORD read = 0;
			if (!ReadFile(handle, contents.data(), static_cast<DWORD>(contents.size()),
			              &read, nullptr) || read != contents.size()) {
				return fail("ovpn.profile_missing", "cannot read the complete profile");
			}
			if (!RejectUnsafeDirectives(contents, rejection)) {
				Close();
				return false;
			}
		}
	}
	return true;
}

std::string RedactForReport(const std::string& line) {
	const std::string lowered = LowercaseAscii(line);
	for (const char* marker : kSecretMarkers) {
		if (lowered.find(marker) != std::string::npos) {
			return std::string("[redacted]");
		}
	}
	if (line.size() <= kMaxReportChars) {
		return line;
	}
	// Cut on a space rather than mid-word, and say that it was cut: a silently
	// truncated error message reads like the whole message.
	size_t cut = kMaxReportChars;
	while (cut > 0 && std::isspace(static_cast<unsigned char>(line[cut - 1]))) {
		--cut;
	}
	return line.substr(0, cut) + " [truncated]";
}

std::wstring MakePipeName() {
	return std::wstring(kPipePrefix) + RandomToken();
}

std::wstring PipeSecurityDescriptorString() {
	PSID userSid = nullptr;
	HANDLE token = nullptr;
	if (OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token) == FALSE) {
		return std::wstring();
	}
	DWORD length = 0;
	GetTokenInformation(token, TokenUser, nullptr, 0, &length);
	std::vector<BYTE> buffer(length);
	TOKEN_USER* user = reinterpret_cast<TOKEN_USER*>(buffer.data());
	if (length == 0 ||
	    GetTokenInformation(token, TokenUser, user, length, &length) == FALSE) {
		CloseHandle(token);
		return std::wstring();
	}
	CloseHandle(token);
	userSid = user->User.Sid;

	LPWSTR sidText = nullptr;
	if (ConvertSidToStringSidW(userSid, &sidText) == FALSE || sidText == nullptr) {
		return std::wstring();
	}
	std::wstring descriptor = L"D:P(A;;GA;;;SY)(A;;GA;;;";
	descriptor += sidText;
	descriptor += L")S:(ML;;NW;;;";
	descriptor += kMediumIntegritySid;
	descriptor += L")";
	LocalFree(sidText);
	return descriptor;
}

namespace {

constexpr uint32_t kMessageVersion = 1;
constexpr size_t kHeaderSize = 12;
constexpr uint32_t kMaxPayload = 64 * 1024;

bool WriteExact(HANDLE pipe, const void* data, size_t size) {
	const char* cursor = static_cast<const char*>(data);
	size_t remaining = size;
	OVERLAPPED overlap = {};
	overlap.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
	if (overlap.hEvent == nullptr) {
		return false;
	}
	bool ok = true;
	while (remaining > 0) {
		ResetEvent(overlap.hEvent);
		DWORD written = 0;
		if (!WriteFile(pipe, cursor, static_cast<DWORD>(remaining), &written,
		               &overlap)) {
			if (GetLastError() != ERROR_IO_PENDING) {
				ok = false;
				break;
			}
			if (WaitForSingleObject(overlap.hEvent, 10000) != WAIT_OBJECT_0) {
				CancelIoEx(pipe, &overlap);
				(void)GetOverlappedResult(pipe, &overlap, &written, TRUE);
				ok = false;
				break;
			}
			if (!GetOverlappedResult(pipe, &overlap, &written, FALSE)) {
				ok = false;
				break;
			}
		}
		if (written == 0) {
			ok = false;
			break;
		}
		cursor += written;
		remaining -= written;
	}
	CloseHandle(overlap.hEvent);
	return ok;
}

bool ReadExact(HANDLE pipe, void* data, size_t size) {
	char* cursor = static_cast<char*>(data);
	size_t remaining = size;
	while (remaining > 0) {
		DWORD read = 0;
		if (ReadFile(pipe, cursor, static_cast<DWORD>(remaining), &read,
		             nullptr) == FALSE) {
			return false;
		}
		if (read == 0) {
			return false;  // End of stream.
		}
		cursor += read;
		remaining -= read;
	}
	return true;
}

void AppendField(std::vector<uint8_t>* out, const std::string& field) {
	uint32_t length = static_cast<uint32_t>(field.size());
	const uint8_t* bytes = reinterpret_cast<const uint8_t*>(&length);
	out->insert(out->end(), bytes, bytes + sizeof(length));
	const uint8_t* text = reinterpret_cast<const uint8_t*>(field.data());
	out->insert(out->end(), text, text + field.size());
}

}  // namespace

Message MakeMessage(MessageType type, std::vector<std::string> fields) {
	Message message;
	message.type = type;
	message.fields = std::move(fields);
	return message;
}

// Extracts one complete framed message from the front of `carry`, and removes
// the bytes it consumed. Returns false when a whole message has not arrived yet.
//
// A byte-mode pipe does not preserve message boundaries, so a reader cannot
// assume one read is one message. It reads into a buffer, appends to `carry`,
// and calls this until it empties.
bool TakeMessage(std::vector<uint8_t>* carry, Message* message) {
	if (carry == nullptr || message == nullptr || carry->size() < kHeaderSize) {
		return false;
	}
	uint32_t magic = 0;
	memcpy(&magic, carry->data(), sizeof(magic));
	if (magic != kMessageMagic) {
		// Not one of ours, so nothing in this stream can be trusted. Clearing it
		// makes the caller's next attempt fail and the connection end.
		carry->clear();
		return false;
	}
	uint32_t payloadLength = 0;
	memcpy(&payloadLength, carry->data() + sizeof(magic) + 4, sizeof(payloadLength));
	uint16_t version = 0;
	uint16_t type = 0;
	memcpy(&version, carry->data() + 4, sizeof(version));
	memcpy(&type, carry->data() + 6, sizeof(type));
	if (version != kMessageVersion ||
	    type < static_cast<uint16_t>(MessageType::kStart) ||
	    type > static_cast<uint16_t>(MessageType::kHello) ||
	    payloadLength < sizeof(uint32_t) || payloadLength > kMaxPayload) {
		carry->clear();
		return false;
	}
	const size_t total = kHeaderSize + payloadLength;
	if (carry->size() < total) {
		return false;
	}

	Message parsed;
	parsed.type = static_cast<MessageType>(type);
	size_t cursor = kHeaderSize;
	const uint8_t* fields = carry->data() + cursor;
	const uint8_t* end = carry->data() + total;
	if (static_cast<size_t>(end - fields) >= sizeof(uint32_t)) {
		uint32_t fieldCount = 0;
		memcpy(&fieldCount, fields, sizeof(fieldCount));
		cursor += sizeof(uint32_t);
		fields += sizeof(uint32_t);
		for (uint32_t index = 0; index < fieldCount; ++index) {
			const size_t left = static_cast<size_t>(end - fields);
			if (left < sizeof(uint32_t)) {
				carry->clear();
				return false;
			}
			uint32_t length = 0;
			memcpy(&length, fields, sizeof(length));
			fields += sizeof(length);
			if (static_cast<size_t>(end - fields) < length) {
				carry->clear();
				return false;
			}
			parsed.fields.emplace_back(
			    reinterpret_cast<const char*>(fields), length);
			fields += length;
		}
	}
	if (fields != end) {
		carry->clear();
		return false;
	}
	carry->erase(carry->begin(), carry->begin() + total);
	*message = std::move(parsed);
	return true;
}

bool WriteMessage(HANDLE pipe, const Message& message) {
	if (pipe == nullptr || pipe == INVALID_HANDLE_VALUE) {
		return false;
	}
	// The payload is the whole frame body; its length travels in the header so a
	// reader never has to guess how much to read.
	std::vector<uint8_t> payload;
	uint32_t fieldCount = static_cast<uint32_t>(message.fields.size());
	const uint8_t* countBytes = reinterpret_cast<const uint8_t*>(&fieldCount);
	payload.insert(payload.end(), countBytes, countBytes + sizeof(fieldCount));
	for (const std::string& field : message.fields) {
		if (field.size() > kMaxPayload ||
		    payload.size() + sizeof(uint32_t) + field.size() > kMaxPayload) {
			return false;
		}
		AppendField(&payload, field);
	}

	uint8_t header[kHeaderSize] = {0};
	const uint16_t version = kMessageVersion;
	const uint16_t type = static_cast<uint16_t>(message.type);
	const uint32_t length = static_cast<uint32_t>(payload.size());
	memcpy(header + 0, &kMessageMagic, sizeof(kMessageMagic));
	memcpy(header + 4, &version, sizeof(version));
	memcpy(header + 6, &type, sizeof(type));
	memcpy(header + 8, &length, sizeof(length));

	if (!WriteExact(pipe, header, sizeof(header))) {
		return false;
	}
	return payload.empty() ? true : WriteExact(pipe, payload.data(), payload.size());
}

bool ReadMessage(HANDLE pipe, Message* message) {
	if (pipe == nullptr || pipe == INVALID_HANDLE_VALUE || message == nullptr) {
		return false;
	}
	// A blocking read, for a pipe nobody writes and reads on at once. The
	// plugin's and the helper's readers use a carry buffer and an overlapped
	// read instead: a pending blocking read on a handle holds that handle's file
	// lock, which would block a write from another thread on the same handle.
	std::vector<uint8_t> carry;
	uint8_t buffer[4096] = {0};
	for (;;) {
		DWORD read = 0;
		if (ReadFile(pipe, buffer, sizeof(buffer), &read, nullptr) == FALSE) {
			return false;
		}
		if (read == 0) {
			return false;  // End of stream.
		}
		carry.insert(carry.end(), buffer, buffer + read);
		if (TakeMessage(&carry, message)) {
			return true;
		}
		if (carry.empty()) {
			return false;  // A foreign frame: the stream is not readable.
		}
		if (carry.size() > kMaxPayload + kHeaderSize) {
			return false;
		}
	}
}
std::wstring Utf8ToWide(const std::string& value) {
	if (value.empty()) {
		return std::wstring();
	}
	// Six arguments: unlike `WideCharToMultiByte`, this API takes neither a
	// default character nor a used-default-character flag, and there is no
	// substitution for malformed UTF-8 to configure in the first place.
	const int needed =
	    MultiByteToWideChar(CP_UTF8, 0, value.c_str(), -1, nullptr, 0);
	if (needed <= 1) {
		return std::wstring();
	}
	std::wstring wide(static_cast<size_t>(needed), L'\0');
	MultiByteToWideChar(CP_UTF8, 0, value.c_str(), -1, wide.data(), needed);
	wide.resize(static_cast<size_t>(needed - 1));
	return wide;
}

std::string WideToUtf8(const std::wstring& value) {
	if (value.empty()) {
		return std::string();
	}
	const int needed = WideCharToMultiByte(CP_UTF8, 0, value.c_str(), -1, nullptr,
	                                       0, nullptr, nullptr);
	if (needed <= 1) {
		return std::string();
	}
	std::string narrow(static_cast<size_t>(needed), '\0');
	WideCharToMultiByte(CP_UTF8, 0, value.c_str(), -1, narrow.data(), needed,
	                    nullptr, nullptr);
	narrow.resize(static_cast<size_t>(needed - 1));
	return narrow;
}

std::wstring RandomToken() {
	// `std::random_device` rather than `rand_s`: Microsoft ships `rand_s` behind
	// `_CRT_RAND_S`, a macro nothing in this project defines, and reaching for
	// `CryptGenRandom` would add a dependency for something the standard library
	// already does. The device is the operating system's own randomness on
	// every toolchain this builds on.
	//
	// An empty result is a failure, not a fallback: the token appears in a pipe
	// name and in a file name, so a predictable one would be a weakness rather
	// than an inconvenience.
	std::random_device device;
	std::wstring token;
	token.reserve(32);
	for (int index = 0; index < 4; ++index) {
		const unsigned int value = device();
		if (value == 0 && index > 0) {
			// A zero in the middle is unlikely and harmless; a fully failed
			// generator is not, and is detected below by the emptiness of the
			// whole token.
		}
		wchar_t buffer[9] = {0};
		swprintf_s(buffer, 9, L"%08x", value);
		token += buffer;
	}
	if (token.size() != 32) {
		return std::wstring();
	}
	return token;
}

int64_t NowMillis() {
	FILETIME fileTime = {0};
	GetSystemTimeAsFileTime(&fileTime);
	ULARGE_INTEGER stamp = {0};
	stamp.LowPart = fileTime.dwLowDateTime;
	stamp.HighPart = fileTime.dwHighDateTime;
	// 100-nanosecond intervals since 1601-01-01. Unix epoch starts 11644473600
	// seconds later.
	const int64_t hundredsPerMilli = 10000;
	const int64_t unixOffset = 116444736000000000LL;
	return (static_cast<int64_t>(stamp.QuadPart) - unixOffset) / hundredsPerMilli;
}

}  // namespace ovpn
}  // namespace phantrix
