import AppKit
import Foundation
import Observation
import Security
import CoreAudio

@Observable
@MainActor
final class AppSettings {
    var kbFolderPath: String {
        didSet { UserDefaults.standard.set(kbFolderPath, forKey: "kbFolderPath") }
    }

    var selectedModel: String {
        didSet { UserDefaults.standard.set(selectedModel, forKey: "selectedModel") }
    }

    var transcriptionLocale: String {
        didSet { UserDefaults.standard.set(transcriptionLocale, forKey: "transcriptionLocale") }
    }

    /// Stored as the AudioDeviceID integer. 0 means "use system default".
    var inputDeviceID: AudioDeviceID {
        didSet { UserDefaults.standard.set(Int(inputDeviceID), forKey: "inputDeviceID") }
    }

    var awsAccessKeyId: String {
        didSet { KeychainHelper.save(key: "awsAccessKeyId", value: awsAccessKeyId) }
    }

    var awsSecretAccessKey: String {
        didSet { KeychainHelper.save(key: "awsSecretAccessKey", value: awsSecretAccessKey) }
    }

    var awsRegion: String {
        didSet { UserDefaults.standard.set(awsRegion, forKey: "awsRegion") }
    }

    /// When true, all app windows are invisible to screen sharing / recording.
    var hideFromScreenShare: Bool {
        didSet {
            UserDefaults.standard.set(hideFromScreenShare, forKey: "hideFromScreenShare")
            applyScreenShareVisibility()
        }
    }

    /// Whether AWS credentials are configured (Keychain or environment).
    var hasAWSCredentials: Bool {
        !awsAccessKeyId.isEmpty && !awsSecretAccessKey.isEmpty
    }

    init() {
        let defaults = UserDefaults.standard
        let env = ProcessInfo.processInfo.environment

        self.kbFolderPath = defaults.string(forKey: "kbFolderPath") ?? ""
        self.selectedModel = defaults.string(forKey: "selectedModel") ?? "us.anthropic.claude-sonnet-4-6"
        self.transcriptionLocale = defaults.string(forKey: "transcriptionLocale") ?? "en-US"
        self.inputDeviceID = AudioDeviceID(defaults.integer(forKey: "inputDeviceID"))

        // AWS credentials: Keychain first, then environment variables
        self.awsAccessKeyId = KeychainHelper.load(key: "awsAccessKeyId")
            ?? env["AWS_ACCESS_KEY_ID"]
            ?? ""
        self.awsSecretAccessKey = KeychainHelper.load(key: "awsSecretAccessKey")
            ?? env["AWS_SECRET_ACCESS_KEY"]
            ?? ""
        self.awsRegion = defaults.string(forKey: "awsRegion")
            ?? env["AWS_REGION"]
            ?? env["AWS_DEFAULT_REGION"]
            ?? "us-east-1"

        // Default to true (hidden) if key has never been set
        if defaults.object(forKey: "hideFromScreenShare") == nil {
            self.hideFromScreenShare = true
        } else {
            self.hideFromScreenShare = defaults.bool(forKey: "hideFromScreenShare")
        }
    }

    /// Apply current screen-share visibility to all app windows.
    func applyScreenShareVisibility() {
        let type: NSWindow.SharingType = hideFromScreenShare ? .none : .readOnly
        for window in NSApp.windows {
            window.sharingType = type
        }
    }

    var kbFolderURL: URL? {
        guard !kbFolderPath.isEmpty else { return nil }
        return URL(fileURLWithPath: kbFolderPath)
    }

    var locale: Locale {
        Locale(identifier: transcriptionLocale)
    }
}

// MARK: - Keychain Helper

enum KeychainHelper {
    private static let service = "com.opengranola.app"

    static func save(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        delete(key: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
        ]

        SecItemAdd(query as CFDictionary, nil)
    }

    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
