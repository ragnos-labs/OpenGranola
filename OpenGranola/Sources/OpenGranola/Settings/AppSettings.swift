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

    /// Whether AWS credentials are configured (Infisical or Keychain).
    var hasAWSCredentials: Bool {
        !awsAccessKeyId.isEmpty && !awsSecretAccessKey.isEmpty
    }

    init() {
        let defaults = UserDefaults.standard
        let infisical = InfisicalLoader.load()

        self.kbFolderPath = defaults.string(forKey: "kbFolderPath") ?? ""
        self.selectedModel = defaults.string(forKey: "selectedModel") ?? "us.anthropic.claude-sonnet-4-6"
        self.transcriptionLocale = defaults.string(forKey: "transcriptionLocale") ?? "en-US"
        self.inputDeviceID = AudioDeviceID(defaults.integer(forKey: "inputDeviceID"))

        // AWS credentials: Keychain first, then Infisical env file
        self.awsAccessKeyId = KeychainHelper.load(key: "awsAccessKeyId")
            ?? infisical["AWS_ACCESS_KEY_ID"]
            ?? ""
        self.awsSecretAccessKey = KeychainHelper.load(key: "awsSecretAccessKey")
            ?? infisical["AWS_SECRET_ACCESS_KEY"]
            ?? ""
        self.awsRegion = defaults.string(forKey: "awsRegion")
            ?? infisical["AWS_REGION"]
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

// MARK: - Infisical Loader

/// Reads secrets from ~/.infisical/ragnos.env (format: export KEY='value').
enum InfisicalLoader {
    private static let envPath = NSHomeDirectory() + "/.infisical/ragnos.env"

    /// Parse the env file and return a dictionary of key-value pairs.
    static func load() -> [String: String] {
        guard let contents = try? String(contentsOfFile: envPath, encoding: .utf8) else {
            return [:]
        }

        var result: [String: String] = [:]
        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Skip comments and empty lines
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

            // Strip optional "export " prefix
            let stripped = trimmed.hasPrefix("export ")
                ? String(trimmed.dropFirst(7))
                : trimmed

            // Split on first "="
            guard let eqIndex = stripped.firstIndex(of: "=") else { continue }
            let key = String(stripped[stripped.startIndex..<eqIndex])
                .trimmingCharacters(in: .whitespaces)
            var value = String(stripped[stripped.index(after: eqIndex)...])
                .trimmingCharacters(in: .whitespaces)

            // Remove surrounding quotes
            if (value.hasPrefix("'") && value.hasSuffix("'")) ||
               (value.hasPrefix("\"") && value.hasSuffix("\"")) {
                value = String(value.dropFirst().dropLast())
            }

            result[key] = value
        }
        return result
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
