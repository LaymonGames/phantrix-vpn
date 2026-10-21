import '../core/app_error.dart';
import '../core/result.dart';

/// An IP address with a prefix length.
///
/// Deliberately dependency free so the same parsing rules run on every
/// platform and inside unit tests.
class AddressCidr {
  const AddressCidr(this.address, this.prefixLength)
    : assert(prefixLength >= 0);

  final String address;
  final int prefixLength;

  bool get isV4 => !address.contains(':');

  bool get isV6 => !isV4;

  static const int maxV4Prefix = 32;
  static const int maxV6Prefix = 128;

  /// Parses `10.0.0.2/32` or `fd42::1/128`. A missing prefix length is not
  /// accepted: a route without a mask is a configuration bug.
  static Result<AddressCidr> parse(String raw) {
    final value = raw.trim();
    if (value.isEmpty) {
      return _fail('address.empty', 'IP address is empty.');
    }
    final slash = value.lastIndexOf('/');
    if (slash < 0) {
      return _fail(
        'address.prefix_missing',
        'IP address must include a prefix length, for example 10.0.0.2/32.',
      );
    }
    final address = value.substring(0, slash).trim();
    final prefix = int.tryParse(value.substring(slash + 1).trim());
    if (prefix == null) {
      return _fail('address.prefix_invalid', 'Prefix length must be a number.');
    }
    if (!isIpv4(address) && !isIpv6(address)) {
      return _fail('address.invalid', 'Not a valid IP address.');
    }
    final maxPrefix = address.contains(':') ? maxV6Prefix : maxV4Prefix;
    if (prefix < 0 || prefix > maxPrefix) {
      return _fail(
        'address.prefix_range',
        'Prefix length must be between 0 and $maxPrefix.',
      );
    }
    return Ok(AddressCidr(address, prefix));
  }

  static Result<List<AddressCidr>> parseList(String raw) {
    final out = <AddressCidr>[];
    for (final part in raw.split(',')) {
      final trimmed = part.trim();
      if (trimmed.isEmpty) {
        continue;
      }
      final parsed = parse(trimmed);
      final value = parsed.valueOrNull;
      final error = parsed.errorOrNull;
      if (value != null) {
        out.add(value);
      } else if (error != null) {
        return Err<List<AddressCidr>>(error);
      }
    }
    if (out.isEmpty) {
      return Err<List<AddressCidr>>(
        AppError(
          group: ErrorGroup.validation,
          code: 'address.list_empty',
          message: 'At least one IP address is required.',
        ),
      );
    }
    return Ok(out);
  }

  static bool isIpv4(String value) {
    // The SDK parser checks ranges; require decimal octets as well so signs,
    // whitespace and ambiguous leading zeroes cannot pass as an address.
    if (!RegExp(
      r'^(0|[1-9][0-9]{0,2})(\.(0|[1-9][0-9]{0,2})){3}$',
    ).hasMatch(value)) {
      return false;
    }
    try {
      Uri.parseIPv4Address(value);
      return true;
    } on FormatException {
      return false;
    }
  }

  static bool isIpv6(String value) {
    if (!value.contains(':') || !RegExp(r'^[0-9A-Fa-f:.]+$').hasMatch(value)) {
      return false;
    }
    if (value.contains('.') &&
        !isIpv4(value.substring(value.lastIndexOf(':') + 1))) {
      return false;
    }
    try {
      Uri.parseIPv6Address(value);
      return true;
    } on FormatException {
      return false;
    }
  }

  static Result<AddressCidr> _fail(String code, String message) =>
      Err(AppError(group: ErrorGroup.validation, code: code, message: message));

  @override
  String toString() => '$address/$prefixLength';

  @override
  bool operator ==(Object other) =>
      other is AddressCidr &&
      other.address == address &&
      other.prefixLength == prefixLength;

  @override
  int get hashCode => Object.hash(address, prefixLength);
}
