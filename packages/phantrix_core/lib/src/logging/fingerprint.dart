/// A short, non-reversible fingerprint for a secret.
///
/// Uses a 64-bit FNV-1a hash implemented over two 32-bit halves, because
/// JavaScript cannot represent 64-bit integer literals. Using
/// `0xcbf29ce484222325` directly would break the web build outright.
///
/// This is not a cryptographic hash and is never used as one: its only job is
/// to let a support engineer tell that two occurrences of a value are the same
/// value without the value itself being printed.
int stableFingerprint(String value) {
	const uint32Mask = 0xFFFFFFFF;

	// The FNV-1a offset basis and prime, split into 32-bit halves.
	var high = 0xcbf2;
	var low = 0x9ce48422;

	for (final byte in value.codeUnits) {
		low ^= byte;
		// Multiply by the 64-bit prime 0x00000100000001b3 using 32-bit halves.
		const primeHigh = 0x00000100;
		const primeLow = 0x000001b3;

		final lowProduct = low * primeLow;
		final highProduct = high * primeLow + (lowProduct >> 32) + (low >> 32) * primeHigh;

		low = lowProduct & uint32Mask;
		high = highProduct & uint32Mask;
	}

	// Fold to a single 32-bit value for display. Collisions between two
	// different secrets are possible and acceptable here.
	return high ^ low;
}

/// Formats [stableFingerprint] as 8 lowercase hex characters.
String fingerprintHex(String value) =>
		stableFingerprint(value).toRadixString(16).padLeft(8, '0');
