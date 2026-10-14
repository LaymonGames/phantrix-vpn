/// The shape of one line in the third-party inventory.
///
/// Every field of this class is produced by
/// `tools/generate_third_party_notices.dart` from files that actually exist:
/// a `pubspec.lock`, a `LICENSE` in the pub cache, a Gradle dependency line, a
/// vendored Maven POM, a licence text fetched from an upstream repository.
/// Nothing here is typed in by hand and nothing is inferred from a package's
/// *name*. When a licence is not identifiable, the inventory records that
/// the text is unidentified or missing rather than inventing a grant.
///
/// The fields that describe *this project* are read from this repository:
/// version and URL from `pubspec.yaml`/Git metadata, its SPDX grant and
/// copyright from `COPYRIGHT`, and the full licence text from `LICENSE`.
/// Those are not third-party facts, and the generator reads them rather than
/// guessing the grant from generic GPL boilerplate.
class ThirdPartyNoticeData {
	const ThirdPartyNoticeData({
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

	/// Which part of the build this component belongs to.
	///
	/// One of `app` (Phantrix itself), `dart` (a `pubspec.lock` entry),
	/// `android` (a Gradle declaration or a vendored Android artefact),
	/// `windows` (the bundled Windows binaries) or `attribution` (code this
	/// project adapts or ships the provenance of, which owes a notice).
	final String component;

	/// Package name, Maven coordinate or component name.
	final String name;

	/// Resolved version, when the component has one.
	final String? version;

	/// Where the component is published, when that is known.
	final String? sourceUrl;

	/// The licence label detected from the source text (usually an SPDX
	/// identifier), or an explicit uncertainty label when the source notices
	/// conflict. When neither a licence identifier nor title is readable, it
	/// is `unknown`; uncertainty is never silently resolved by guessing.
	final String licenseId;

	/// Key into the generated licence-text map, or null when no licence text
	/// was found. Null is a fact, not a placeholder: the UI must show it as
	/// "not found" rather than invent a licence.
	final String? licenseKey;

	/// Where the licence fact itself came from — a pub-cache file, a POM URL,
	/// a fetched upstream file. Shown in the UI as provenance.
	final String? licenseSource;

	/// A copyright line read out of the licence text, when one is present.
	final String? copyright;

	/// Machine-readable caveats, each translated to a real sentence by the UI
	/// through `licensesNote_<code>`.
	///
	/// The codes, and what each one asserts:
	///
	/// - `devDependency` — reachable only from `dev_dependencies`, so it is
	///   absent from a release artifact.
	/// - `sdkDependency` — supplied as part of the Flutter or Dart SDK; the
	///   aggregate SDK licence-notice file is displayed, and contains multiple
	///   component licences rather than one grant for every SDK package.
	/// - `testOnly` — declared in `testImplementation` or `androidTest`.
	/// - `notBundled` — a real, fetched licence for a component that is *not*
	///   linked into this repository today. Listed so the notice exists the
	///   moment it is linked, and so the absence is visible rather than
	///   implied.
	/// - `adaptedUpstream` — this project's copy is an adaptation, and the
	///   licence and copyright shown are upstream's.
	/// - `mereAggregation` — the Windows OpenVPN 2 binary is distributed as a
	///   separate process. This note records that process boundary; it is not
	///   a general compatibility conclusion.
	/// - `variantUnclear` — the licence text establishes the GPL version but
	///   not whether "or any later version" applies.
	/// - `appLicenceScopeLimited` — the displayed GPL-3.0-only grant applies to
	///   Phantrix's original code; third-party components keep their own licences.
	/// - `projectPackageScopeLimited` — a path package contains project-owned
	///   code as well as platform or bundled components whose licences may differ;
	///   see THIRD_PARTY_LICENSES.md and docs/LICENSING_AUDIT.md for scope.
	final List<String> noteCodes;

	/// Which lockfile(s) resolved this package. Several, when the app and its
	/// two sibling packages lock different copies.
	final List<String> scopes;

	/// Whether a full licence text was bundled for this entry.
	bool get hasLicenseText => licenseKey != null;
}

/// Helpers shared by the licences screen and its tests.
class ThirdPartyNotices {
	ThirdPartyNotices._();

	/// The licences screen renders [component] in this order.
	static const List<String> componentOrder = [
		'app',
		'dart',
		'android',
		'windows',
		'attribution',
	];

	/// Sorts [notices] into the stable order the generated file uses, so a UI
	/// test can find the nth entry without first re-sorting it.
	static List<ThirdPartyNoticeData> sorted(List<ThirdPartyNoticeData> notices) =>
			List<ThirdPartyNoticeData>.of(notices)..sort(_compare);

	/// The localisation keys for [notice], one per caveat it carries.
	static List<String> noteKeys(ThirdPartyNoticeData notice) => [
		for (final code in notice.noteCodes) 'licensesNote_$code',
	];

	static int _compare(ThirdPartyNoticeData a, ThirdPartyNoticeData b) {
		final component = componentOrder
				.indexOf(a.component)
				.compareTo(componentOrder.indexOf(b.component));
		if (component != 0) {
			return component;
		}
		final name = a.name.compareTo(b.name);
		if (name != 0) {
			return name;
		}
		return (a.version ?? '').compareTo(b.version ?? '');
	}
}
