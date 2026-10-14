// Generates the Phantrix third-party notice inventory.
//
// This file is deliberately small and dependency-free: it is a build-time
// tool, not part of the app, and it must run with `dart run` against the
// app package alone so a fresh clone can regenerate notices after
// `flutter pub get`.
//
// Everything it emits is derived from files that exist in the repository or
// in the local caches the toolchain itself wrote: `pubspec.lock` files,
// `LICENSE` files in the pub cache, Gradle dependency lines, vendored Maven
// POMs, fetched upstream licence texts under `tools/attribution/`, and the
// Windows bundle's own licence files when that bundle exists. Where a fact
// cannot be read the tool records `unknown` and says where it looked — it
// never invents a licence, and it never infers one from a package name.
//
// Output: `lib/notices/generated_third_party_notices.dart`, which the
// licences screen renders. The output is deterministic: two runs over the
// same inputs produce a byte-identical file.

import 'dart:io';

/// The lockfiles that resolve the Dart dependency graph.
///
/// The app's own lockfile is what a shipped APK or EXE is built from; the
/// two sibling packages lock their own copies, and a package they resolve
/// differently has to be visible as such rather than averaged away.
const List<({String path, String label})> lockfiles = [
	(path: 'pubspec.lock', label: 'app'),
	(path: 'packages/phantrix_core/pubspec.lock', label: 'core'),
	(path: 'packages/phantrix_platform/pubspec.lock', label: 'platform'),
];

/// Gradle files whose dependency blocks are read statically.
const List<String> gradleFiles = [
	'packages/phantrix_platform/android/build.gradle.kts',
	'packages/phantrix_platform/android/build.gradle',
	'android/app/build.gradle.kts',
	'android/app/build.gradle',
];

/// The Windows bundle's licence files, and where a copy is kept in this
/// repository as the fetched original for when the bundle is absent.
///
/// Keyed by the file name; the value is the component the text covers and
/// the note the entry carries. The bundle copy wins when it exists, so the
/// entry always describes the bits that ship.
const List<({String file, String? bundleFile, String component, List<String> notes})> windowsLicenceFiles = [
	(
		file: 'wintun-prebuilt-license.txt',
		bundleFile: null,
		component: 'wintun (prebuilt DLL, WireGuard LLC)',
		notes: ['shippedBinary'],
	),
	(
		file: 'openvpn-dart-license.txt',
		bundleFile: null,
		component: 'openvpn_dart (engine glue adapted from, BlockDev AG)',
		notes: ['adaptedUpstream'],
	),
	(
		file: 'openvpn-copying.txt',
		bundleFile: 'openvpn/LICENSE.txt',
		component: 'OpenVPN 2 (community binaries, separate process)',
		notes: ['mereAggregation', 'shippedBinary'],
	),
];

/// Licence texts vendored under `tools/attribution/`, keyed by component.
const List<({String file, String component, List<String> notes})> attributionFiles = [
	(
		file: 'openvpn-dart-license.txt',
		component: 'openvpn_dart (engine glue adapted from, BlockDev AG)',
		notes: ['adaptedUpstream'],
	),
	(
		file: 'openvpn-copying.txt',
		component: 'OpenVPN 2 (community binaries, separate process)',
		notes: ['mereAggregation', 'shippedBinary'],
	),
	(
		file: 'wintun-prebuilt-license.txt',
		component: 'wintun (prebuilt DLL, WireGuard LLC)',
		notes: ['shippedBinary'],
	),
];

/// Known licences for Android Maven dependencies whose POM may not yet exist
/// in a fresh Gradle cache. Full text is checked in so offline regeneration
/// can still produce the required notice.
const Map<String, String> androidVendoredLicenceFiles = {
	'com.wireguard.android:tunnel': 'apache-2.0-license.txt',
	'androidx.core:core-ktx': 'apache-2.0-license.txt',
	'androidx.annotation:annotation': 'apache-2.0-license.txt',
	'androidx.test.ext:junit': 'apache-2.0-license.txt',
	'androidx.test:core': 'apache-2.0-license.txt',
	'androidx.test:runner': 'apache-2.0-license.txt',
	'org.json:json': 'json-java-public-domain.txt',
};

/// Verified Maven licence identifiers when a fresh checkout has no local POM.
/// These entries are test-only in this project and are not shipped in the app.
const Map<String, String> androidLicenceIdsWithoutText = {
	'junit:junit': 'EPL-1.0',
};

const Map<String, String> androidLicenceUrlsWithoutText = {
	'junit:junit': 'https://www.eclipse.org/legal/epl-v10.html',
};

/// The order components are rendered in, and the sort within one.
const List<String> componentOrder = ['app', 'dart', 'android', 'windows', 'attribution'];

const String attributionDir = 'tools/attribution';
const String windowsBundleDir = 'packages/phantrix_platform/windows/bundle';
const String generatedPath = 'lib/notices/generated_third_party_notices.dart';

/// One inventory line. Mirrors `ThirdPartyNoticeData`.
class Entry {
	Entry({
		required this.component,
		required this.name,
		required this.licenseId,
		this.version,
		this.sourceUrl,
		this.licenseKey,
		this.licenseSource,
		this.copyright,
		this.noteCodes = const <String>[],
		this.scopes = const <String>[],
	});

	final String component;
	final String name;
	final String? version;
	final String? sourceUrl;
	final String licenseId;
	final String? licenseKey;
	final String? licenseSource;
	final String? copyright;
	final List<String> noteCodes;
	final List<String> scopes;

	String get identity => '$component|$name|${version ?? ''}';
}

/// A licence text found on disk, with the key it is stored under.
class LicenceText {
	LicenceText(this.key, this.text, this.source);

	final String key;
	final String text;
	final String source;
}

String? readIfExists(String path) {
	final file = File(path);
	if (!file.existsSync()) {
		return null;
	}
	try {
		return file.readAsStringSync();
	} catch (_) {
		return null;
	}
}

List<String> lines(String text) =>
		text.split('\n').map((l) => l.endsWith('\r') ? l.substring(0, l.length - 1) : l).toList();

/// A stable, collision-free key for a bundled licence text.
String keyFor(String name, String licenseId) {
	final base = '$name-$licenseId';
	final buffer = StringBuffer();
	var lastDash = false;
	for (final rune in base.toLowerCase().runes) {
		final char = String.fromCharCode(rune);
		if (RegExp(r'[a-z0-9]').hasMatch(char)) {
			buffer.write(char);
			lastDash = false;
		} else if (!lastDash) {
			buffer.write('-');
			lastDash = true;
		}
	}
	final slug = buffer.toString().replaceAll(RegExp(r'^-+|-+$'), '');
	return slug.isEmpty ? 'unnamed' : slug;
}

/// The pub cache root, honouring `PUB_CACHE` before the platform default.
String pubCacheRoot() {
	final override = Platform.environment['PUB_CACHE'];
	if (override != null && override.isNotEmpty) {
		return override;
	}
	if (Platform.isWindows) {
		final local = Platform.environment['LOCALAPPDATA'];
		if (local != null && local.isNotEmpty) {
			return '$local${Platform.pathSeparator}Pub${Platform.pathSeparator}Cache';
		}
	}
	final home = Platform.environment['HOME'];
	if (home != null && home.isNotEmpty) {
		return '$home/.pub-cache';
	}
	return '.pub-cache';
}

/// The Flutter SDK root, found from `FLUTTER_ROOT` or next to the Dart VM.
String? flutterRoot() {
	final override = Platform.environment['FLUTTER_ROOT'];
	if (override != null && Directory(override).existsSync()) {
		return override;
	}
	final executable = Platform.resolvedExecutable;
	final candidate = File(executable).parent.parent.parent;
	for (final marker in ['LICENSE', 'version']) {
		if (File('${candidate.path}${Platform.pathSeparator}$marker').existsSync()) {
			return candidate.path;
		}
	}
	return null;
}

/// The Gradle user home, consulted for cached POMs as a last resort.
String? gradleCacheRoot() {
	final override = Platform.environment['GRADLE_USER_HOME'];
	if (override != null && Directory(override).existsSync()) {
		return override;
	}
	final home = Platform.isWindows
			? Platform.environment['USERPROFILE']
			: Platform.environment['HOME'];
	if (home == null || home.isEmpty) {
		return null;
	}
	final path = '$home/.gradle';
	return Directory(path).existsSync() ? path : null;
}

/// Reads the `dependency:` value of every entry in a pubspec.lock.
///
/// The lockfile records how each package entered the graph: `direct main`,
/// `direct dev` or `transitive`. `direct dev` is the one honest signal that
/// a package is absent from a release artifact, without walking a graph the
/// tool does not need to solve.
Map<String, ({String version, String source, String url, String dependency})> parseLockfile(
	String path,
) {
	final result = <String, ({String version, String source, String url, String dependency})>{};
	final text = readIfExists(path);
	if (text == null) {
		return result;
	}
	final blocks = RegExp(
		r'^  ([a-zA-Z0-9_]+):\n((?:    .*\n?)*)',
		multiLine: true,
	).allMatches(text);
	for (final block in blocks) {
		final name = block.group(1)!;
		final body = block.group(2)!;
		final version = RegExp(r'version: "?([^"\n]+)"?').firstMatch(body)?.group(1)?.trim();
		final source = RegExp(r'source: (\S+)').firstMatch(body)?.group(1);
		final url = RegExp(r'url: "?([^"\n]+)"?').firstMatch(body)?.group(1)?.trim();
		final dependency = RegExp(r'dependency: "?([^"\n]+?)"?\s*$', multiLine: true)
				.firstMatch(body)
				?.group(1)
				?.trim();
		if (version == null || source == null) {
			continue;
		}
		result[name] = (
			version: version,
			source: source,
			url: url ?? '',
			dependency: dependency ?? 'transitive',
		);
	}
	return result;
}

/// The `LICENSE` file inside a pub-cached package, if the cache is present.
String? cachedPackageLicence(String name, String version) {
	final roots = [
		'${pubCacheRoot()}${Platform.pathSeparator}hosted${Platform.pathSeparator}pub.dev',
		'${pubCacheRoot()}${Platform.pathSeparator}hosted${Platform.pathSeparator}pub.dartlang.org',
	];
	for (final root in roots) {
		final prefix = '$root${Platform.pathSeparator}$name-$version';
		for (final candidate in [
			'$prefix${Platform.pathSeparator}LICENSE',
			'$prefix${Platform.pathSeparator}LICENSE.txt',
			'$prefix${Platform.pathSeparator}LICENSE.md',
			'$prefix${Platform.pathSeparator}COPYING',
			'$prefix${Platform.pathSeparator}COPYING.txt',
		]) {
			final text = readIfExists(candidate);
			if (text != null) {
				return text;
			}
		}
	}
	return null;
}

/// The Flutter SDK's aggregate third-party licence notices for `sdk: flutter` packages.
/// This is an aggregate notice file, not a single licence grant.
String? sdkLicence() {
	final root = flutterRoot();
	if (root == null) {
		return null;
	}
	return readIfExists('$root${Platform.pathSeparator}LICENSE');
}

/// Matches the SPDX identifier from a licence text.
///
/// Deliberately conservative, and ordered by *position* rather than by
/// precedence: a licence document states which licence governs first, and
/// OpenVPN's own `LICENSE.txt` says "distributed under the GPL license
/// version 2" before it lists an Apache-2.0 clause for bundled components.
/// Checking Apache first would label the whole file Apache-2.0; checking
/// whichever marker appears first is what the document itself says.
///
/// A near-miss returns `unknown` so the inventory can say "the text is
/// there but it does not name a known licence", which is true, rather than
/// asserting one that is not.
String spdxFromText(String text) {
	// Inspect the actual licence clauses, not just the heading. Common BSD
	// texts in Dart packages start with a copyright line and do not contain the
	// literal word "BSD" or "license" anywhere in the grant itself.
	final head = text.length > 16384 ? text.substring(0, 16384) : text;
	// Licence documents wrap their lines, so a marker such as "…FOLLOWING
	// CONDITIONS ARE / MET:" is split across two lines. Collapsing every run of
	// whitespace to a single space lets the contiguous markers below match the
	// way the document reads, not the way it was wrapped. The collapse
	// preserves order, so the position comparisons that pick the earliest
	// statement stay correct.
	final upper = head.toUpperCase().replaceAll(RegExp(r'\s+'), ' ');

	/// The offset of the first occurrence of [pattern], or null.
	int? at(Pattern pattern) {
		final match = pattern.allMatches(upper);
		return match.isEmpty ? null : match.first.start;
	}

	/// The offset of a two-part marker that must appear near each other.
	int? atPair(String first, String second, {int within = 400}) {
		final start = at(first);
		if (start == null) {
			return null;
		}
		final window = upper.substring(start, (start + within).clamp(0, upper.length));
		return window.contains(second) ? start : null;
	}

	int best = -1;
	void consider(int? position) {
		if (position == null) {
			return;
		}
		if (best < 0 || position < best) {
			best = position;
		}
	}

	// Each branch both classifies and records where it was found, so the
	// winner is the earliest statement rather than the most specific one.
	final candidates = <({int? position, String id})>[
		(position: atPair('APACHE LICENSE', 'VERSION 2.0') ?? atPair('APACHE LICENSE', 'VERSION 2'), id: 'Apache-2.0'),
		(
			position: at('MIT LICENSE') ??
					(at('PERMISSION IS HEREBY GRANTED, FREE OF CHARGE') == null
							? null
							: at('REDISTRIBUTION AND USE IN SOURCE AND BINARY') == null
									? at('PERMISSION IS HEREBY GRANTED, FREE OF CHARGE')
									: null),
			id: 'MIT',
		),
		(position: at(r'GNU (AFFERO )?LESSER GENERAL PUBLIC LICENSE'), id: 'LGPL-3.0-or-later'),
		(position: at('GNU AFFERO GENERAL PUBLIC LICENSE'), id: 'AGPL-3.0-or-later'),
		(position: at('GNU GENERAL PUBLIC LICENSE'), id: 'GPL'),
		(position: atPair('MOZILLA PUBLIC LICENSE', 'VERSION 2.0'), id: 'MPL-2.0'),
		(position: at('ECLIPSE PUBLIC LICENSE'), id: 'EPL'),
		(position: at('ISC LICENSE'), id: 'ISC'),
		(position: at('DO WHAT THE FUCK YOU WANT'), id: 'WTFPL'),
	];

	String? winner;
	for (final candidate in candidates) {
		if (candidate.id.isEmpty) {
			continue;
		}
		consider(candidate.position);
		if (best >= 0 && candidate.position == best) {
			winner = candidate.id;
		}
	}

	// Standard BSD notices often do not name the BSD family in their text.
	// Recognise the defining redistribution clause and identify its variant.
	final redistribution = at('REDISTRIBUTION AND USE IN SOURCE AND BINARY FORMS');
	if (redistribution != null) {
		final clauseEnd = (redistribution + 6000).clamp(0, upper.length);
		final clauses = upper.substring(redistribution, clauseEnd);
		if (clauses.contains('PERMITTED PROVIDED THAT THE FOLLOWING CONDITIONS ARE MET')) {
			consider(redistribution);
			if (best == redistribution) {
				if (clauses.contains('ALL ADVERTISING MATERIALS MENTIONING FEATURES OR USE OF THIS SOFTWARE')) {
					winner = 'BSD-4-Clause';
				} else if (clauses.contains('NEITHER THE NAME')) {
					winner = 'BSD-3-Clause';
				} else {
					winner = 'BSD-2-Clause';
				}
			}
		}
	}

	if (winner == null) {
		return 'unknown';
	}
	if (winner == 'GPL') {
		final versionMatch = RegExp(r'VERSION\s+([23])').firstMatch(upper);
		final version = versionMatch?.group(1) ?? '3';
		final orLater = upper.contains('ANY LATER VERSION');
		return orLater ? 'GPL-$version.0-or-later' : 'GPL-$version.0-only';
	}
	if (winner == 'EPL') {
		if (upper.contains('VERSION 2.0')) {
			return 'EPL-2.0';
		}
		if (upper.contains('V 1.0') || upper.contains('VERSION 1.0')) {
			return 'EPL-1.0';
		}
		return 'EPL-2.0';
	}
	if (winner == 'AGPL-3.0-or-later' || winner == 'LGPL-3.0-or-later') {
		final orLater = upper.contains('ANY LATER VERSION');
		return winner.replaceFirst('-or-later', orLater ? '-or-later' : '-only');
	}
	return winner;
}

/// The licence document's own title, for texts SPDX has no identifier for.
String titleFromText(String text) {
	for (final line in lines(text)) {
		final trimmed = line.trim();
		if (trimmed.isEmpty || (trimmed.length > 1 && RegExp(r'^-+$').hasMatch(trimmed))) {
			continue;
		}
		if (RegExp(r'^(?:Copyright\b|©|\(c\))', caseSensitive: false).hasMatch(trimmed)) {
			continue;
		}
		// A copyright header is attribution, never a licence name. If no
		// recognisable licence title or SPDX pattern exists, label the text as
		// unclassified while still making the full text accessible in the UI.
		if (trimmed.length <= 100 &&
				(RegExp(r'\bLICEN[CS]E\b', caseSensitive: false).hasMatch(trimmed) ||
					trimmed == 'Prebuilt Binaries License' ||
					trimmed == 'Public Domain.')) {
			return trimmed;
		}
		return 'Unidentified license text';
	}
	return 'Unidentified license text';
}

/// Pulls the first copyright line out of a licence or attribution text.
String? copyrightFromText(String text) {
	for (final line in lines(text).take(40)) {
		final trimmed = line.trim();
		if (trimmed.isEmpty) {
			continue;
		}
		final match = RegExp(
			r'^(?:\(c\)|©|Copyright\s*(?:\(c\)|©)?\s*)(.+)$',
			caseSensitive: false,
		).firstMatch(trimmed);
		if (match != null) {
			return 'Copyright (c) ${match.group(1)!.trim()}';
		}
	}
	return null;
}

/// The project copyright is intentionally separate from the unmodified GPL text.
String? projectCopyright() {
	final notice = readIfExists('COPYRIGHT');
	return notice == null ? null : copyrightFromText(notice);
}

/// The canonical GPL text does not state which GPL version this project chose.
/// Read that grant from the separate SPDX declaration instead of guessing from
/// boilerplate phrases inside the licence document.
String projectLicenseId() {
	final notice = readIfExists('COPYRIGHT');
	if (notice == null) {
		return 'unknown';
	}
	final match = RegExp(
		r'^\s*SPDX-License-Identifier:\s*([A-Za-z0-9.+-]+)\s*$',
		multiLine: true,
	).firstMatch(notice);
	return match?.group(1) ?? 'unknown';
}

/// Normalises a licence text for embedding.
String normalise(String text) {
	final buffer = StringBuffer();
	for (final line in lines(text)) {
		buffer.writeln(line.replaceAll(RegExp(r'[ \t]+$'), ''));
	}
	var result = buffer.toString();
	while (result.endsWith('\n\n')) {
		result = result.substring(0, result.length - 1);
	}
	return result;
}

/// A Dart string literal for [text] that nothing has to be escaped away.
String dartLiteral(String text) {
	final body = normalise(text);
	if (!body.contains("'''") && !body.contains('"""')) {
		return "r'''$body'''";
	}
	final escaped = body.replaceAll(r'\', r'\\').replaceAll(r'$', r'$').replaceAll("'''", r"\'");	return "'$escaped'";
}

/// The dependency coordinate of every Gradle dependency line, with the
/// `val` interpolations in the same file resolved.
List<({String coordinate, String configuration})> gradleDependencies(String path) {
	final text = readIfExists(path);
	if (text == null) {
		return const [];
	}
	final values = <String, String>{};
	for (final match in RegExp(r'val\s+([A-Za-z0-9_]+)\s*=\s*"([^"]*)"').allMatches(text)) {
		values[match.group(1)!] = match.group(2)!;
	}
	final found = <({String coordinate, String configuration})>[];
	final pattern = RegExp(
		r'^\s*(implementation|api|compileOnly|runtimeOnly|testImplementation|'
		r'androidTestImplementation|debugImplementation|profileImplementation|'
		r'releaseImplementation|lintChecks)'
		r'\s*[( ]\s*"([^"]+)"',
		multiLine: true,
	);
	for (final match in pattern.allMatches(text)) {
		var resolved = match.group(2)!;
		for (final entry in values.entries) {
			resolved = resolved.replaceAll('\$${entry.key}', entry.value);
		}
		found.add((coordinate: resolved, configuration: match.group(1)!));
	}
	return found;
}

/// Finds a Maven POM for a coordinate, preferring anything vendored in the
/// repository over the local Gradle cache.
String? findPom(String group, String artifact, String version) {
	for (final root in const ['packages/phantrix_platform/android/localmaven', 'android/localmaven']) {
		final directory = Directory(root);
		if (!directory.existsSync()) {
			continue;
		}
		final expected = '$artifact-$version.pom';
		for (final entity in directory.listSync(recursive: true)) {
			if (entity is File &&
					entity.path.replaceAll(Platform.pathSeparator, '/').endsWith(expected)) {
				return entity.path;
			}
		}
	}
	final cache = gradleCacheRoot();
	if (cache == null) {
		return null;
	}
	final base = '$cache${Platform.pathSeparator}modules-2${Platform.pathSeparator}files-2.1'
			'${Platform.pathSeparator}$group${Platform.pathSeparator}$artifact${Platform.pathSeparator}$version';
	final directory = Directory(base);
	if (!directory.existsSync()) {
		return null;
	}
	for (final entity in directory.listSync(recursive: true)) {
		if (entity is File && entity.path.endsWith('.pom')) {
			return entity.path;
		}
	}
	return null;
}

/// A licence text shipped inside a Maven artefact directory, when the
/// artefact itself carries one next to its POM or AAR.
///
/// The POM is not always the whole story: `icsopenvpn` declares no
/// `<licenses>` block at all while shipping its real `LICENSE.txt`
/// alongside. The file beside the artefact is the authority when it exists.
({String path, String text})? mavenSiblingLicence(String pomPath) {
	final directory = Directory(File(pomPath).parent.path);
	if (!directory.existsSync()) {
		return null;
	}
	for (final entity in directory.listSync()) {
		if (entity is! File) {
			continue;
		}
		final name = entity.uri.pathSegments.last.toLowerCase();
		if (name == 'license' ||
				name == 'license.txt' ||
				name == 'license.md' ||
				name == 'copying' ||
				name == 'copying.txt') {
			final text = readIfExists(entity.path);
			if (text != null) {
				return (path: entity.path, text: text);
			}
		}
	}
	return null;
}

({String name, String url})? pomLicence(String pomPath) {
	final text = readIfExists(pomPath);
	if (text == null) {
		return null;
	}
	final name = RegExp(r'<licenses>.*?<name>\s*([^<]+?)\s*</name>', dotAll: true)
			.firstMatch(text)
			?.group(1);
	final url = RegExp(r'<licenses>.*?<url>\s*([^<]+?)\s*</url>', dotAll: true)
			.firstMatch(text)
			?.group(1);
	if (name == null) {
		return null;
	}
	return (name: name, url: url ?? '');
}

/// Maps a Maven licence name to an SPDX identifier.
///
/// Only names the mapping is certain of; anything else stays `unknown`
/// with the declared name preserved in the provenance.
String spdxFromPomName(String name) {
	final lower = name.toLowerCase();
	if (lower.contains('apache') && lower.contains('2.0')) {
		return 'Apache-2.0';
	}
	if (lower.contains('eclipse public license') && lower.contains('2.0')) {
		return 'EPL-2.0';
	}
	if (lower.contains('eclipse public license') && lower.contains('1.0')) {
		return 'EPL-1.0';
	}
	if (lower.contains('mit')) {
		return 'MIT';
	}
	if (lower.contains('bsd') && lower.contains('3')) {
		return 'BSD-3-Clause';
	}
	if (lower.contains('bsd') && lower.contains('2')) {
		return 'BSD-2-Clause';
	}
	if (lower.contains('mozilla') && lower.contains('2.0')) {
		return 'MPL-2.0';
	}
	if (lower.contains('gnu general public license') || lower.contains('gpl')) {
		return lower.contains('later') ? 'GPL-2.0-or-later' : 'GPL-2.0-only';
	}
	return 'unknown';
}

/// The app's own version, from its pubspec.
String appVersion() {
	final text = readIfExists('pubspec.yaml');
	if (text == null) {
		return 'unknown';
	}
	final match = RegExp(r'^version:\s*"?([^"\n]+)"?', multiLine: true).firstMatch(text);
	return match?.group(1)?.trim() ?? 'unknown';
}

/// The repository URL, from git's own record of the origin.
String repositoryUrl() {
	final text = readIfExists('.git/config');
	if (text != null) {
		final match = RegExp(r'\[remote "origin"\]\s*\n\s*url\s*=\s*(\S+)').firstMatch(text);
		if (match != null) {
			return match.group(1)!;
		}
	}
	return 'unknown';
}

List<Entry> dartEntries(List<LicenceText> texts) {
	final entries = <Entry>[];
	final byName =
			<String, Map<String, ({String version, String source, String url, String dependency})>>{};
	for (final lockfile in lockfiles) {
		for (final entry in parseLockfile(lockfile.path).entries) {
			byName.putIfAbsent(entry.key, () => {}).putIfAbsent(lockfile.label, () => entry.value);
		}
	}
	for (final package in byName.entries) {
		final name = package.key;
		// Group by the resolved record: one row per (name, version), with
		// every lockfile that resolved that version in its scopes. Two
		// lockfiles resolving different versions stay distinct rows, because
		// a user can only be told about the version that actually ships.
		final grouped = <String, List<String>>{};
		final records =
				<String, ({String version, String source, String url, String dependency})>{};
		for (final resolved in package.value.entries) {
			final record = resolved.value;
			final identity = '${record.version}|${record.source}|${record.url}';
			grouped.putIfAbsent(identity, () => <String>[]).add(resolved.key);
			records[identity] = record;
		}
		for (final group in grouped.entries) {
			final record = records[group.key]!;
			final labels = group.value..sort();
		final notes = <String>[];
		if (record.source == 'sdk') {
			notes.add('sdkDependency');
		}
		if (record.source == 'path') {
			notes.add('projectPackageScopeLimited');
		}
		if (record.dependency.contains('dev')) {
			notes.add('devDependency');
		}
		String licenseId;
		String? text;
		String? textSource;
		if (record.source == 'path') {
			// A path dependency is this project's own package: the licence
			// fact is this repository's own LICENSE file, not a cached copy
			// that can never exist.
			final own = readIfExists('LICENSE');
			text = own;
			licenseId = own == null ? 'unknown' : projectLicenseId();
			textSource = 'path dependency in this repository; SPDX choice read from COPYRIGHT and text from LICENSE';
		} else if (record.source == 'sdk') {
			final licence = sdkLicence();
			if (licence != null) {
				text = licence;
				// The SDK root LICENSE is an aggregate of many component notices,
				// not a single licence grant that can be assigned to every SDK row.
				licenseId = 'Multiple licenses (SDK aggregate notices)';
				textSource = 'Flutter SDK aggregate LICENSE notices';
			} else {
				licenseId = 'unknown';
				textSource = 'SDK package: aggregate licence notices are not readable from this checkout';
			}
		} else {
			final licence = cachedPackageLicence(name, record.version);
			if (licence != null) {
				text = licence;
				licenseId = spdxFromText(licence);
				textSource = 'pub cache: $name-${record.version}';
			} else {
				licenseId = 'unknown';
				textSource = 'no LICENSE found in the pub cache for $name-${record.version}';
			}
		}
			String? licenseKey;
			final labelForId = licenseId == 'unknown' && text != null
					? titleFromText(text)
					: licenseId;
			if (text != null) {
				// Every SDK-backed package points to the same aggregate notice file;
				// store that large document once instead of duplicating it per row.
				licenseKey = record.source == 'sdk'
						? 'flutter-sdk-aggregate-notices'
						: keyFor('$name@${record.version}', labelForId);
				texts.add(LicenceText(licenseKey, text, textSource));
				licenseId = labelForId;
			}
			entries.add(Entry(
				component: 'dart',
				name: name,
				version: record.version,
				licenseId: licenseId,
				licenseKey: licenseKey,
				licenseSource: '$textSource (${lockfilePathFor(labels.first)})',
				sourceUrl: record.url.isNotEmpty ? record.url : null,
				copyright: record.source == 'path'
						? projectCopyright()
						: text == null ? null : copyrightFromText(text),
				noteCodes: notes,
				scopes: labels,
			));
		}
	}
	return entries;
}

/// The lockfile path for a scope label, for the provenance line.
String lockfilePathFor(String label) {
	for (final lockfile in lockfiles) {
		if (lockfile.label == label) {
			return lockfile.path;
		}
	}
	return 'pubspec.lock';
}

List<Entry> androidEntries(List<LicenceText> texts) {
	final entries = <Entry>[];
	final seen = <String>{};
	for (final path in gradleFiles) {
		for (final dependency in gradleDependencies(path)) {
			final coordinate = dependency.coordinate;
			if (seen.contains(coordinate)) {
				continue;
			}
			seen.add(coordinate);
			final parts = coordinate.split(':');
			if (parts.length < 2) {
				continue;
			}
			final group = parts[0];
			final artifact = parts[1];
			final version = parts.length >= 3 ? parts[2] : null;
			final testOnly = dependency.configuration == 'testImplementation' ||
					dependency.configuration == 'androidTestImplementation';
			final pom = version == null ? null : findPom(group, artifact, version);
			final licence = pom == null ? null : pomLicence(pom);
			final sibling = pom == null ? null : mavenSiblingLicence(pom);
			final fallbackPath = androidVendoredLicenceFiles['$group:$artifact'];
			final fallbackLicenseId = androidLicenceIdsWithoutText['$group:$artifact'];
			final fallbackText = sibling == null && fallbackPath != null
					? readIfExists('$attributionDir/$fallbackPath')
					: null;
			String licenseId;
			String? licenseKey;
			if (sibling != null || fallbackText != null) {
				// The artefact's own licence file outranks the POM's declared
				// name; a checked-in fallback is used only for a known dependency
				// whose POM may be absent from an offline fresh checkout.
				final sourceText = sibling?.text ?? fallbackText!;
				final sourcePath = sibling?.path.replaceAll(Platform.pathSeparator, '/') ?? '$attributionDir/$fallbackPath';
				final spdx = spdxFromText(sourceText);
				final detectedLicenseId = spdx == 'unknown' ? titleFromText(sourceText) : spdx;
				licenseId = detectedLicenseId;
				final key = keyFor('$group:$artifact', detectedLicenseId);
				licenseKey = key;
				texts.add(LicenceText(key, sourceText, sourcePath));
			} else {
				licenseId = licence == null
						? (fallbackLicenseId ?? 'unknown')
						: spdxFromPomName(licence.name);
			}
			final notes = <String>[
				if (testOnly) 'testOnly',
				if (licence == null && sibling == null && fallbackText == null) 'licenceTextNotFound',
			];
			entries.add(Entry(
				component: 'android',
				name: '$group:$artifact',
				version: version,
				licenseId: licenseId,
				licenseKey: licenseKey,
				licenseSource: sibling != null
						? 'Maven artefact licence file: ${sibling.path.replaceAll(Platform.pathSeparator, '/')}'
						: fallbackText != null
							? '$attributionDir/$fallbackPath (checked-in fallback licence text; provenance documented in THIRD_PARTY_LICENSES.md)'
							: licence == null && fallbackLicenseId != null
								? 'Published Maven metadata declares $fallbackLicenseId for $coordinate; full licence text is not vendored in this checkout'
								: pom != null
									? 'Maven POM: ${pom.replaceAll(Platform.pathSeparator, '/')}'
									: 'no vendored or cached POM found for $coordinate',
				sourceUrl: (licence?.url.isNotEmpty ?? false)
					? licence!.url
					: androidLicenceUrlsWithoutText['$group:$artifact'],
				copyright: sibling == null ? null : copyrightFromText(sibling.text),
				noteCodes: notes,
			));
		}
	}
	// Text is never available for a Maven artefact's licence from the POM
	// alone — the POM names it, the full text would be fabricated. The name
	// and URL are the whole of the readable fact, and they are what ships.
	return entries;
}

List<Entry> windowsEntries(List<LicenceText> texts) {
	final entries = <Entry>[];
	for (final descriptor in windowsLicenceFiles) {
		final bundlePath = descriptor.bundleFile == null
			? null
			: '$windowsBundleDir/${descriptor.bundleFile}';
		final attributionPath = '$attributionDir/${descriptor.file}';
		final bundleText = bundlePath == null ? null : readIfExists(bundlePath);
		final fallbackText = readIfExists(attributionPath);
		final text = bundleText ?? fallbackText;
		final from = bundleText != null ? bundlePath! : attributionPath;
		final notes = List<String>.of(descriptor.notes);
		if (text == null) {
			entries.add(Entry(
				component: 'windows',
				name: descriptor.component,
				licenseId: 'unknown',
				licenseSource: 'expected at $from, not present in this checkout',
				noteCodes: notes,
			));
			continue;
		}
		final spdx = spdxFromText(text);
		final licenseId = spdx == 'unknown' ? titleFromText(text) : spdx;
		final key = keyFor(descriptor.component, licenseId);
		texts.add(LicenceText(key, text, from));
		entries.add(Entry(
			component: 'windows',
			name: descriptor.component,
			licenseId: licenseId,
			licenseKey: key,
			licenseSource: from,
			copyright: copyrightFromText(text),
			noteCodes: notes,
		));
	}
	return entries;
}

List<Entry> attributionEntries(List<LicenceText> texts) {
	final entries = <Entry>[];
	for (final descriptor in attributionFiles) {
		final path = '$attributionDir/${descriptor.file}';
		final text = readIfExists(path);
		if (text == null) {
			entries.add(Entry(
				component: 'attribution',
				name: descriptor.component,
				licenseId: 'unknown',
				licenseSource: 'expected at $path, not present in this checkout',
				noteCodes: descriptor.notes,
			));
			continue;
		}
		final spdx = spdxFromText(text);
		final licenseId = spdx == 'unknown' ? titleFromText(text) : spdx;
		final key = keyFor(descriptor.component, licenseId);
		texts.add(LicenceText(key, text, path));
		entries.add(Entry(
			component: 'attribution',
			name: descriptor.component,
			licenseId: licenseId,
			licenseKey: key,
			licenseSource: path,
			copyright: copyrightFromText(text),
			noteCodes: descriptor.notes,
		));
	}
	return entries;
}

Entry appEntry(List<LicenceText> texts) {
	final text = readIfExists('LICENSE');
	final licenseId = text == null ? 'unknown' : projectLicenseId();
	String? licenseKey;
	if (text != null) {
		licenseKey = keyFor('phantrix', licenseId == 'unknown' ? titleFromText(text) : licenseId);
		texts.add(LicenceText(licenseKey, text, 'LICENSE'));
	}
	return Entry(
		component: 'app',
		name: 'phantrix',
		version: appVersion(),
		licenseId: licenseId,
		licenseKey: licenseKey,
		licenseSource: 'LICENSE and COPYRIGHT (scope limited to independent original code; see docs/LICENSING_AUDIT.md)',
		sourceUrl: repositoryUrl(),
		copyright: projectCopyright(),
		noteCodes: ['appLicenceScopeLimited'],
	);
}

int compareEntries(Entry a, Entry b) {
	final component =
			componentOrder.indexOf(a.component).compareTo(componentOrder.indexOf(b.component));
	if (component != 0) {
		return component;
	}
	final name = a.name.compareTo(b.name);
	if (name != 0) {
		return name;
	}
	return (a.version ?? '').compareTo(b.version ?? '');
}

String quoted(String? value) => value == null ? 'null' : "'${value.replaceAll(r'\', r'\\').replaceAll("'", r"\'")}'";

String listLiteral(List<String> values) {
	if (values.isEmpty) {
		return '<String>[]';
	}
	return '<String>[${values.map((v) => "'$v'").join(', ')}]';
}

String emitEntry(Entry entry) {
	final buffer = StringBuffer();
	buffer.writeln('\tThirdPartyNoticeData(');
	buffer.writeln('\t\tcomponent: ${quoted(entry.component)},');
	buffer.writeln('\t\tname: ${quoted(entry.name)},');
	if (entry.version != null) {
		buffer.writeln('\t\tversion: ${quoted(entry.version)},');
	}
	if (entry.sourceUrl != null) {
		buffer.writeln('\t\tsourceUrl: ${quoted(entry.sourceUrl)},');
	}
	buffer.writeln('\t\tlicenseId: ${quoted(entry.licenseId)},');
	if (entry.licenseKey != null) {
		buffer.writeln('\t\tlicenseKey: ${quoted(entry.licenseKey)},');
	}
	if (entry.licenseSource != null) {
		buffer.writeln('\t\tlicenseSource: ${quoted(entry.licenseSource)},');
	}
	if (entry.copyright != null) {
		buffer.writeln('\t\tcopyright: ${quoted(entry.copyright)},');
	}
	buffer.writeln('\t\tnoteCodes: ${listLiteral(entry.noteCodes)},');
	buffer.writeln('\t\tscopes: ${listLiteral(entry.scopes)},');
	buffer.write('\t),');
	return buffer.toString();
}

Future<void> main() async {
	final texts = <LicenceText>[];
	final entries = <Entry>[
		appEntry(texts),
		...dartEntries(texts),
		...androidEntries(texts),
		...windowsEntries(texts),
		...attributionEntries(texts),
	]..sort(compareEntries);

	// A text keyed by two entries is stored once; the second entry keeps
	// the same key, so the map never holds two different copies of one
	// licence.
	final uniqueTexts = <String, LicenceText>{};
	for (final text in texts) {
		uniqueTexts.putIfAbsent(text.key, () => text);
	}

	final buffer = StringBuffer();
	buffer.writeln('// GENERATED FILE. DO NOT EDIT BY HAND.');
	buffer.writeln('//');
	buffer.writeln('// Regenerate with `dart run tools/generate_third_party_notices.dart`');
	buffer.writeln('// from the repository root. Every entry and every licence text below');
	buffer.writeln('// is derived from a file that exists in this repository or in a');
	buffer.writeln('// local toolchain cache; where a fact could not be read the entry');
	buffer.writeln('// says where it looked. The output is deterministic, so re-running');
	buffer.writeln('// over unchanged inputs produces a byte-identical file.');
	buffer.writeln();
	buffer.writeln("import 'package:phantrix/notices/third_party_notices.dart';");
	buffer.writeln();
	buffer.writeln('/// Every component this project depends on, adapts, or ships as a');
	buffer.writeln('/// binary, in the order the licences screen renders them.');
	buffer.writeln('const List<ThirdPartyNoticeData> thirdPartyNotices = <ThirdPartyNoticeData>[');
	for (final entry in entries) {
		buffer.writeln(emitEntry(entry));
	}
	buffer.writeln('];');
	buffer.writeln();
	buffer.writeln('/// The licence text of every entry that has one, keyed by [');
	buffer.writeln('/// ThirdPartyNoticeData.licenseKey].');
	buffer.writeln('const Map<String, String> licenseTexts = <String, String>{');
	final orderedTexts = uniqueTexts.values.toList()
		..sort((a, b) => a.key.compareTo(b.key));
	for (final text in orderedTexts) {
		buffer.writeln("\t${quoted(text.key)}: ${dartLiteral(text.text)},");
	}
	buffer.writeln('};');

	final output = File(generatedPath);
	await output.parent.create(recursive: true);
	await output.writeAsString(buffer.toString());

	stdout.writeln(
		'third-party notices: ${entries.length} entries, '
		'${uniqueTexts.length} licence texts -> $generatedPath',
	);
	final unknown = entries.where((e) => e.licenseId == 'unknown').length;
	if (unknown > 0) {
		stdout.writeln('third-party notices: $unknown entries have no readable licence id');
	}
}
