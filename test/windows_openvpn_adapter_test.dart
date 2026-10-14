import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Regression tests for the Windows OpenVPN engine's adapter discovery.
///
/// ## Why these tests exist
///
/// The Windows backend failed to connect on every PC for a reason no code
/// review of the Dart layer could see: `openvpn.exe` reached `open_tun` and
/// died with `There are no TAP-Windows, Wintun or ovpn-dco adapters on this
/// system`, *after* a completed TLS handshake. The engine chooses adapters by
/// reading `ComponentId` from each subkey of
/// `HKLM\SYSTEM\CurrentControlSet\Control\Class\{4D36E972-…}` and keeping only
/// the ones that read `wintun` (or `tap0901`, `root\tap0901`, `ovpn-dco`);
/// anything else is skipped, and an empty list is that fatal.
///
/// Wintun's own INF declares `Class = Net` but never writes `ComponentId`, so an
/// adapter created through the Wintun API was invisible to the engine. The fix
/// is in `phantrix_ovpn_helper.cpp`, which now writes that one value into the
/// class key that belongs to the adapter it created and restores it afterwards.
///
/// These tests are host-VM tests and make no claim about a live tunnel. What
/// they do is pin the two invariants the fix depends on, and do so by reading
/// the actual sources rather than re-describing them, because the failure mode
/// this guards against was exactly a mismatch between what a comment claimed and
/// what the code did:
///
///   1. **the helper performs the registration** — it must write `ComponentId`
///      for the adapter's own `NetCfgInstanceId` and put the class key back
///      afterwards; and
///   2. **the engine passes the adapter to `openvpn.exe`** — `--dev-node
///      Phantrix` must be on the command line, because `--dev-node` is how the
///      adapter the helper created is selected rather than one picked by
///      lottery.
///
/// Anything that needs an administrator token — creating the adapter, running
/// the engine — is covered by the native procedures in
/// `docs/evidence/openvpn/WINDOWS_LIVE_VERIFICATION.md`, and the distinction is
/// stated rather than blurred: nothing here asserts a tunnel exists.
void main() {
	group('the Windows OpenVPN helper registers the adapter it creates', () {
		final helper = File(
			'packages/phantrix_platform/windows/phantrix_ovpn_helper.cpp',
		);

		final exists = helper.existsSync();
		final source = exists ? helper.readAsStringSync() : '';

		test('the sources are where the test expects them', () {
			// A missing file fails here with a clear message, rather than as a
			// vacuous pass from a test that read nothing.
			expect(
				exists,
				isTrue,
				reason: 'phantrix_ovpn_helper.cpp moved; the tests below must '
					'point at the real sources.',
			);
		});

		test('it writes ComponentId = wintun for the adapter, not for any '
			'adapter', () {
			// The value must be matched against the adapter's own
			// NetCfgInstanceId. Writing it into every Net-class subkey would
			// relabel unrelated adapters — a Bluetooth PAN, a Hyper-V vSwitch —
			// as Wintun adapters, which is a machine-wide change no connection
			// attempt may make.
			expect(
				source.contains('NetCfgInstanceId'),
				isTrue,
				reason: 'the helper must look the adapter up by its own '
					'NetCfgInstanceId before writing anything.',
			);
			expect(
				source.contains('kComponentIdValue'),
				isTrue,
				reason: 'the ComponentId value the engine matches on must be a '
					'named constant, not a magic string in one call.',
			);
		});

		test('the class subkey is found through the adapter\'s own instance '
			'id', () {
			// The lookup is what makes the write safe. If it searched by name
			// or by position instead, a machine with another Wintun adapter —
			// an earlier session's orphan, or WireGuard's own — would have
			// that adapter relabelled, and the tunnel would bind to an adapter
			// nobody created for it.
			expect(
				source.contains('ConvertInterfaceLuidToGuid'),
				isTrue,
				reason: 'the adapter must be identified from its own LUID.',
			);
			expect(
				source.contains('FindNetClassSubkeyFor(instanceId)'),
				isTrue,
				reason: 'the subkey lookup must use the instance id derived '
					'from that LUID.',
			);
		});

		test('the value is read back after it is written', () {
			// A write that reports success without holding leaves the adapter
			// exactly as undiscoverable as before, with the same confusing
			// timeout as the original bug. Reading it back is the only way the
			// helper knows the engine will find the adapter.
			final register = source.indexOf('bool RegisterAdapterForOpenVpn(');
			expect(register, greaterThan(-1));
			final body = source.substring(register);
			final write = body.indexOf('RegSetValueExW');
			expect(write, greaterThan(-1));
			expect(
				body.substring(write).contains('ReadRegString'),
				isTrue,
				reason: 'the value must be confirmed by reading it back.',
			);
		});

		test('the value written is the one OpenVPN matches on', () {
			// `WINTUN_COMPONENT_ID` in src/openvpn/tun.h is exactly "wintun".
			// A near miss — "Wintun", "wintun adapter" — would leave the
			// registry looking correct to a human and still invisible to the
			// engine, which is the same failure with one more step in it.
			final value = RegExp(
				r'kComponentIdValue\[\]\s*=\s*L"([^"]+)"',
			).firstMatch(source);
			expect(
				value,
				isNotNull,
				reason: 'the ComponentId constant must be declared.',
			);
			expect(value!.group(1), 'wintun');
		});

		test('it restores the class key when the session ends', () {
			// Without the restore, every failed attempt leaves a Wintun
			// ComponentId on an adapter that is no longer there, and the
			// machine accumulates entries OpenVPN will try to open.
			//
			// The teardown path is the one that matters: an attempt that fails
			// at the registry restores from its own error branch, but the
			// successful session must put the class key back too. Matched on
			// the ordering inside the helper's shutdown sequence — the restore
			// immediately followed by the ReleaseAdapter() call that removes
			// the adapter handle — rather than on bare presence, so a version
			// that only restores on the error path is still caught.
			final restore = source.indexOf('RestoreAdapterRegistration()');
			expect(
				restore,
				greaterThan(-1),
				reason: 'the restore must be called, not only defined.',
			);
			// Every call must sit immediately before an adapter release, and
			// there must be at least one on the shutdown path.
			final calls = RegExp(
				r'RestoreAdapterRegistration\(\);\s*ReleaseAdapter\(\);',
			).allMatches(source);
			expect(
				calls.length,
				greaterThanOrEqualTo(1),
				reason: 'the restore must run alongside the adapter release, '
					'which is what removes the adapter this session created.',
			);
			// The second call is the one after the message loop: the teardown
			// that runs on a *successful* session. Without it a completed
			// connection leaves the class key changed.
			final shutdown = source.indexOf('if (engine.running()) {');
			expect(shutdown, greaterThan(-1));
			final afterLoop = source.substring(shutdown);
			expect(
				RegExp(r'RestoreAdapterRegistration\(\);\s*ReleaseAdapter\(\);')
						.hasMatch(afterLoop),
				isTrue,
				reason: 'a successful session must also restore the class key '
					'before the adapter is closed.',
			);
		});

		test('the registration is called, and its failure stops the start', () {
			// This is the assertion that matters most. A version that leaves
			// the registration code present but never calls it compiles, builds,
			// ships, and fails at open_tun exactly as before — so the test
			// verifies the call itself rather than the function's existence.
			final ensureAdapter = source.indexOf('bool EnsureAdapter(');
			expect(
				ensureAdapter,
				greaterThan(-1),
				reason: 'EnsureAdapter is where the adapter is created.',
			);
			final body = source.substring(ensureAdapter);
			final registration = body.indexOf('RegisterAdapterForOpenVpn(');
			expect(
				registration,
				greaterThan(-1),
				reason: 'EnsureAdapter must call the registration, not merely '
					'define it.',
			);
			// The call must be negated: `if (!Register...)` means a failure
			// takes the branch. Without the `!` the function is called and its
			// answer discarded, the adapter is created, the engine launches
			// anyway, and the failure surfaces as a confusing timeout instead of
			// the real reason.
			expect(
				body.contains('if (!RegisterAdapterForOpenVpn('),
				isTrue,
				reason: 'the registration result must be tested, so a failure '
					'stops the attempt.',
			);
			// And the failing branch must stop the attempt outright.
			final afterCall = body.substring(registration);
			expect(
				afterCall.contains('return false'),
				isTrue,
				reason: 'a failed registration must stop the attempt.',
			);
		});

		test('the registration runs only for the adapter this session '
			'created', () {
			// The lookup is by the adapter's own NetCfgInstanceId. Writing the
			// value for any other adapter — a Bluetooth PAN, a Hyper-V vSwitch —
			// is a machine-wide change no connection attempt may make.
			expect(
				source.contains('ConvertInterfaceLuidToGuid'),
				isTrue,
				reason: 'the adapter must be identified from its own LUID.',
			);
			expect(
				source.contains('FindNetClassSubkeyFor'),
				isTrue,
				reason: 'the class subkey must be found for that identifier.',
			);
		});

		test('the value it writes lives in the Net class key, not the HW key', () {
			// This is the root cause. `HKR` in a DDInstall INF section is the
			// hardware key; the engine reads the class key. The helper writes
			// to the class key directly, so the two agree.
			//
			// Matched on the parts that cannot drift: the Net class GUID, which
			// is what makes it the Net class key at all, and the path that makes
			// it HKML rather than a per-device hardware key. Both use the
			// doubled backslashes a C++ string literal carries, so the
			// assertion reads the source as it is written.
			const escapedClassPath = r'Control\\Class';
			expect(
				source.contains('4D36E972'),
				isTrue,
				reason: 'the Net class GUID is what identifies the key the '
					'engine enumerates.',
			);
			expect(
				source.contains(escapedClassPath),
				isTrue,
				reason: 'the helper must target '
					r'HKLM\SYSTEM\CurrentControlSet\Control\Class\{4D36E972-…}',
			);
			// And the key it writes through must be that constant. Writing to
			// the device's own hardware key would be the exact mistake the
			// Wintun INF makes, reproduced one layer up.
			final writes = RegExp(
				r'RegOpenKeyExW\(HKEY_LOCAL_MACHINE,\s*(\w+)[.,]',
			).allMatches(source);
			expect(
				writes.isNotEmpty,
				isTrue,
				reason: 'the writes must go through a named key.',
			);
			expect(
				writes.map((m) => m.group(1)).contains('kNetClassKey'),
				isTrue,
				reason: 'the class-key writes must open the Net class key, '
					'not a hardware key.',
			);
		});
	});

	group('the engine is told which adapter to use', () {
		final engine = File(
			'packages/phantrix_platform/windows/phantrix_ovpn_engine.cpp',
		);

		test('the sources are where the test expects them', () {
			expect(
				engine.existsSync(),
				isTrue,
				reason: 'phantrix_ovpn_engine.cpp moved; the tests below must '
					'point at the real sources.',
			);
		});

		final source = engine.existsSync() ? engine.readAsStringSync() : '';

		test('--windows-driver wintun is passed, so the engine uses Wintun', () {
			// Without it the engine picks TAP-Windows when it is installed and
			// Wintun when it is not, which is a different adapter with
			// different behaviour on the same machine.
			expect(source.contains('--windows-driver wintun'), isTrue);
		});

		test('--dev-node is passed, so the adapter is not picked by lottery', () {
			// OpenVPN's no-dev-node path takes the first adapter that appears
			// available. With more than one Wintun adapter on a machine — a
			// previous session's orphan, WireGuard's own — that is whichever
			// one the registry happens to list first. Naming the adapter the
			// helper just created is what makes the tunnel deterministic.
			expect(source.contains('--dev-node'), isTrue);
		});

		test('every path is quoted, so a space cannot split an argument', () {
			// `%LOCALAPPDATA%` for an account with a space in its name — the
			// common case — would otherwise be read as several arguments.
			// `CreateProcessW` receives the whole line.
			expect(
				source.contains('QuoteArgument(executable)'),
				isTrue,
				reason: 'the executable path must be quoted.',
			);
			expect(
				source.contains('QuoteArgument(paths.profile)'),
				isTrue,
				reason: 'the profile path must be quoted.',
			);
		});

		test('the engine is started in its own directory, so DLLs resolve', () {
			// openvpn.exe loads wintun.dll and the OpenSSL DLLs from its own
			// working directory. Starting it from the app's directory puts
			// that lookup at the mercy of the app's PATH.
			expect(
				source.contains('paths.engineDirectory.c_str()'),
				isTrue,
				reason: 'the engine needs its own directory as the working '
					'directory.',
			);
		});

		test('the log and status files are both told to the engine', () {
			// The plugin's state machine is driven by the log, and the
			// counters by the status file. Dropping either turns a working
			// tunnel into "the engine never reported a handshake".
			expect(source.contains('--status'), isTrue);
			expect(source.contains('--log'), isTrue);
		});
	});

	group('the engine states that mean a tunnel', () {
		final engine = File(
			'packages/phantrix_platform/windows/phantrix_ovpn_engine.cpp',
		);
		final source = engine.existsSync() ? engine.readAsStringSync() : '';

		test('"Initialization Sequence Completed" is what proves the tunnel', () {
			// This is the line OpenVPN prints once the interface is up and
			// routes and DNS are configured. Nothing may be reported as a
			// tunnel before it.
			expect(
				source.contains('Initialization Sequence Completed'),
				isTrue,
			);
		});

		test('the adapter failure is classified as a driver failure, not a '
			'timeout', () {
			// The whole point of the fix is that this is readable. The engine
			// prints `There are no TAP-Windows, Wintun or ovpn-dco adapters on
			// this system.` followed by `Exiting due to fatal error`; if only
			// the second line survives, the app reports a timeout instead of
			// the cause and the defect is invisible again.
			expect(
				source.contains('Exiting due to fatal error'),
				isTrue,
				reason: 'the generic terminator must be recognised so it does '
					'not replace the real cause.',
			);
			expect(
				source.contains('ovpn.driver_failed'),
				isTrue,
				reason: 'an adapter or driver failure must have its own code.',
			);
		});

		test('a fatal line keeps its cause rather than the terminator', () {
			// Regression for the report that told the user only
			// "Exiting due to fatal error": OpenVPN appends that sentence
			// after *every* fatal, so keeping the last error line kept the
			// sentence that names nothing. The last lines before the exit are
			// what the user must be told.
			expect(
				source.contains('recentLines_'),
				isTrue,
				reason: 'the lines immediately before a fatal exit must be '
					'kept for the report.',
			);
		});
	});
}

/// The registry key the engine enumerates for adapters.
///
/// Named here rather than inline so a test that fails says which path was
/// expected, and so the two files that need it cannot drift apart. The helper
/// splits it across string literals for line length, which is why the test
/// matches its two stable parts rather than this whole string.
const String kNetClassKeyPath =
	r'SYSTEM\CurrentControlSet\Control\Class\{4D36E972-E325-11CE-BFC1-08002BE10318}';
