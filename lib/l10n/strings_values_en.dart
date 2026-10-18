part of 'strings.dart';

const Map<String, String> _stringsValuesEn = {
    'appTitle': 'Phantrix',
    'home': 'Home',
    'server': 'Server',
    'actions': 'Actions',
    'locations': 'Locations',
    'diagnostics': 'Diagnostics',
    'privacy': 'Privacy',
    'settings': 'Settings',
    'connect': 'Connect',
    'connecting': 'Connecting…',
    'disconnect': 'Disconnect',
    'notConnected': 'Not connected',
    'connected': 'Connected',
    'chooseLocation': 'Choose Location',
    'automaticLocation': 'Automatic · best available',
    'automaticLocationHint': 'Let Phantrix choose the best eligible server.',
    'publicRelayNoticeTitle':
        'The built-in public relays need OpenVPN support',
    'publicFeedOpenVpnOnly':
        'The bundled public servers use OpenVPN, and this platform has no '
        'OpenVPN engine available, so none of them can be connected.',
    'savedLocationHint': 'Saved preference · tap to change',
    'tapToChangeLocation': 'Tap to change location',
    'tryAgain': 'Try again',
    'retry': 'Retry',
    'noServerInCountry':
        'There is no usable server in this country right now.',
    'serversAvailable': 'servers available',
    'searchCountries': 'Search countries',
    'sortByName': 'Name',
    'sortByCount': 'Server count',
    'toggleMap': 'Show or hide the map',
    'refreshingServers': 'Refreshing the server list…',
    'serverListUnavailable': 'The server list could not be loaded.',
    'noServerListYet': 'No server list has been loaded yet.',
    'noServerListHint':
        'Tap Refresh to ask the server sources for their current list.',
    'refresh': 'Refresh',
    'serverListStale': 'This server list is out of date.',
    'showingCachedList': 'Showing the last list that was loaded.',
    'cachedListDamaged':
        'The saved server list was damaged and has been rebuilt.',
    'serverListCurrent': 'Server list is up to date.',
    'publicRelayWarning': 'Volunteer-run public relay. The operator can see your traffic, and it is not operated by this project.',
    'noServersFound': 'No servers were found. No connection can be made until at least one source returns a usable server.',
    'fastest': 'Fastest',
    'nearest': 'Nearest',
    'random': 'Random',
    'runChecks': 'Run checks',
    'amIProtected': 'Am I protected?',
    'leakExplanation':
        'Checking the public IP makes one request to a service that then '
        'knows the address your traffic appears to come from. Phantrix '
        'sends nothing else.',
    'notTested': 'Not tested',
    'notSupported': 'Not supported here',
    'checkPassed': 'Protected',
    'checkWarning': 'Warning',
    'checkFailed': 'Potential leak',
    'settingsConnection': 'Connection',
    'settingsPrivacy': 'Privacy',
    'settingsAppearance': 'Appearance',
    'settingsAdvanced': 'Advanced',
    'settingsAbout': 'About',
    'settingsDiagnostics': 'Diagnostics',
    'settingsDiagnosticsHint': 'Tunnel state, traffic and handshake evidence',
    'settingsPrivacyNotice': 'Privacy notice',
    'settingsPrivacyNoticeHint':
        'What this app records, and what it does not',
    'settingsKillSwitchUnsupported':
        'Phantrix cannot block traffic itself when the tunnel drops. '
        'Automatic reconnects after a failure; it does not hold traffic '
        'back while reconnecting. The protection that exists is the '
        'system\u2019s own traffic blocking, shown below where '
        'the system provides one.',
    'settingsSystemLockdown': 'System traffic blocking',
    'settingsSystemLockdownOn': 'On',
    'settingsSystemLockdownOff': 'Off',
    'settingsSystemLockdownOnHint':
        'Android itself is blocking traffic outside the VPN. This is set '
        'in the system settings and stays in effect even if this app '
        'is closed.',
    'settingsSystemLockdownOffHint':
        'If the tunnel drops, traffic can leave over the normal network '
        'until the app reconnects. Enable Always-on VPN with Block '
        'connections without VPN in the system settings for protection '
        'that does not depend on this app running.',
    'settingsOpenVpnSettings': 'Open VPN settings',
    'killSwitch': 'Kill switch',
    'killSwitchOff': 'Off',
    'killSwitchAutomatic': 'Automatic',
    'killSwitchStrict': 'Strict',
    'ipv6': 'IPv6',
    'ipv6Block': 'Block while connected',
    'ipv6Prefer': 'Route when supported',
    'ipv6Allow': 'Allow (may leak)',
    'startOnBoot': 'Start on system boot',
    'theme': 'Theme',
    'themeLight': 'Light',
    'themeDark': 'Dark',
    'themeSystem': 'System',
    'animation': 'Animation',
    'language': 'Language',
    'clearData': 'Clear local data',
    'clearDataHint':
        'Removes settings, cached server lists and recent connections from '
        'this device.',
    'clearDataAction': 'Clear',
    'clearDataDone': 'Local data cleared.',
    'aboutVersion': 'Version',
    'aboutCreator': 'Creator',
    'aboutPortfolio': 'Portfolio',
    'portfolioOpenFailed':
        'Could not open the link. Visit '
        'laymongames.github.io/portfolio instead.',
    'aboutDisclaimer':
        'You remain responsible for complying with applicable laws, '
        'network policies, and the terms of the networks and services you '
        'use.',
    'licensesTitle': 'Licenses & credits',
    'settingsLicenses': 'About, licenses and credits',
    'settingsLicensesHint':
        'Which components this app is built from, and under which '
        'licences',
    'licensesRepository': 'Source',
    'licensesAppLicense': 'Licence',
    'licensesCopyright': 'Copyright',
    'licensesSource': 'Source',
    'licensesProvenance': 'Licence read from',
    'licensesFullText': 'Full licence text',
    'licensesMissingText':
        'No licence text could be read for this component from local '
        'data. Use the source link or the provenance line above rather '
        'than assuming a licence.',
    'licensesGeneratedNote':
        'This inventory is generated from the project\u2019s lockfiles '
        'and build files by tools/generate_third_party_notices.dart. It '
        'is never edited by hand, and every line says where its fact '
        'came from.',
    'licensesSectionDart': 'Dart and Flutter packages',
    'licensesSectionAndroid': 'Android libraries',
    'licensesSectionWindows': 'Windows components',
    'licensesSectionAttribution': 'Adapted and bundled components',
    'licensesVpnGateTitle': 'VPN Gate',
    'licensesVpnGateBody':
        'Part of this app\u2019s built-in server list comes from the '
        'VPN Gate academic experiment (vpngate.net) at the University '
        'of Tsukuba. Those servers are run by volunteers: this project '
        'does not operate them, cannot vouch for them, and is not '
        'affiliated with VPN Gate or the university. The operator of '
        'any server you choose can see the traffic that leaves it.',
    'licensesNote_appLicenceScopeLimited':
        'This GPL-3.0-only notice applies to Phantrix\u2019s original code. '
        'Third-party components listed here keep their own licences. '
        'See docs/LICENSING_AUDIT.md.',
    'licensesNote_projectPackageScopeLimited':
        'This repository-local package contains original project code plus '
        'platform or bundled components that may have separate licence terms. '
        'The GPL-3.0-only grant applies only to independently authored Phantrix '
        'code; consult THIRD_PARTY_LICENSES.md and docs/LICENSING_AUDIT.md.',
    'licensesNote_devDependency':
        'Development and test only. It is not part of a released build.',
    'licensesNote_sdkDependency':
        'Part of the Flutter or Dart SDK. The displayed SDK file is an '
        'aggregate of multiple component notices, not a single licence grant.',
    'licensesNote_testOnly': 'Test only. It is not part of a released build.',
    'licensesNote_notBundled':
        'Not bundled with this build. Listed for completeness.',
    'licensesNote_shippedBinary':
        'A compiled binary is bundled with this app.',
    'licensesNote_adaptedUpstream':
        'This project\u2019s code is an adaptation of the upstream '
        'project. The licence and copyright shown are upstream\u2019s.',
    'licensesNote_mereAggregation':
        'Windows-only aggregation: OpenVPN 2 is launched as a separate '
        'process, not linked into the app.',
    'licensesNote_variantUnclear':
        'The licence text establishes the GPL version but not whether '
        '\u201Cor any later version\u201D applies.',
    'licensesNote_licenceTextNotFound':
        'The licence name is known, but its full text is not bundled '
        'with this app.',
    'welcomeTitle': 'Private, simple, no account required.',
    'welcomeBody':
        "Phantrix routes this device's traffic through a VPN with no "
        'account, no email address, and no subscription.',
    'privacyNoticeTitle': 'What a VPN does and does not do',
    'privacyNoticeBody':
        'A VPN encrypts traffic between this device and the server it '
        'exits from. It does not make you anonymous, and the operator of '
        'a free public server can observe the traffic that leaves it.',
    'privacyNoticeAccept': 'I understand. Continue.',

    // ——— The connection story ———
    //
    // Emitted by the connection layer, which has no widget in scope: the
    // controller resolves these against the language the user chose and
    // hands the screen a finished sentence. English values are the exact
    // sentences the layer wrote before it learned to localise, so nothing
    // changes for the existing tests; the placeholders ({seconds}, {ip}…)
    // are replaced at emit time with the values measured for this attempt.
    'flowNotConnected': 'Not connected.',
    'flowNegotiating': 'Negotiating with the server…',
    'flowInterfaceUp':
        'Tunnel interface is up; waiting for the server to complete the '
        'connection…',
    'flowNetworkChanged': 'The network changed; reconnecting…',
    'flowDisconnecting': 'Disconnecting…',
    'flowPreparing': 'Preparing the tunnel…',
    'flowPermissionWaiting':
        'Waiting for VPN permission from the operating system…',
    'flowPermissionNeeded': 'VPN permission is needed before connecting.',
    'flowPermissionDeniedCard':
        'The operating system did not grant VPN permission, so no tunnel '
        'was started.',
    'flowTunnelFailed': 'The tunnel failed.',
    'flowTunnelDied':
        'The tunnel stopped unexpectedly before it connected. No error was '
        'reported; trying the same server again is the first thing to attempt.',
    'flowTunnelCancelled': 'The connection attempt was cancelled.',
    'flowStillShuttingDown':
        'The connection could not be started because the previous tunnel is '
        'still shutting down.',
    'flowRetry': 'Retrying…',
    'flowLookingForServer': 'Looking for a server…',
    'flowHandshaked': 'Handshake completed. Verifying the exit address…',
    'flowConnectedVia':
        'Connected via {ip}, which is different from the address used '
        'before connecting.',
    'flowConnectedViaUncertain':
        'Connected via {ip}. The address used before connecting could not '
        'be read, so the change in address could not be confirmed; the '
        'handshake with the server was verified.',
    'flowHandshakeMissing':
        'The tunnel interface is up, but the server has not completed '
        '{article} {protocol} handshake yet, so nothing is being carried. '
        'This usually means the server is unreachable or is rejecting this '
        'configuration.',
    'flowHandshakeStale':
        'The last successful handshake was {minutes} minutes ago. The '
        'server has stopped responding, so this is no longer a working '
        'tunnel even though the interface is still showing as up.',
    'flowVerifyCancelled':
        'Verification was cancelled before the exit address could be '
        'confirmed.',
    'flowVerifyUnreachable':
        'The handshake succeeded, but no external address service could be '
        'reached, even after several tries, so the connection could not be '
        'verified. It is not being reported as connected because that '
        'cannot be confirmed.',
    'flowExitUnchanged':
        'The public address did not change after connecting ({ip} both '
        'before and after, re-checked over several seconds), so traffic is '
        'still leaving outside the tunnel.',
    'flowTimeout':
        'The connection did not complete within {seconds}s: {detail}. '
        'The tunnel has been stopped.',
    'flowTimeoutNoHandshake': 'the engine never reported a handshake',
    'flowTimeoutUnverified': 'the handshake could not be verified in time',

    // The multi-server walk, in the words the user can act on: what was
    // tried, in what country, and whether the relays were ever heard from.
    'walkNextServer':
        'The selected server did not answer; trying the next one '
        '({tried} of {depth})…',
    'walkSecondTry':
        'A relay completed the handshake but the exit could not be '
        'confirmed. Trying that relay once more…',
    'walkExhaustedRetried':
        'Tried {tried} relays{where}. One completed a handshake, but its '
        'exit could not be confirmed even on a second attempt. Volunteer '
        'relays often connect only on a later try — try again shortly, or '
        'refresh the list and pick another relay.',
    'walkExhaustedSilent':
        'Tried {tried} relays{where} and none completed a handshake. '
        'Public relay lists change quickly — refresh the server list and '
        'try again.',
    'walkExhaustedDark':
        'Tried {tried} relays{where} and none completed a handshake; '
        '{silent} of them never answered at all. Relays that stay silent '
        'are usually blocked or down — refresh the server list or try '
        'another country.',

    // Selection and configuration problems: why nothing was attempted.
    'selNoEndpoints':
        'No server endpoints are available yet. The app can try cached '
        'relays when present.',
    'selUnknownCountry': 'The server list has no servers in {country}.',
    'selAllProtocols':
        'Every server{where} speaks {names}, and this build cannot start '
        '{it} on this device, so nothing was attempted. {remedy}',
    'selThisServer':
        'This server speaks {protocol}, and this build cannot start it on '
        'this device, so nothing was attempted. {remedy}',
    'selRemedyWireGuard': 'this build does not run WireGuard',
    'selRemedyOpenVpn': 'OpenVPN needs a build that bundles the community engine',
    'selNoEligible':
        'No server currently passes the health and trust checks. '
        'Try again shortly.',
    'selNoEligibleCountry':
        'No server in {country} currently passes the health and trust checks.',
    'selSourceGone':
        'The source "{provider}" that published {host} is no longer '
        'enabled. Refresh the server list.',
    'selDownloadFailed':
        'Could not download the configuration for {host}.',
    'selProfileMissing':
        '{provider} lists {host} but its profile is missing or failed '
        'validation, so it cannot be connected to.',
    'selProtocolOnly':
        '{provider} lists {host} but supplies only a {protocol} '
        'configuration, which this build cannot start on this device, so it '
        'cannot be connected to.',
    'selNoneSelected': 'No server has been selected yet. Pick one from Locations.',
    'selRetryNeedsSelection':
        'The last attempt never reached a tunnel, and there is no server '
        'selection to repeat. Choose a server from Locations and try again.',
    'selProfileFallbackNote':
        'The highest-ranked relay had no usable profile; using the next '
        'compatible relay.',
    'selCachedDirectoryNote':
        'The live server feed is unavailable; trying a previously saved '
        'relay. Its current reachability has not been verified. {note}',
    'selNextInRankNote': 'The next eligible server in the ranking.',

    // The state's own short names, for the places where only a state fits —
    // the sidebar status after a failure has no sentence of its own.
    'state.disconnected': 'Disconnected',
    'state.permissionRequired': 'Permission needed',
    'state.preparing': 'Preparing',
    'state.connecting': 'Connecting',
    'state.reconnecting': 'Reconnecting',
    'state.connected': 'Connected',
    'state.disconnecting': 'Disconnecting',
    'state.error': 'Error',
    'state.blocked': 'Needs attention',
    'state.noServerAvailable': 'No server available',

    // The sidebar's per-state one-liners, under the flow lines above.
    'sidebarTunnelEstablished': 'Tunnel established',
    'sidebarNegotiating': 'Negotiating a tunnel',
    'sidebarTapToTryAgain': 'Tap to try again',
    'sidebarNeedsAttention': 'Needs your attention',
    'sidebarNotProtected': 'Not protected',
    'chooseALocation': 'Choose a location',
};
