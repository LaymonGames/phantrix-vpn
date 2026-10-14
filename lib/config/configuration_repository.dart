import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:phantrix_core/phantrix_core.dart';

import '../storage/app_store.dart';

/// A VPN configuration the user imported.
///
/// This is what makes Phantrix usable. The only discovery source this build
/// ships with is VPN Gate, which publishes **OpenVPN** servers, and every
/// native backend here drives **WireGuard**. Without a way to supply a
/// WireGuard configuration there is nothing the app could ever connect to, so
/// importing one is not a convenience feature — it is the difference between a
/// VPN client and a UI that can only ever fail.
///
/// ## What is stored
///
/// The full wg-quick(5) text, verbatim, plus metadata derived from it. The
/// text is kept rather than a re-serialised form because re-serialising would
/// risk a round trip that differs from what the user gave us, and the text is
/// what the user can check against what their provider gave them.
class ImportedConfiguration {
	ImportedConfiguration({
		required this.id,
		required this.name,
		required this.wgQuickText,
		required this.importedAt,
		required this.endpointCount,
		required this.usesIpv6,
	});

	/// A stable identifier derived from the configuration's public keys.
	///
	/// Deriving it rather than generating a random one means importing the same
	/// configuration twice updates the existing entry instead of creating a
	/// duplicate the user then has to delete.
	final String id;

	/// What the user called it. Defaults to the endpoint host.
	final String name;

	/// The configuration exactly as supplied, including its private key.
	final String wgQuickText;

	final DateTime importedAt;

	/// How many peers the configuration declares.
	final int endpointCount;

	/// Whether the configuration carries an IPv6 address or an IPv6 route.
	final bool usesIpv6;

	/// The configuration parsed and checked, or an error explaining why not.
	///
	/// This is computed on demand rather than cached because a cached parse
	/// would have to be invalidated when the parser changes, and a stale
	/// verdict is worse than a repeated parse.
	Result<VpnConfiguration> build() => ImportedConfiguration.parse(wgQuickText);

	/// The largest import that is even attempted.
	///
	/// A real wg-quick file is around a kilobyte; ten peers are still under
	/// four. 64 KiB is generous to the point of absurdity, and anything past
	/// it is either a mistake — a log file pasted into the wrong box — or an
	/// attempt to make the app hold an unreasonable amount of text in memory,
	/// JSON-encode it, and write it to disk on every change. Refusing early
	/// keeps a paste from becoming a denial of service against the store.
	static const int maxImportBytes = 64 * 1024;

	/// The longest name that is kept.
	///
	/// Names are labels, not key material: truncating one loses nothing the
	/// tunnel needs, while an unbounded name would let a paste of megabytes
	/// live in the store and in every list row that renders it.
	static const int maxNameLength = 120;

	/// Parses and validates wg-quick text into a checked configuration.
	///
	/// Exposed as a static so the import screen and the connect path cannot
	/// disagree about what counts as a usable configuration.
	static Result<VpnConfiguration> parse(String text) {
		final trimmed = text.trim();
		if (trimmed.isEmpty) {
			return const Err(
				AppError(
					group: ErrorGroup.configuration,
					code: 'import.empty',
					message:
						'There is nothing to import. Paste the configuration '
						'text your provider gave you.',
				),
			);
		}
		// Measured in bytes, not characters: the cost that matters is memory
		// and disk, and a character is not a fixed number of bytes. Counted
		// by hand rather than via `utf8.encode`, which would allocate a
		// second copy of a hostile input just to measure it.
		if (_utf8Length(trimmed) > maxImportBytes) {
			return const Err(
				AppError(
					group: ErrorGroup.configuration,
					code: 'import.too_large',
					message:
						'That text is far larger than any VPN configuration. '
						'Paste only the configuration file your provider gave you.',
				),
			);
		}

		final parsed = WgParser.parse(trimmed);
		if (parsed case Err(:final error)) {
			return Err(error);
		}
		final config = (parsed as Ok<WgConfig>).value;

		// The validator is what refuses a configuration that would leak, run a
		// command, or point nowhere. It is not optional here: an unchecked
		// configuration must never reach the platform.
		final verdict = WgValidator.validate(config);
		if (verdict case Err(:final error)) {
			return Err(error);
		}
		return Ok(VpnConfiguration.wireGuard((verdict as Ok<WgVerdict>).value));
	}

	static int _utf8Length(String text) {
		var length = 0;
		for (var i = 0; i < text.length; i++) {
			final unit = text.codeUnitAt(i);
			if (unit < 0x80) {
				length += 1;
			} else if (unit < 0x800) {
				length += 2;
			} else if (unit >= 0xD800 && unit <= 0xDBFF && i + 1 < text.length) {
				final next = text.codeUnitAt(i + 1);
				if (next >= 0xDC00 && next <= 0xDFFF) {
					length += 4;
					i++;
				} else {
					length += 3;
				}
			} else {
				length += 3;
			}
		}
		return length;
	}

	/// Builds one from wg-quick text, or an error explaining why it cannot.
	static Result<ImportedConfiguration> fromText({
		required String text,
		String? name,
		DateTime? importedAt,
	}) {
		final validated = parse(text);
		if (validated case Err(:final error)) {
			return Err(error);
		}
		final config = (validated as Ok<VpnConfiguration>).value;
		final wireGuard = config.wireGuard;
		final peers = wireGuard?.peers ?? const [];
		final hosts = <String>{};
		for (final peer in peers) {
			final host = peer.endpoint?.host;
			if (host != null && host.isNotEmpty) {
				hosts.add(host);
			}
		}
		final derivedName =
				name?.trim().isNotEmpty == true
				? _truncateName(name!.trim())
				: (hosts.isEmpty ? 'Imported configuration' : hosts.first);

		return Ok(
			ImportedConfiguration(
				id: fingerprintOf(config),
				name: derivedName,
				wgQuickText: text.trim(),
				importedAt: importedAt ?? DateTime.now(),
				endpointCount: peers.length,
				usesIpv6:
					(wireGuard?.interface.addresses.any((a) => a.toString().contains(':')) ??
						false) ||
					peers.any(
						(p) => p.allowedIps.any((ip) => ip.toString().contains(':')),
					),
			),
		);
	}

	/// Shortens a user-supplied name to [maxNameLength].
	///
	/// Cut on a character boundary, never in the middle of a surrogate pair:
	/// a lone surrogate in a stored name would render as U+FFFD everywhere it
	/// appears and could break a JSON round trip on a strict decoder.
	static String _truncateName(String name) {
		if (name.length <= maxNameLength) {
			return name;
		}
		var end = maxNameLength;
		if (end > 0 &&
			name.codeUnitAt(end - 1) >= 0xD800 &&
			name.codeUnitAt(end - 1) <= 0xDBFF &&
			end < name.length &&
			name.codeUnitAt(end) >= 0xDC00 &&
			name.codeUnitAt(end) <= 0xDFFF) {
			end--;
		}
		return name.substring(0, end).trimRight();
	}

	/// A stable id for [config], derived from the peer public keys.
	///
	/// Only public keys are used. A fingerprint that included the private key
	/// would let two configurations be told apart, but it would also mean a
	/// secret influences an identifier that ends up in a filename and in the
	/// UI — and the public keys already identify the server uniquely.
	static String fingerprintOf(VpnConfiguration config) {
		final wireGuard = config.wireGuard;
		if (wireGuard == null || wireGuard.peers.isEmpty) {
			return 'config-${Redactor.fingerprint(config.kind.name)}';
		}
		final material = wireGuard.peers.map((p) => p.publicKey).join('|');
		return 'wg-${Redactor.fingerprint(material)}';
	}

	/// The stored form.
	///
	/// The private key is part of the text and therefore part of this map.
	/// That is deliberate and is why [AppStore] keeps the file owner-only: a
	/// configuration is only useful with its key, and splitting the two would
	/// mean storing them somewhere less protected than together.
	Map<String, Object?> toJson() => {
		'id': id,
		'name': name,
		'text': wgQuickText,
		'importedAt': importedAt.toUtc().toIso8601String(),
		'endpointCount': endpointCount,
		'usesIpv6': usesIpv6,
	};

	/// Rebuilds a stored configuration, or null when the record is unusable.
	///
	/// A record that no longer parses — because the parser got stricter, or the
	/// file was edited — is skipped rather than crashing the list. Losing one
	/// configuration is recoverable; an app that cannot start is not.
	static ImportedConfiguration? tryFromJson(Object? value) {
		if (value is! Map) {
			return null;
		}
		final text = value['text'];
		if (text is! String || text.trim().isEmpty) {
			return null;
		}
		final importedAt =
			DateTime.tryParse(value['importedAt']?.toString() ?? '')?.toLocal() ??
			DateTime.now();
		final rebuilt = fromText(text: text, name: value['name']?.toString(), importedAt: importedAt);
		if (rebuilt case Err(:final error)) {
			debugPrint('Phantrix: a stored configuration was skipped: ${error.code}');
			return null;
		}
		return (rebuilt as Ok<ImportedConfiguration>).value;
	}
}

/// The user's imported configurations, persisted.
///
/// ## Why this is not in `phantrix_core`
///
/// It stores things on a device, so it depends on a store and on the
/// platform. The core package stays pure Dart with no I/O, which is the rule
/// that keeps it testable without a device.
class ConfigurationRepository extends ChangeNotifier {
	ConfigurationRepository(this._store);

	/// The key the list is kept under in the store.
	static const String storageKey = 'configurations';

	/// The most configurations the store will hold.
	///
	/// Each one is a few kilobytes, so this is not about disk space. It is
	/// about the list staying something a person can manage: past a few dozen
	/// entries nobody can tell them apart, and every one of them is
	/// re-validated and re-rendered whenever the list is shown. Refusing with
	/// a reason beats silently evicting the oldest entry, which would be data
	/// loss wearing the mask of housekeeping.
	static const int maxStoredConfigurations = 64;

	final AppStore _store;
	final List<ImportedConfiguration> _configs = [];
	bool _loaded = false;

	/// The imported configurations, in most-recent-first order.
	List<ImportedConfiguration> get all => List.unmodifiable(_configs);

	/// Reads the stored configurations.
	///
	/// Safe to call more than once; the second call is a no-op. Callers do not
	/// have to remember whether they already loaded, which is what stops two
	/// screens racing to load and one overwriting the other's result.
	Future<void> load() async {
		if (_loaded) {
			return;
		}
		_loaded = true;
		final raw = await _store.read(storageKey);
		if (raw == null || raw.isEmpty) {
			return;
		}
		List<Object?> decoded;
		try {
			final value = jsonDecode(raw);
			decoded = value is List ? value : const [];
		} on FormatException {
			// A corrupt store must not stop the app launching.
			return;
		}
		final parsed = <ImportedConfiguration>[];
		for (final entry in decoded) {
			final configuration = ImportedConfiguration.tryFromJson(entry);
			if (configuration != null) {
				parsed.add(configuration);
			}
		}
		parsed.sort((a, b) => b.importedAt.compareTo(a.importedAt));
		_configs
			..clear()
			..addAll(parsed);
		notifyListeners();
	}

	/// Imports [text], replacing any existing entry with the same peer keys.
	///
	/// Returns the stored configuration or the error that stopped it. The text
	/// is validated before it is written, so a configuration that would leak or
	/// that cannot be connected is never persisted.
	///
	/// All-or-nothing: when the disk write fails, the in-memory entry is
	/// rolled back and the caller gets an error instead of a configuration the
	/// next launch will not have. A caller that cannot distinguish "imported"
	/// from "imported for this session only" will show one and mean the other.
	Future<Result<ImportedConfiguration>> import(String text, {String? name}) async {
		await load();
		final built = ImportedConfiguration.fromText(text: text, name: name);
		if (built case Err(:final error)) {
			return Err(error);
		}
		final configuration = (built as Ok<ImportedConfiguration>).value;

		final previous = byId(configuration.id);
		_configs.removeWhere((existing) => existing.id == configuration.id);
		if (_configs.length >= maxStoredConfigurations) {
			// The displaced entry is put back: the refusal must not cost the
			// user a configuration they already had.
			if (previous != null) {
				_configs.insert(0, previous);
			}
			return Err(
				AppError(
					group: ErrorGroup.configuration,
					code: 'import.too_many',
					message:
						'There are already $maxStoredConfigurations stored '
						'configurations. Remove one before importing another.',
				),
			);
		}
		_configs.insert(0, configuration);
		notifyListeners();
		final failure = await _persistOrNull();
		if (failure != null) {
			// Roll back: the list on screen must never disagree with the disk
			// about what exists.
			_configs.removeWhere((existing) => existing.id == configuration.id);
			if (previous != null) {
				_configs.insert(0, previous);
			}
			notifyListeners();
			return Err(failure);
		}
		return Ok(configuration);
	}

	/// Removes the configuration with [id].
	Future<void> remove(String id) async {
		await load();
		final index = _configs.indexWhere((configuration) => configuration.id == id);
		if (index < 0) {
			return;
		}
		final previous = _configs.removeAt(index);
		notifyListeners();
		if (await _persistOrNull() != null && byId(id) == null) {
			// The disk still has it, so the list must too. A removal the
			// store rejected would otherwise resurrect the entry on next
			// launch with no explanation. Restored at its position, not at
			// the top: the list is most-recent-first and this entry is not
			// the most recent.
			_configs.insert(index.clamp(0, _configs.length), previous);
			notifyListeners();
		}
	}

	/// The configuration with [id], or null.
	ImportedConfiguration? byId(String id) {
		for (final configuration in _configs) {
			if (configuration.id == id) {
				return configuration;
			}
		}
		return null;
	}

	/// Forgets every imported configuration.
	Future<void> clear() async {
		await load();
		final previous = List<ImportedConfiguration>.of(_configs);
		_configs.clear();
		notifyListeners();
		if (await _persistOrNull() != null) {
			_configs.addAll(previous);
			notifyListeners();
		}
	}

	/// Writes the list, returning the error when the write fails.
	///
	/// A failed write leaves the previous file intact — the store writes to a
	/// temporary sibling and renames — so every caller above can roll its own
	/// in-memory change back and end up agreeing with the disk again. What no
	/// caller may do is throw: the import sheet awaits these methods with no
	/// try/catch, and a disk-full exception must arrive as an error the UI can
	/// show, not as a crash.
	Future<AppError?> _persistOrNull() async {
		try {
			await _persist();
			return null;
		} on Object {
			// The failure itself carries no secret — it is a filesystem error
			// about the store file, never about the configurations inside it —
			// but it is still reported in the app's own vocabulary rather than
			// leaking a platform exception type to the UI.
			return const AppError(
				group: ErrorGroup.storage,
				code: 'store.write_failed',
				message:
					'The change could not be saved on this device, so it was '
					'not applied. Check that storage is available and try again.',
			);
		}
	}

	Future<void> _persist() async {
		await _store.write(
			storageKey,
			jsonEncode(_configs.map((c) => c.toJson()).toList()),
		);
	}
}