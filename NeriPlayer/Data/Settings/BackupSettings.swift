// BackupSettings.swift
// M7: explicit settings allowlist; secrets, sync credentials and crash markers never enter backups.

import Foundation

extension SettingsStore {
    private static var backupStrings: [SettingsKey<String>] {
        [SettingsKeys.appAppearance, SettingsKeys.accentColor, SettingsKeys.lastSelectedTab]
    }
    private static var backupBooleans: [SettingsKey<Bool>] {
        [SettingsKeys.resumePlaybackOnLaunch, SettingsKeys.lyricsBlur, SettingsKeys.lyricsTranslation, SettingsKeys.lyricsPhonetic]
    }
    private static var backupNumbers: [SettingsKey<Double>] { [SettingsKeys.defaultVolume, SettingsKeys.lyricsFontSize] }
    private static var backupData: [SettingsKey<Data>] {
        [SettingsKeys.libraryDirectories, SettingsKeys.lyricsAssociations, SettingsKeys.lyricsOffsets, SettingsKeys.audioEffects]
    }
    func backupSettings() -> SyncRecord {
        var record = SyncRecord()
        for key in Self.backupStrings { record.set(key.name, value(for: key)) }
        for key in Self.backupBooleans { record.set(key.name, value(for: key)) }
        for key in Self.backupNumbers { record.set(key.name, String(value(for: key))) }
        for key in Self.backupData { record.set(key.name, value(for: key).base64EncodedString()) }
        return record
    }
    func validateBackupSettings(_ record: SyncRecord) throws {
        let keys = Set(Self.backupStrings.map(\.name) + Self.backupBooleans.map(\.name) +
                       Self.backupNumbers.map(\.name) + Self.backupData.map(\.name))
        guard Set(record.fields.keys).isSubset(of: keys) else { throw SyncError.invalidBackup }
        for key in Self.backupStrings where record.fields[key.name] != nil {
            guard case .string = record.fields[key.name] else { throw SyncError.invalidBackup }
        }
        for key in Self.backupBooleans where record.fields[key.name] != nil {
            guard case .bool = record.fields[key.name] else { throw SyncError.invalidBackup }
        }
        for key in Self.backupNumbers where record.fields[key.name] != nil {
            guard let value = Double(record.text(key.name)), value.isFinite else { throw SyncError.invalidBackup }
        }
        for key in Self.backupData where record.fields[key.name] != nil {
            guard Data(base64Encoded: record.text(key.name)) != nil else { throw SyncError.invalidBackup }
        }
    }
    func restoreBackupSettings(_ record: SyncRecord) {
        for key in Self.backupStrings where record.fields[key.name] != nil { set(record.text(key.name), for: key) }
        for key in Self.backupBooleans where record.fields[key.name] != nil { set(record.flag(key.name), for: key) }
        for key in Self.backupNumbers {
            if let value = Double(record.text(key.name)) { set(value, for: key) }
        }
        for key in Self.backupData {
            if let data = Data(base64Encoded: record.text(key.name)) { set(data, for: key) }
        }
    }
}

public struct SyncConfiguration: Codable, Equatable, Sendable {
    public enum Provider: String, Codable, CaseIterable, Sendable { case github, webdav }
    public var provider: Provider = .github
    public var githubOwner = ""
    public var githubRepository = "NeriPlayer-Backup"
    public var webDAVURL = ""
    public var webDAVUsername = ""
    public init() {}
}

public final class SyncConfigurationStore: @unchecked Sendable {
    private let settings: SettingsStore
    private let credentials: any OnlineCredentialStore
    private let key = SettingsKey<Data>("metadataSyncConfiguration", default: Data())
    public init(settings: SettingsStore = .shared,
                credentials: any OnlineCredentialStore = KeychainCredentialStore(service: "moe.ouom.NeriPlayer.sync")) {
        self.settings = settings; self.credentials = credentials
    }
    public func load() -> SyncConfiguration {
        (try? JSONDecoder().decode(SyncConfiguration.self, from: settings.value(for: key))) ?? SyncConfiguration()
    }
    public func save(_ configuration: SyncConfiguration, secret: String) throws {
        // Persist the secret first, so a Keychain failure cannot replace a working configuration.
        if !secret.isEmpty { try credentials.write(Data(secret.utf8), account: configuration.provider.rawValue) }
        settings.set(try JSONEncoder().encode(configuration), for: key)
    }
    public func transport(for configuration: SyncConfiguration, http: SyncHTTP = SyncHTTP()) throws -> any SyncTransport {
        guard let data = try credentials.read(account: configuration.provider.rawValue),
              let secret = String(data: data, encoding: .utf8), !secret.isEmpty else { throw SyncError.invalidConfiguration }
        switch configuration.provider {
        case .github:
            return try GitHubSyncTransport(owner: configuration.githubOwner, repository: configuration.githubRepository, token: secret, http: http)
        case .webdav:
            guard let url = URL(string: configuration.webDAVURL) else { throw SyncError.invalidConfiguration }
            return try WebDAVSyncTransport(url: url, username: configuration.webDAVUsername, password: secret, http: http)
        }
    }
}
