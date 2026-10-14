import 'dart:convert';

import '../../core/app_error.dart';
import '../../core/result.dart';

/// Base64 helpers for the exact 32-byte WireGuard key encoding.
class WireGuardKey {
	const WireGuardKey._();

	static const int keyLengthBytes = 32;
	static const int encodedLength = 44;

	static final RegExp _head = RegExp(r'^[A-Za-z0-9+/]{43}$');

	static bool isValid(String value) => _tryParse(value) != null;

	static String? _tryParse(String value) {
		final trimmed = value.trim();
		if (trimmed.length != encodedLength || !trimmed.endsWith('=')) {
			return null;
		}
		if (!_head.hasMatch(trimmed.substring(0, 43))) {
			return null;
		}
		try {
			if (base64Decode(trimmed).length != keyLengthBytes) {
				return null;
			}
		} on FormatException {
			return null;
		}
		return trimmed;
	}

	static Result<String> parse(String value, {String field = 'key'}) {
		final parsed = _tryParse(value);
		if (parsed == null) {
			return Err(
				AppError(
					group: ErrorGroup.validation,
					code: 'key.format',
					message:
						'Invalid WireGuard $field. A key is exactly 44 base64 '
						'characters (32 bytes) ending in "=".',
				),
			);
		}
		return Ok(parsed);
	}
}
