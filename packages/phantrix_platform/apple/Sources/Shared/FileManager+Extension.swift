// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.
//
// Vendored from wireguard-apple, MIT licensed. Adapted only in the
// Info.plist keys that name the app group, which are Phantrix's own.

import Foundation
import os.log

extension FileManager {
	static var appGroupId: String? {
		#if os(iOS)
		let appGroupIdInfoDictionaryKey = "com.phantrix.ios.app_group_id"
		#elseif os(macOS)
		let appGroupIdInfoDictionaryKey = "com.phantrix.macos.app_group_id"
		#else
		#error("Unimplemented")
		#endif
		return Bundle.main.object(forInfoDictionaryKey: appGroupIdInfoDictionaryKey) as? String
	}
	private static var sharedFolderURL: URL? {
		guard let appGroupId = FileManager.appGroupId else {
			os_log("Cannot obtain app group ID from bundle", log: OSLog.default, type: .error)
			return nil
		}
		guard let sharedFolderURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
			wg_log(.error, message: "Cannot obtain shared folder URL")
			return nil
		}
		return sharedFolderURL
	}

	static var logFileURL: URL? {
		return sharedFolderURL?.appendingPathComponent("tunnel-log.bin")
	}

	static var networkExtensionLastErrorFileURL: URL? {
		return sharedFolderURL?.appendingPathComponent("last-error.txt")
	}

	static var loginHelperTimestampURL: URL? {
		return sharedFolderURL?.appendingPathComponent("login-helper-timestamp.bin")
	}

	static func deleteFile(at url: URL) -> Bool {
		do {
			try FileManager.default.removeItem(at: url)
		} catch {
			return false
		}
		return true
	}
}
