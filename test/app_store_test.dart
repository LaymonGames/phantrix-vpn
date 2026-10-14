import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:phantrix_core/phantrix_core.dart';

import 'package:phantrix/config/configuration_repository.dart';
import 'package:phantrix/settings/settings_persistence.dart';
import 'package:phantrix/storage/app_store.dart';

/// The persistence layer: atomicity, failure rollback, malformed data, and
/// the guarantees the file on disk actually carries.
///
/// ## What is tested here versus on a device
///
/// Everything here runs against a temporary directory or an in-memory store,
/// so it proves the Dart logic — atomic writes, rollback, parsing — but not
/// the operating system's enforcement. POSIX mode bits are asserted only
/// where POSIX exists; on Windows the ACL is set by the native backend and is
/// verified by inspecting a real directory (see the evidence report), not by
/// this file.
void main() {
	group('selected country preference', () {
		test('round-trips the selected country and defaults to automatic', () {
			final selected = AppSettings.defaults.copyWith(selectedCountryCode: 'HK');
			final decoded = SettingsCodec.decode(SettingsCodec.encode(selected));
			expect(decoded.selectedCountryCode, 'HK');
			expect(SettingsCodec.decode('{}').selectedCountryCode, 'AUTO');
		});

		test('normalizes known ISO3 country codes to the directory ISO2 form', () {
			final decoded = SettingsCodec.decode('{"selectedCountryCode":"HKG"}');
			expect(decoded.selectedCountryCode, 'HK');
		});

		test('rejects invalid saved country codes', () {
			final decoded = SettingsCodec.decode('{"selectedCountryCode":"not-a-country"}');
			expect(decoded.selectedCountryCode, 'AUTO');
		});

		test('clearing local data persists the automatic location', () async {
			final store = MemoryAppStore();
			final controller = PersistentSettingsController(
				AppSettings.defaults.copyWith(selectedCountryCode: 'HK'),
				store,
			);

			controller.clearLocalData();
			final stored = await store.read(SettingsCodec.storageKey);
			expect(SettingsCodec.decode(stored!).selectedCountryCode, 'AUTO');
		});
	});

	const valid = '''
[Interface]
PrivateKey = 02R31BtVMJe/5r8cMd8uRVf6DysDrWKFXxDlMdRDU6c=
Address = 10.8.0.2/32

[Peer]
PublicKey = iGaPncC709q7zIxUD9OMJENN3dh+W40oQx0Lv7AStp8=
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = 192.0.2.1:51820
''';

	group('FileAppStore', () {
		late Directory directory;

		setUp(() {
			directory = Directory.systemTemp.createTempSync('phantrix-store-test');
		});

		tearDown(() {
			if (directory.existsSync()) {
				directory.deleteSync(recursive: true);
			}
		});

		test('round-trips values through a real file', () async {
			final store = FileAppStore.inDirectory(directory.path, fileName: 's.json');
			await store.write('a', '1');
			await store.write('b', '2');
			expect(await store.read('a'), '1');
			expect(await store.read('b'), '2');
			expect(await store.keys(), {'a', 'b'});
			await store.delete('a');
			expect(await store.read('a'), isNull);
		});

		test('leaves no temporary sibling behind after a write', () async {
			final store = FileAppStore.inDirectory(directory.path, fileName: 's.json');
			await store.write('a', '1');
			final leftovers = directory
					.listSync()
					.where((e) => e.path.endsWith('.tmp'))
					.toList();
			expect(leftovers, isEmpty, reason: 'a .tmp left behind holds a copy of the key material');
		});

		test('a half-written file never replaces a good one', () async {
			// Simulated by writing a good file, then replacing the store with
			// a reader over a truncated copy: the point under test is that the
			// reader treats garbage as empty rather than throwing, so a crash
			// mid-write degrades to defaults instead of a launch failure.
			final store = FileAppStore.inDirectory(directory.path, fileName: 's.json');
			await store.write('configurations', '["x"]');
			final file = File('${directory.path}${Platform.pathSeparator}s.json');
			file.writeAsStringSync('{"configurations": "unterminated');
			final reread = FileAppStore.inDirectory(directory.path, fileName: 's.json');
			expect(await reread.read('configurations'), isNull);
		});

		test('concurrent writes serialise instead of interleaving', () async {
			final store = FileAppStore.inDirectory(directory.path, fileName: 's.json');
			await Future.wait([for (var i = 0; i < 20; i++) store.write('k$i', 'v$i')]);
			for (var i = 0; i < 20; i++) {
				expect(await store.read('k$i'), 'v$i');
			}
			// And the file parses as one JSON object, not two writes glued
			// together.
			final raw = File(
				'${directory.path}${Platform.pathSeparator}s.json',
			).readAsStringSync();
			expect(raw.trim().startsWith('{'), isTrue);
			expect(raw.trim().endsWith('}'), isTrue);
		});

		test(
			'the store file is owner-only on POSIX',
			() async {
				final store = FileAppStore.inDirectory(directory.path, fileName: 's.json');
				await store.write('configurations', '[]');
				final stat = File(
					'${directory.path}${Platform.pathSeparator}s.json',
				).statSync();
				// ignore: avoid_print
				final mode = stat.mode & 0xFFF;
				expect(
					mode & 0x077,
					0,
					reason: 'mode ${mode.toRadixString(8)} leaves group/other bits set',
				);
			},
			skip: Platform.isWindows || Platform.isAndroid
				? 'POSIX mode bits do not exist on this platform'
				: false,
		);

		test('openDefaultStore falls back to memory without a directory', () async {
			final store = await openDefaultStore(null);
			expect(store, isA<MemoryAppStore>());
			await store.write('a', '1');
			expect(await store.read('a'), '1');
		});
	});

	group('rollback on storage failure', () {
		test('a failed import leaves neither the entry nor a crash', () async {
			final repo = ConfigurationRepository(_FailingStore());
			final result = await repo.import(valid);
			expect(result, isA<Err<ImportedConfiguration>>());
			expect((result as Err<ImportedConfiguration>).error.code, 'store.write_failed');
			expect(repo.all, isEmpty);
		});

		test('a failed re-import restores the entry it displaced', () async {
			final backing = MemoryAppStore();
			final budgeted = _BudgetStore(backing, 1);
			final repo = ConfigurationRepository(budgeted);
			final first = await repo.import(valid, name: 'original');
			expect(first, isA<Ok<ImportedConfiguration>>());

			// The budget is spent: this re-import validates, displaces the
			// entry, then fails to persist. The rollback must put the
			// original back rather than losing it.
			final second = await repo.import(valid, name: 'replacement');
			expect(second, isA<Err<ImportedConfiguration>>());
			expect(repo.all, hasLength(1));
			expect(repo.all.first.name, 'original');
		});

		test('a failed removal keeps the entry in the list', () async {
			final backing = MemoryAppStore();
			final seeded = ConfigurationRepository(backing);
			final first = await seeded.import(valid);
			final id = (first as Ok<ImportedConfiguration>).value.id;
			expect(seeded.all, hasLength(1));

			// From here on the disk is frozen: writes fail, reads still work.
			final frozen = ConfigurationRepository(_FrozenStore(backing));
			await frozen.load();
			await frozen.remove(id);
			expect(
				frozen.all,
				hasLength(1),
				reason: 'the disk still has it, so the list must too',
			);
		});

		test('the failure message never contains configuration text', () async {
			final repo = ConfigurationRepository(_FailingStore());
			final result = await repo.import(valid);
			final message = (result as Err<ImportedConfiguration>).error.message;
			expect(message, isNot(contains('02R31BtVMJe')));
			expect(message, isNot(contains('PrivateKey')));
		});
	});
}

/// A store whose reads work and whose writes always fail.
///
/// Models a full disk, a revoked permission, or a path deleted out from under
/// the app — every way the real world says "no" to a write.
class _FailingStore implements AppStore {
	final _values = <String, String>{};

	@override
	Future<String?> read(String key) async => _values[key];

	@override
	Future<void> write(String key, String value) async {
		throw const FileSystemException('no space left on device');
	}

	@override
	Future<void> delete(String key) async {
		throw const FileSystemException('no space left on device');
	}

	@override
	Future<Set<String>> keys() async => _values.keys.toSet();
}

/// A store with a fixed write budget, then failure.
///
/// Models the exact rollback case: the first import succeeds and is on disk,
/// and the second change validates but cannot persist. Whatever the
/// repository does next must not lose the entry that is already stored.
class _BudgetStore implements AppStore {
	_BudgetStore(this._backing, this._budget);

	final AppStore _backing;
	int _budget;

	@override
	Future<String?> read(String key) => _backing.read(key);

	@override
	Future<void> write(String key, String value) async {
		if (_budget <= 0) {
			throw const FileSystemException('no space left on device');
		}
		_budget--;
		return _backing.write(key, value);
	}

	@override
	Future<void> delete(String key) async {
		if (_budget <= 0) {
			throw const FileSystemException('no space left on device');
		}
		_budget--;
		return _backing.delete(key);
	}

	@override
	Future<Set<String>> keys() => _backing.keys();
}

/// A store frozen at its current contents: reads pass through, writes fail.
///
/// Distinct from [_FailingStore], which starts empty: this one models the
/// rollback case, where the disk already holds an entry the list must keep
/// showing after a rejected change.
class _FrozenStore implements AppStore {
	_FrozenStore(this._backing);

	final AppStore _backing;

	@override
	Future<String?> read(String key) => _backing.read(key);

	@override
	Future<void> write(String key, String value) async {
		throw const FileSystemException('read-only file system');
	}

	@override
	Future<void> delete(String key) async {
		throw const FileSystemException('read-only file system');
	}

	@override
	Future<Set<String>> keys() => _backing.keys();
}
