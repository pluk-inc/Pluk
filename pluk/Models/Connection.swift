//
//  Connection.swift
//  Collection
//
//  Created by Fauzaan on 1/4/25.
//

import SwiftUI
import SwiftData

enum DatabaseType: String, Codable, CaseIterable, Sendable {
    var id: String { rawValue }
    
    case convex = "convex"
    case supabase = "supabase"
    // case neon = "neon"
    case postgres = "postgres"
    case mongodb = "MongoDB"
    case sqlite = "sqlite"
    case mysql = "mysql"
    case redis = "redis"
    
    var displayName: String {
        switch self {
        case .convex: return "Convex"
        case .supabase: return "Supabase"
        // case .neon: return "Neon"
        case .postgres: return "PostgreSQL"
        case .mongodb: return "MongoDB"
        case .mysql: return "MySQL"
        case .sqlite: return "SQLite"
        case .redis: return "Redis"
        }
    }
    
    var accentColor: Color {
        switch self {
        case .convex: return Color(hex: "#8D2676")
        case .supabase: return Color(hex: "#3ECF8E")
        // case .neon: return Color(hex: "#00E599")
        case .postgres: return Color(hex: "#336791")
        case .mysql: return Color(hex: "#00546B")
        case .mongodb: return Color(hex: "#00ED64")
        case .sqlite: return Color(hex: "#003B57")
        case .redis: return Color(hex: "#DC382D")
        }
    }
    
    var backgroundColor: Color {
        switch self {
        case .convex: return Color(hex: "#1E1B1A")
        case .supabase: return Color(hex: "#3ECF8E")
        // case .neon: return Color(hex: "#00E599")
        case .postgres: return Color(hex: "#346791")
        case .mysql: return Color(hex: "#00546B")
        case .mongodb: return Color(hex: "#021E2C")
        case .sqlite: return Color(hex: "#E6F0FA")
        case .redis: return Color(hex: "#A41E11")
        }
    }
    
    var icon: String {
        switch self {
        case .convex: return "convex"
        case .supabase: return "supabase"
        // case .neon: return "neon"
        case .postgres: return "postgres"
        case .mongodb: return "mongodb"
        case .mysql: return "mysql"
        case .sqlite: return "sqlite"
        case .redis: return "redis"
        }
    }
    
    var homeIcon: String {
        switch self {
        case .convex: return "convex"
        case .supabase: return "supabase"
        // case .neon: return "neon"
        case .postgres: return "postgres"
        case .mongodb: return "mongodb"
        case .mysql: return "mysql.white"
        case .sqlite: return "sqlite"
        case .redis: return "redis"
        }
    }
    
    
    var status: DatabaseStatus {
        switch self {
        case .supabase:
            return .comingSoon
        default:
            return .available
        }
    }
    
    var placeholderURI: String {
        switch self {
        case .convex:
            return "postgresql://username:password@host:5432/database"
        case .supabase:
            return "postgresql://username:password@host:5432/database"
        // case .neon:
        //     return "postgresql://username:password@host:5432/database"
        case .postgres:
            return "postgresql://username:password@localhost:5432/database"
        case .mysql:
            return "mysql://username:password@localhost:3306/database"
        case .mongodb:
            return "mongodb+srv://user:password@cluster.mongodb.net"
        case .sqlite:
            return "sqlite:///path/to/database.db"
        case .redis:
            return "redis://localhost:6379/0"
        }
    }
    
    var category: DatabaseCategory {
        switch self {
        case .convex, .supabase:
            return .platforms
        case .postgres, .mysql, .mongodb, .sqlite, .redis:
            return .database
        }
    }
    
    var dataModelType: DataModelType {
            switch self {
            case .mongodb, .redis:
                return .noSQL
            case .convex, .supabase, .postgres, .mysql, .sqlite:
                return .sql
            }
        }
    
    var supportsRealTime: Bool {
        switch self {
        case .convex:
            return true
        case .supabase, .postgres, .mysql, .sqlite, .mongodb, .redis:
            return false
        }
    }

    var supportsTableBrowser: Bool {
        self != .redis
    }

    var supportsSchemaBrowser: Bool {
        self != .redis
    }

    var supportsCanvas: Bool {
        self != .redis
    }

    var supportsNotebookAnalytics: Bool {
        self != .redis
    }

    var supportsKeyValueBrowser: Bool {
        self == .redis
    }

    var supportsCommandWorkspace: Bool {
        self == .redis || self == .postgres || self == .supabase || self == .mysql
            || self == .sqlite || self == .mongodb
    }

    var supportsDatabaseCreation: Bool {
        switch self {
        case .postgres, .mysql, .mongodb, .supabase:
            return true
        case .convex, .sqlite, .redis:
            return false
        }
    }
}

enum DatabaseCategory: String, CaseIterable, Sendable {
    case database = "Database"
    case platforms = "Platforms"
}

enum DatabaseStatus: Sendable {
    case available
    case beta
    case comingSoon
    case notConnected
}

enum ConnectionEnvironment: String, CaseIterable, Codable, Sendable {
    case local = "Local"
    case testing = "Testing"
    case development = "Development"
    case staging = "Staging"
    case production = "Production"
}

enum DataModelType: String, CaseIterable, Sendable {
    case sql = "SQL"
    case noSQL = "NoSQL"
    
    var description: String {
        switch self {
        case .sql:
            return "Structured data with predefined schema and relationships"
        case .noSQL:
            return "Flexible data models without fixed schema requirements"
        }
    }
}

enum SSHAuthMethod: String, Codable, CaseIterable, Sendable {
    case sshAgent
    case privateKey
    case password

    var displayName: String {
        switch self {
        case .sshAgent: return "SSH Agent"
        case .privateKey: return "Private Key"
        case .password: return "Password"
        }
    }
}

struct SSHConfiguration: Codable, Hashable, Sendable {
    var enabled: Bool = false
    var host: String = ""
    var port: Int?
    var username: String = ""
    var authMethod: SSHAuthMethod = .sshAgent
    var privateKeyPath: String = ""
}

@Model
final class Connection {
    var name: String
    var databaseType: DatabaseType
    var color: ConnectionColor
    var environment: ConnectionEnvironment?
    var url: String?
    var defaultDatabase: String?
    var createdAt: Date = Date()
    var lastOpenedAt: Date = Date()
    var updatedAt: Date = Date()
    
    // New individual connection fields (optional for backward compatibility)
    var hostname: String?
    var port: String?
    var username: String?
    var sslMode: String?
    var sslKeyPath: String?
    var sslCertPath: String?
    var sslRootCertPath: String?
    
    // Stable identifier for keychain storage (persists across app restarts)
    var keychainId: String = UUID().uuidString

    var containerName: String?
    var containerId: String?

    var sshEnabled: Bool = false
    var sshHost: String?
    var sshPort: String?
    var sshUsername: String?
    var sshAuthMethodRawValue: String = SSHAuthMethod.sshAgent.rawValue
    var sshPrivateKeyPath: String?
    
    // Password is stored in keychain, not in database
    var password: String? {
        get {
            return KeychainHelper.shared.retrieve(for: keychainId)
        }
        set {
            if let newPassword = newValue, !newPassword.isEmpty {
                KeychainHelper.shared.store(password: newPassword, for: keychainId)
            } else {
                KeychainHelper.shared.delete(for: keychainId)
            }
        }
    }

    var sshAuthMethod: SSHAuthMethod {
        get {
            SSHAuthMethod(rawValue: sshAuthMethodRawValue) ?? .sshAgent
        }
        set {
            sshAuthMethodRawValue = newValue.rawValue
        }
    }

    var sshPassword: String? {
        get {
            KeychainHelper.shared.retrieve(for: sshPasswordKeychainId)
        }
        set {
            if let newPassword = newValue, !newPassword.isEmpty {
                KeychainHelper.shared.store(password: newPassword, for: sshPasswordKeychainId)
            } else {
                KeychainHelper.shared.delete(for: sshPasswordKeychainId)
            }
        }
    }

    var sshKeyPassphrase: String? {
        get {
            KeychainHelper.shared.retrieve(for: sshKeyPassphraseKeychainId)
        }
        set {
            if let newPassphrase = newValue, !newPassphrase.isEmpty {
                KeychainHelper.shared.store(password: newPassphrase, for: sshKeyPassphraseKeychainId)
            } else {
                KeychainHelper.shared.delete(for: sshKeyPassphraseKeychainId)
            }
        }
    }
    
    init(databaseType: DatabaseType, url: String, name: String, color: ConnectionColor, environment: ConnectionEnvironment, defaultDatabase: String? = nil) {
        self.name = name
        self.databaseType = databaseType
        self.url = url
        self.color = color
        self.environment = environment
        self.defaultDatabase = defaultDatabase
    }
    
    init(databaseType: DatabaseType, name: String, color: ConnectionColor, environment: ConnectionEnvironment?, hostname: String, port: String, username: String, database: String? = nil, sslMode: String? = "prefer", sslKeyPath: String? = nil, sslCertPath: String? = nil, sslRootCertPath: String? = nil) {
        self.name = name
        self.databaseType = databaseType
        self.color = color
        self.environment = environment
        self.defaultDatabase = database
        self.hostname = hostname
        self.port = port
        self.username = username
        self.sslMode = sslMode
        self.sslKeyPath = sslKeyPath
        self.sslCertPath = sslCertPath
        self.sslRootCertPath = sslRootCertPath
        self.url = nil
    }
    
    var connectionUri: String {
        if databaseType == .convex {
            return password ?? ""
        }
        // If we have individual fields, construct URI from them (new approach)
        if canConstructURIFromFields {
            return constructURIFromFields()
        }
        
        // Fallback to legacy URI construction (backward compatibility)
        if databaseType == .redis {
            return url ?? ""
        } else if let database = defaultDatabase, !database.isEmpty {
            return "\(url ?? "")/\(database)"
        } else {
            return url ?? ""
        }
    }

    private func constructURIFromFields(encodeCredentials: Bool = true) -> String {
        guard let hostname, let port else {
            return url ?? ""
        }

        if databaseType == .redis {
            let databaseIndex = Int(defaultDatabase ?? "0") ?? 0
            return (try? ConnectionURLParser.makeRedisURL(
                hostname: hostname,
                port: Int(port) ?? 6379,
                username: username,
                password: password,
                databaseIndex: databaseIndex,
                usesTLS: redisUsesTLS
            )) ?? (url ?? "")
        }

        guard let username else {
            return url ?? ""
        }

        let scheme: String
        switch databaseType {
        case .postgres, .supabase, .convex, .sqlite:
            scheme = "postgresql"
        case .mysql:
            scheme = "mysql"
        case .mongodb:
            scheme = "mongodb"
        case .redis:
            scheme = redisUsesTLS ? "rediss" : "redis"
        }

        let resolvedHost = hostname.isEmpty ? "localhost" : hostname
        let resolvedPort = Int(port) ?? (databaseType == .mysql ? 3306 : 5432)

        var uri = "\(scheme)://"
        if !username.isEmpty {
            if encodeCredentials {
                uri += username.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? username
            } else {
                uri += username
            }
            if let pwd = password, !pwd.isEmpty {
                if encodeCredentials {
                    uri += ":\(pwd.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? pwd)"
                } else {
                    uri += ":\(pwd)"
                }
            }
            uri += "@"
        }

        uri += "\(resolvedHost):\(resolvedPort)"

        if let database = defaultDatabase, !database.isEmpty {
            let encodedDatabase = database.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? database
            uri += "/\(encodeCredentials ? encodedDatabase : database)"
        }

        if databaseType == .postgres || databaseType == .supabase || databaseType == .convex {
            var queryItems: [URLQueryItem] = []

            if let sslMode {
                queryItems.append(URLQueryItem(name: "sslmode", value: sslMode))
            }

            if databaseType == .postgres || databaseType == .supabase {
                if let sslKeyPath, !sslKeyPath.isEmpty {
                    queryItems.append(URLQueryItem(name: "sslkey", value: sslKeyPath))
                }
                if let sslCertPath, !sslCertPath.isEmpty {
                    queryItems.append(URLQueryItem(name: "sslcert", value: sslCertPath))
                }
                if let sslRootCertPath, !sslRootCertPath.isEmpty {
                    queryItems.append(URLQueryItem(name: "sslrootcert", value: sslRootCertPath))
                }
            }

            if !queryItems.isEmpty {
                var queryComponents = URLComponents()
                queryComponents.queryItems = queryItems
                if let query = queryComponents.percentEncodedQuery {
                    uri += "?\(query)"
                }
            }
        }

        return uri
    }

    /// Returns a readable connection URI for display/copy purposes (no percent-encoding)
    var copyableConnectionUri: String {
        if databaseType == .convex {
            return password ?? ""
        }
        if canConstructURIFromFields {
            return constructURIFromFields(encodeCredentials: false)
        }
        return url ?? ""
    }
    
    // Helper method to check if connection uses new field-based approach
    var usesFieldBasedConnection: Bool {
        guard hostname != nil, port != nil else { return false }
        return databaseType == .redis || username != nil
    }
    
    // Helper method to check if password exists in keychain
    var hasPassword: Bool {
        return KeychainHelper.shared.passwordExists(for: keychainId)
    }

    var sshConfiguration: SSHConfiguration? {
        guard sshEnabled else { return nil }
        let trimmedHost = (sshHost ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else { return nil }

        let trimmedPort = (sshPort ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedPort = trimmedPort.isEmpty ? nil : Int(trimmedPort)

        return SSHConfiguration(
            enabled: true,
            host: trimmedHost,
            port: parsedPort,
            username: (sshUsername ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            authMethod: sshAuthMethod,
            privateKeyPath: (sshPrivateKeyPath ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
    
    var displayUrl: String? {
        if databaseType == .convex {
            return nil
        }
        
        // If we have individual fields, construct display URL from them
        if canConstructURIFromFields {
            return constructDisplayURLFromFields()
        }
        
        // Special handling for SQLite bookmark URLs
        if databaseType == .sqlite, let url = url, !url.isEmpty {
            return extractSQLiteFilePath(from: url)
        }
        
        // Fallback to sanitizing existing URL (backward compatibility)
        if let url = url, !url.isEmpty {
            return sanitizeURLForDisplay(url)
        }
        
        return nil
    }
    
    private func constructDisplayURLFromFields() -> String {
        guard let hostname, let port else {
            return "Invalid connection"
        }

        let resolvedUsername = username ?? ""

        if databaseType == .redis {
            let databaseIndex = Int(defaultDatabase ?? "0") ?? 0
            return (try? ConnectionURLParser.makeRedisURL(
                hostname: hostname,
                port: Int(port) ?? 6379,
                username: resolvedUsername,
                password: hasPassword ? "****" : nil,
                databaseIndex: databaseIndex,
                usesTLS: redisUsesTLS
            )) ?? "\(hostname):\(port)"
        }
        
        var components = URLComponents()
        
        switch databaseType {
        case .postgres, .supabase, .convex:
            components.scheme = "postgresql"
        case .mysql:
            components.scheme = "mysql"
        case .sqlite:
            components.scheme = "sqlLite"
        case .mongodb:
            components.scheme = "mongodb"
        case .redis:
            components.scheme = redisUsesTLS ? "rediss" : "redis"
        }
        
        components.host = hostname
        components.port = Int(port)
        components.user = resolvedUsername
        
        // Show asterisks if password exists in keychain
        if hasPassword {
            components.password = "****"
        }
        
        // Add database path
        if let database = defaultDatabase, !database.isEmpty {
            components.path = "/\(database)"
        }
        
        return components.url?.absoluteString ?? "\(hostname):\(port)"
    }
    
    private func extractSQLiteFilePath(from url: String) -> String {
        // Check if this is a security-scoped bookmark URL
        if url.hasPrefix("bookmark:") {
            // Try to decode the bookmark to get the original file path
            let bookmarkString = String(url.dropFirst(9)) // Remove "bookmark:"
            let components = bookmarkString.components(separatedBy: "|")
            
            if components.count >= 2 {
                let encryptedPath = components[1]
                // Decrypt the path (matching BookmarkManager logic)
                if let decryptedPath = decryptPath(encryptedPath) {
                    return decryptedPath
                }
            }
        }
        
        // Handle other SQLite URL formats
        if url.hasPrefix("sqlite://") {
            let path = String(url.dropFirst(9)) // Remove "sqlite://"
            return path.isEmpty ? ":memory:" : path
        } else if url.hasPrefix("file:") {
            return String(url.dropFirst(5)) // Remove "file:"
        }
        
        // Return the original URL if we can't parse it
        return url
    }
    
    private func decryptPath(_ encryptedPath: String) -> String? {
        guard let data = Data(base64Encoded: encryptedPath),
              let saltedPath = String(data: data, encoding: .utf8) else {
            return nil
        }
        
        let salt = "PlukSecureBookmark2025"
        if saltedPath.hasPrefix(salt) && saltedPath.hasSuffix(salt) {
            let startIndex = saltedPath.index(saltedPath.startIndex, offsetBy: salt.count)
            let endIndex = saltedPath.index(saltedPath.endIndex, offsetBy: -salt.count)
            return String(saltedPath[startIndex..<endIndex])
        }
        
        return nil
    }
    
    private func sanitizeURLForDisplay(_ url: String) -> String {
        guard let urlComponents = URLComponents(string: url) else {
            return url // Return original if parsing fails
        }
        
        var sanitizedComponents = urlComponents
        
        // Replace password with asterisks if it exists
        if urlComponents.password != nil {
            sanitizedComponents.password = "****"
        }
        
        return sanitizedComponents.url?.absoluteString ?? url
    }
    
    // Clean up keychain when connection is deleted
    func cleanupKeychain() {
        KeychainHelper.shared.delete(for: keychainId)
        KeychainHelper.shared.delete(for: sshPasswordKeychainId)
        KeychainHelper.shared.delete(for: sshKeyPassphraseKeychainId)
    }
    
    // Helper method to populate fields from existing URL (for migration)
    func populateFieldsFromURL() {
        if databaseType == .redis,
           let storedURL = url,
           let parsed = try? ConnectionURLParser.parseRedis(storedURL) {
            hostname = parsed.hostname
            port = String(parsed.port)
            username = parsed.username ?? ""
            password = parsed.password
            defaultDatabase = String(parsed.databaseIndex)
            sslMode = parsed.usesTLS ? "require" : "disable"
            // Redis credentials must not remain embedded in SwiftData.
            url = nil
            return
        }

        guard let urlComponents = URLComponents(string: url ?? "") else { return }
        
        self.hostname = urlComponents.host
        self.port = urlComponents.port?.description
        self.username = urlComponents.user
        self.password = urlComponents.password
        
        // Parse database from path
        let path = urlComponents.path
        if !path.isEmpty && path != "/" {
            self.defaultDatabase = String(path.dropFirst()) // Remove leading "/"
        }
        
        // Parse SSL mode from query parameters (for PostgreSQL)
        if databaseType == .postgres || databaseType == .supabase || databaseType == .convex {
            if let queryItems = urlComponents.queryItems {
                for item in queryItems {
                    if item.name.lowercased() == "sslmode" {
                        self.sslMode = item.value ?? "prefer"
                        break
                    }
                }
            }
            if sslMode == nil {
                sslMode = "prefer" // Default value
            }
        }
    }

    private var sshPasswordKeychainId: String {
        "\(keychainId).ssh.password"
    }

    private var sshKeyPassphraseKeychainId: String {
        "\(keychainId).ssh.keyPassphrase"
    }

    private var canConstructURIFromFields: Bool {
        guard let hostname, !hostname.isEmpty,
              let port, !port.isEmpty else {
            return false
        }
        return databaseType == .redis || !(username ?? "").isEmpty
    }

    private var redisUsesTLS: Bool {
        switch sslMode?.lowercased() {
        case "require", "verify-ca", "verify-full":
            return true
        default:
            return false
        }
    }
}
