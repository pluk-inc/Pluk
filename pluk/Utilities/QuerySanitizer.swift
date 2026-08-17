//
//  QuerySanitizer.swift
//  Pluk
//
//  Created by Claude on 1/23/26.
//

import Foundation

struct QuerySanitizer {
    struct SanitizationResult: Equatable, Sendable {
        let sanitizedQuery: String
        let wasSanitized: Bool
    }

    private static let patterns: [(pattern: String, replacement: String)] = [
        // Connection string passwords (various formats)
        (#"(://[^:]+:)[^@]+(@)"#, "$1[REDACTED]$2"),
        (#"(password\s*[=:]\s*)['\"]?[^'\";\s]+['\"]?"#, "$1[REDACTED]"),
        (#"(pwd\s*[=:]\s*)['\"]?[^'\";\s]+['\"]?"#, "$1[REDACTED]"),

        // API keys and tokens
        (#"(api[_-]?key\s*[=:]\s*)['\"]?[a-zA-Z0-9_\-]{16,}['\"]?"#, "$1[REDACTED]"),
        (#"(token\s*[=:]\s*)['\"]?[a-zA-Z0-9_\-\.]{16,}['\"]?"#, "$1[REDACTED]"),
        (#"(secret\s*[=:]\s*)['\"]?[a-zA-Z0-9_\-]{8,}['\"]?"#, "$1[REDACTED]"),
        (#"(bearer\s+)[a-zA-Z0-9_\-\.]+\b"#, "$1[REDACTED]"),

        // AWS credentials
        (#"(AKIA)[A-Z0-9]{16}"#, "[REDACTED_AWS_KEY]"),
        (#"(aws_secret_access_key\s*[=:]\s*)['\"]?[a-zA-Z0-9/+=]{40}['\"]?"#, "$1[REDACTED]"),
        (#"(aws_access_key_id\s*[=:]\s*)['\"]?[A-Z0-9]{20}['\"]?"#, "$1[REDACTED]"),

        // Credit card patterns (basic)
        (#"\b\d{4}[\s\-]?\d{4}[\s\-]?\d{4}[\s\-]?\d{4}\b"#, "[REDACTED_CC]"),

        // SSN patterns
        (#"\b\d{3}[\s\-]?\d{2}[\s\-]?\d{4}\b"#, "[REDACTED_SSN]"),

        // Private keys
        (#"-----BEGIN\s+(?:RSA\s+)?PRIVATE\s+KEY-----[\s\S]*?-----END\s+(?:RSA\s+)?PRIVATE\s+KEY-----"#, "[REDACTED_PRIVATE_KEY]"),

        // JWT tokens
        (#"\beyJ[a-zA-Z0-9_\-]*\.eyJ[a-zA-Z0-9_\-]*\.[a-zA-Z0-9_\-]*\b"#, "[REDACTED_JWT]"),

        // Generic secrets in SQL values
        (#"(INSERT\s+INTO\s+\S+\s*\([^)]*(?:password|secret|token|api_key|credentials)[^)]*\)\s*VALUES\s*\()[^)]*(\))"#, "$1[REDACTED]$2"),
        (#"(UPDATE\s+\S+\s+SET\s+(?:password|secret|token|api_key|credentials)\s*=\s*)['\"][^'\"]+['\"]"#, "$1'[REDACTED]'"),
    ]

    private static let sensitiveColumnPatterns = [
        "password", "passwd", "pwd", "secret", "token", "api_key", "apikey",
        "access_key", "private_key", "credential", "auth", "ssn", "credit_card",
        "card_number", "cvv", "pin"
    ]

    static func sanitize(_ query: String) -> SanitizationResult {
        let redisRedaction = RedisCommandHistoryRedactor.redactIfNeeded(in: query)
        var sanitizedQuery = redisRedaction?.sanitizedCommand ?? query
        var wasSanitized = redisRedaction?.wasRedacted ?? false

        for (pattern, replacement) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(sanitizedQuery.startIndex..., in: sanitizedQuery)
                let modifiedQuery = regex.stringByReplacingMatches(
                    in: sanitizedQuery,
                    options: [],
                    range: range,
                    withTemplate: replacement
                )

                if modifiedQuery != sanitizedQuery {
                    sanitizedQuery = modifiedQuery
                    wasSanitized = true
                }
            }
        }

        return SanitizationResult(sanitizedQuery: sanitizedQuery, wasSanitized: wasSanitized)
    }

    static func containsSensitiveColumnName(_ query: String) -> Bool {
        let lowercasedQuery = query.lowercased()
        return sensitiveColumnPatterns.contains { pattern in
            lowercasedQuery.localizedStandardContains(pattern)
        }
    }

    static func detectQueryType(from query: String) -> QueryType {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        if trimmedQuery.hasPrefix("SELECT") || trimmedQuery.hasPrefix("WITH") {
            return .select
        } else if trimmedQuery.hasPrefix("INSERT") {
            return .insert
        } else if trimmedQuery.hasPrefix("UPDATE") {
            return .update
        } else if trimmedQuery.hasPrefix("DELETE") {
            return .delete
        } else if trimmedQuery.hasPrefix("CREATE") || trimmedQuery.hasPrefix("ALTER") ||
                  trimmedQuery.hasPrefix("DROP") || trimmedQuery.hasPrefix("TRUNCATE") {
            return .ddl
        } else {
            return .raw
        }
    }

    static func extractTableName(from query: String) -> String? {
        let patterns = [
            #"(?:FROM|INTO|UPDATE|TABLE)\s+[`\"']?(\w+)[`\"']?"#,
            #"(?:JOIN)\s+[`\"']?(\w+)[`\"']?"#
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
               let match = regex.firstMatch(in: query, options: [], range: NSRange(query.startIndex..., in: query)),
               let range = Range(match.range(at: 1), in: query) {
                return String(query[range])
            }
        }

        return nil
    }
}
