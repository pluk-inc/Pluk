//
//  ConnectionURLParser.swift
//  Pluk
//
//  URL parsing logic based on Vapor's MySQLKit and PostgresKit implementations.
//  Uses URLComponents which automatically handles percent-decoding of credentials.
//

import Foundation

enum ConnectionURLParserError: Error, LocalizedError, Equatable, Sendable {
    case invalidURL
    case missingScheme
    case unsupportedScheme(String)
    case missingHost
    case missingUsername
    case missingPassword
    case invalidPort(Int)
    case invalidDatabaseIndex(String)
    case invalidSSLMode(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid connection URL format"
        case .missingScheme:
            return "Connection URL must include a scheme (e.g., mysql://, postgresql://)"
        case .unsupportedScheme(let scheme):
            return "Unsupported URL scheme: \(scheme)"
        case .missingHost:
            return "Connection URL must include a hostname"
        case .missingUsername:
            return "Connection URL must include a username"
        case .missingPassword:
            return "Redis ACL authentication requires a password"
        case .invalidPort(let port):
            return "Connection URL contains an invalid port: \(port)"
        case .invalidDatabaseIndex(let index):
            return "Redis database index must be a non-negative integer: \(index)"
        case .invalidSSLMode(let mode):
            return "Invalid SSL mode: \(mode)"
        }
    }
}

struct ParsedConnectionURL {
    let scheme: String
    let hostname: String
    let port: Int
    let username: String
    let password: String?
    let database: String?
    let sslMode: SSLMode
    let isUnixSocket: Bool
    let unixSocketPath: String?

    enum SSLMode: String {
        case disable
        case allow
        case prefer
        case require
        case verifyCa = "verify-ca"
        case verifyFull = "verify-full"

        var postgresValue: String {
            rawValue
        }

        var mysqlValue: String {
            switch self {
            case .disable: return "DISABLED"
            case .allow, .prefer: return "PREFERRED"
            case .require, .verifyCa, .verifyFull: return "REQUIRED"
            }
        }
    }
}

struct ParsedRedisConnectionURL: Equatable, Sendable {
    let hostname: String
    let port: Int
    let username: String?
    let password: String?
    let databaseIndex: Int
    let usesTLS: Bool

    var scheme: String {
        usesTLS ? "rediss" : "redis"
    }
}

struct ConnectionURLParser {

    // MARK: - Redis Parsing

    static func parseRedis(_ urlString: String) throws -> ParsedRedisConnectionURL {
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty,
              let components = URLComponents(string: trimmedURL) else {
            throw ConnectionURLParserError.invalidURL
        }

        guard let scheme = components.scheme?.lowercased(), !scheme.isEmpty else {
            throw ConnectionURLParserError.missingScheme
        }
        guard scheme == "redis" || scheme == "rediss" else {
            throw ConnectionURLParserError.unsupportedScheme(scheme)
        }
        guard let parsedHostname = components.host, !parsedHostname.isEmpty else {
            throw ConnectionURLParserError.missingHost
        }
        let hostname = normalizedParsedRedisHost(parsedHostname)

        let port = components.port ?? 6379
        guard (1...65_535).contains(port) else {
            throw ConnectionURLParserError.invalidPort(port)
        }

        let databaseIndex = try parseRedisDatabaseIndex(from: components.path)
        let username = components.user.flatMap { $0.isEmpty ? nil : $0 }
        let password = components.password.flatMap { $0.isEmpty ? nil : $0 }
        guard username == nil || password != nil else {
            throw ConnectionURLParserError.missingPassword
        }

        return ParsedRedisConnectionURL(
            hostname: hostname,
            port: port,
            username: username,
            password: password,
            databaseIndex: databaseIndex,
            usesTLS: scheme == "rediss"
        )
    }

    static func makeRedisURL(
        hostname: String,
        port: Int = 6379,
        username: String? = nil,
        password: String? = nil,
        databaseIndex: Int = 0,
        usesTLS: Bool = false
    ) throws -> String {
        let trimmedHost = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            throw ConnectionURLParserError.missingHost
        }
        guard (1...65_535).contains(port) else {
            throw ConnectionURLParserError.invalidPort(port)
        }
        guard databaseIndex >= 0 else {
            throw ConnectionURLParserError.invalidDatabaseIndex(String(databaseIndex))
        }

        var components = URLComponents()
        components.scheme = usesTLS ? "rediss" : "redis"
        components.host = normalizedHostForURLComponents(trimmedHost)
        components.port = port

        let normalizedUsername = username?.isEmpty == false ? username : nil
        let normalizedPassword = password?.isEmpty == false ? password : nil
        guard normalizedUsername == nil || normalizedPassword != nil else {
            throw ConnectionURLParserError.missingPassword
        }
        if let normalizedUsername {
            components.user = normalizedUsername
        } else if normalizedPassword != nil {
            // Redis URI password-only authentication is represented as
            // redis://:password@host, with an intentionally empty username.
            components.user = ""
        }
        components.password = normalizedPassword
        components.path = "/\(databaseIndex)"

        guard let result = components.string else {
            throw ConnectionURLParserError.invalidURL
        }
        return result
    }

    // MARK: - MySQL Parsing (based on vapor/mysql-kit)

    static func parseMySQL(_ urlString: String) throws -> ParsedConnectionURL {
        guard let url = URL(string: urlString) else {
            throw ConnectionURLParserError.invalidURL
        }
        return try parseMySQL(url)
    }

    static func parseMySQL(_ url: URL) throws -> ParsedConnectionURL {
        guard let comp = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            throw ConnectionURLParserError.invalidURL
        }

        // URLComponents.user and .password automatically decode percent-encoded values
        guard let username = comp.user else {
            throw ConnectionURLParserError.missingUsername
        }

        let scheme = comp.scheme?.lowercased() ?? "mysql"

        switch scheme {
        case "mysql", "mysql+tcp":
            guard let hostname = comp.host, !hostname.isEmpty else {
                throw ConnectionURLParserError.missingHost
            }

            let sslMode = try parseSSLMode(
                from: comp.queryItems ?? [],
                defaultMode: "require"
            )

            let database = extractDatabase(from: url)

            return ParsedConnectionURL(
                scheme: "mysql",
                hostname: hostname,
                port: comp.port ?? 3306,
                username: username,
                password: comp.password,
                database: database,
                sslMode: sslMode,
                isUnixSocket: false,
                unixSocketPath: nil
            )

        case "mysql+uds":
            // Unix domain socket
            guard (comp.host?.isEmpty ?? true || comp.host == "localhost"),
                  comp.port == nil,
                  !comp.path.isEmpty,
                  comp.path != "/" else {
                throw ConnectionURLParserError.invalidURL
            }

            let sslMode = try parseSSLMode(
                from: comp.queryItems ?? [],
                defaultMode: "disable"
            )

            return ParsedConnectionURL(
                scheme: "mysql",
                hostname: "localhost",
                port: 3306,
                username: username,
                password: comp.password,
                database: comp.fragment,
                sslMode: sslMode,
                isUnixSocket: true,
                unixSocketPath: comp.path
            )

        default:
            throw ConnectionURLParserError.unsupportedScheme(scheme)
        }
    }

    // MARK: - Helpers

    private static func parseRedisDatabaseIndex(from path: String) throws -> Int {
        guard !path.isEmpty, path != "/" else {
            return 0
        }

        let indexString = String(path.dropFirst())
        guard !indexString.isEmpty,
              indexString.utf8.allSatisfy({ (48...57).contains($0) }),
              let databaseIndex = Int(indexString) else {
            throw ConnectionURLParserError.invalidDatabaseIndex(indexString)
        }
        return databaseIndex
    }

    private static func normalizedHostForURLComponents(_ hostname: String) -> String {
        guard hostname.contains(":"),
              !(hostname.hasPrefix("[") && hostname.hasSuffix("]")) else {
            return hostname
        }
        return "[\(hostname)]"
    }

    private static func normalizedParsedRedisHost(_ hostname: String) -> String {
        guard hostname.hasPrefix("["), hostname.hasSuffix("]") else {
            return hostname
        }
        return String(hostname.dropFirst().dropLast())
    }

    private static func parseSSLMode(
        from queryItems: [URLQueryItem],
        defaultMode: String
    ) throws -> ParsedConnectionURL.SSLMode {
        let sslKeys = ["ssl-mode", "sslmode", "tls-mode", "tlsmode", "ssl", "tls"]

        let modeString = queryItems
            .last { sslKeys.contains($0.name.lowercased()) }?
            .value ?? defaultMode

        switch modeString.lowercased() {
        case "disable", "disabled", "false":
            return .disable
        case "allow":
            return .allow
        case "prefer", "preferred", "true":
            return .prefer
        case "require", "required":
            return .require
        case "verify-ca", "verify_ca":
            return .verifyCa
        case "verify-full", "verify_full", "verify-identity":
            return .verifyFull
        default:
            throw ConnectionURLParserError.invalidSSLMode(modeString)
        }
    }

    private static func extractDatabase(from url: URL) -> String? {
        let path = url.lastPathComponent
        guard !path.isEmpty, path != "/" else {
            return nil
        }
        return path
    }
}
