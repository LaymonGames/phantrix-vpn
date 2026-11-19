import 'dart:convert';

import 'package:http/http.dart' as http;

/// Resolves server IPs to the state / region they sit in.
///
/// The public VPN Gate feed publishes a country but no state, so the
/// locations screen would have no states to offer. This asks ip-api.com's
/// batch endpoint (100 IPs per request, no key) for each server's region.
/// Only server addresses are sent, never anything about the user, though the
/// request itself comes from the user's IP like any other feed fetch.
///
/// Every failure is swallowed and returns what was resolved so far: a
/// missing state only means the country offers "Fastest" alone.
typedef RegionLookup = Future<Map<String, String>> Function(List<String> ips);

RegionLookup ipApiRegionLookup({http.Client? client}) {
  return (ips) async {
    final owned = client == null;
    final c = client ?? http.Client();
    final result = <String, String>{};
    try {
      for (var i = 0; i < ips.length; i += 100) {
        final chunk = ips.sublist(i, i + 100 > ips.length ? ips.length : i + 100);
        final response = await c
            .post(
              Uri.parse(
                'http://ip-api.com/batch?fields=status,query,regionName',
              ),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode(chunk),
            )
            .timeout(const Duration(seconds: 10));
        if (response.statusCode != 200) {
          break;
        }
        final decoded = jsonDecode(response.body);
        if (decoded is! List) {
          break;
        }
        for (final row in decoded) {
          if (row is Map &&
              row['status'] == 'success' &&
              row['query'] is String &&
              row['regionName'] is String &&
              (row['regionName'] as String).trim().isNotEmpty) {
            result[row['query'] as String] = (row['regionName'] as String)
                .trim();
          }
        }
      }
    } on Object {
      // Best effort; see the type's documentation.
    } finally {
      if (owned) {
        c.close();
      }
    }
    return result;
  };
}
