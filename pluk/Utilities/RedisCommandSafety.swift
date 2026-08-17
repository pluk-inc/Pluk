//
//  RedisCommandSafety.swift
//  Pluk
//
//  Redis command parsing, classification, and history redaction.
//

import Foundation

struct RedisCommandToken: Equatable, Hashable, Sendable {
    let bytes: [UInt8]

    init(_ value: String) {
        self.bytes = Array(value.utf8)
    }

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    var stringValue: String? {
        String(bytes: bytes, encoding: .utf8)
    }

    fileprivate var uppercasedASCIIValue: String? {
        guard !bytes.isEmpty,
              bytes.allSatisfy({ $0 >= 0x21 && $0 <= 0x7E }) else {
            return nil
        }

        return String(
            bytes: bytes.map { byte in
                guard byte >= CharacterByte.lowercaseA && byte <= CharacterByte.lowercaseZ else {
                    return byte
                }
                return byte - CharacterByte.asciiCaseOffset
            },
            encoding: .ascii
        )
    }

    fileprivate func equalsIgnoringASCIICase(_ value: String) -> Bool {
        uppercasedASCIIValue == value.uppercased()
    }

    fileprivate var historyRepresentation: String {
        guard !bytes.isEmpty else { return "\"\"" }

        if bytes.allSatisfy(Self.isSafeUnquotedByte) {
            return String(decoding: bytes, as: UTF8.self)
        }

        if let stringValue {
            var result = "\""
            for scalar in stringValue.unicodeScalars {
                switch scalar.value {
                case 0x07: result += "\\a"
                case 0x08: result += "\\b"
                case 0x09: result += "\\t"
                case 0x0A: result += "\\n"
                case 0x0D: result += "\\r"
                case 0x22: result += "\\\""
                case 0x5C: result += "\\\\"
                case 0x00...0x1F, 0x7F:
                    for byte in String(scalar).utf8 {
                        result += String(format: "\\x%02X", byte)
                    }
                default:
                    result.unicodeScalars.append(scalar)
                }
            }
            result += "\""
            return result
        }

        let escaped = bytes.map { String(format: "\\x%02X", $0) }.joined()
        return "\"\(escaped)\""
    }

    private static func isSafeUnquotedByte(_ byte: UInt8) -> Bool {
        byte >= 0x21 && byte <= 0x7E && byte != CharacterByte.doubleQuote &&
            byte != CharacterByte.singleQuote && byte != CharacterByte.backslash
    }
}

struct ParsedRedisCommand: Equatable, Sendable {
    let arguments: [RedisCommandToken]

    init(arguments: [RedisCommandToken]) throws {
        guard let first = arguments.first else {
            throw RedisCommandTokenizerError.emptyCommand
        }
        guard first.uppercasedASCIIValue != nil else {
            throw RedisCommandTokenizerError.invalidCommandName
        }
        self.arguments = arguments
    }

    var name: String {
        // The initializer guarantees an ASCII command name.
        arguments[0].uppercasedASCIIValue!
    }

    var renderedForHistory: String {
        arguments.map(\.historyRepresentation).joined(separator: " ")
    }

    /// Lossless bridge to the driver's binary-safe transport model.
    var transportCommand: RedisCommand {
        RedisCommand(arguments: arguments.map { Data($0.bytes) })
    }

    func containsArgument(_ value: String, after index: Int = 0) -> Bool {
        arguments.dropFirst(index).contains { $0.equalsIgnoringASCIICase(value) }
    }
}

enum RedisCommandTokenizerError: Error, Equatable, LocalizedError {
    case emptyCommand
    case invalidCommandName
    case unterminatedQuote(Character)
    case danglingEscape
    case invalidHexEscape

    var errorDescription: String? {
        switch self {
        case .emptyCommand:
            return "Enter a Redis command."
        case .invalidCommandName:
            return "Redis command names must be printable ASCII."
        case .unterminatedQuote(let quote):
            return "The \(quote) quote is not terminated."
        case .danglingEscape:
            return "The command ends with an incomplete escape sequence."
        case .invalidHexEscape:
            return "Hex escapes must contain exactly two hexadecimal digits."
        }
    }
}

enum RedisCommandTokenizer {
    static func tokenize(_ source: String) throws -> ParsedRedisCommand {
        let input = Array(source.utf8)
        var index = 0
        var arguments: [RedisCommandToken] = []

        while true {
            skipWhitespace(in: input, index: &index)
            guard index < input.count else { break }

            var token: [UInt8] = []
            var tokenStarted = false

            while index < input.count, !isWhitespace(input[index]) {
                tokenStarted = true
                switch input[index] {
                case CharacterByte.singleQuote, CharacterByte.doubleQuote:
                    let quote = input[index]
                    index += 1
                    try appendQuotedBytes(
                        from: input,
                        index: &index,
                        quote: quote,
                        to: &token
                    )
                case CharacterByte.backslash:
                    index += 1
                    try appendEscapedByte(from: input, index: &index, to: &token)
                default:
                    token.append(input[index])
                    index += 1
                }
            }

            if tokenStarted {
                arguments.append(RedisCommandToken(bytes: token))
            }
        }

        return try ParsedRedisCommand(arguments: arguments)
    }

    private static func appendQuotedBytes(
        from input: [UInt8],
        index: inout Int,
        quote: UInt8,
        to output: inout [UInt8]
    ) throws {
        while index < input.count {
            if input[index] == quote {
                index += 1
                return
            }
            if input[index] == CharacterByte.backslash {
                index += 1
                try appendEscapedByte(from: input, index: &index, to: &output)
            } else {
                output.append(input[index])
                index += 1
            }
        }

        let quoteCharacter = quote == CharacterByte.singleQuote ? Character("'") : Character("\"")
        throw RedisCommandTokenizerError.unterminatedQuote(quoteCharacter)
    }

    private static func appendEscapedByte(
        from input: [UInt8],
        index: inout Int,
        to output: inout [UInt8]
    ) throws {
        guard index < input.count else {
            throw RedisCommandTokenizerError.danglingEscape
        }

        switch input[index] {
        case CharacterByte.lowercaseA:
            output.append(0x07)
            index += 1
        case CharacterByte.lowercaseB:
            output.append(0x08)
            index += 1
        case CharacterByte.lowercaseN:
            output.append(0x0A)
            index += 1
        case CharacterByte.lowercaseR:
            output.append(0x0D)
            index += 1
        case CharacterByte.lowercaseT:
            output.append(0x09)
            index += 1
        case CharacterByte.lowercaseX:
            guard index + 2 < input.count,
                  let high = hexValue(input[index + 1]),
                  let low = hexValue(input[index + 2]) else {
                throw RedisCommandTokenizerError.invalidHexEscape
            }
            output.append((high << 4) | low)
            index += 3
        default:
            // redis-cli treats a backslash as escaping the following byte even
            // when that byte has no named escape.
            output.append(input[index])
            index += 1
        }
    }

    private static func skipWhitespace(in input: [UInt8], index: inout Int) {
        while index < input.count, isWhitespace(input[index]) {
            index += 1
        }
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x09...0x0D, 0x20: return true
        default: return false
        }
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x41...0x46: return byte - 0x41 + 10
        case 0x61...0x66: return byte - 0x61 + 10
        default: return nil
        }
    }
}

enum RedisCommandCategory: String, Codable, CaseIterable, Sendable {
    case readOnly = "read_only"
    case write
    case destructive
    case administrative
    case connectionStateful = "connection_stateful"
    case unknown
}

enum RedisCommandExecutionDecision: String, Codable, Sendable {
    case allow
    case requireConfirmation = "require_confirmation"
    case deny
}

enum RedisCommandConfirmationKind: String, Codable, Sendable {
    case write
    case destructive
    case administrative
    case unknown
}

struct RedisCommandExecutionPolicy: Equatable, Sendable {
    let decision: RedisCommandExecutionDecision
    let confirmationKind: RedisCommandConfirmationKind?
    let message: String?

    static let allow = RedisCommandExecutionPolicy(
        decision: .allow,
        confirmationKind: nil,
        message: nil
    )

    static func confirm(_ kind: RedisCommandConfirmationKind, message: String) -> Self {
        RedisCommandExecutionPolicy(
            decision: .requireConfirmation,
            confirmationKind: kind,
            message: message
        )
    }

    static func deny(message: String) -> Self {
        RedisCommandExecutionPolicy(
            decision: .deny,
            confirmationKind: nil,
            message: message
        )
    }

    var requiresConfirmation: Bool {
        decision == .requireConfirmation
    }

    var allowsExecution: Bool {
        decision != .deny
    }
}

struct RedisServerCommandMetadata: Equatable, Sendable {
    let flags: Set<String>
    let aclCategories: Set<String>

    init(flags: Set<String> = [], aclCategories: Set<String> = []) {
        self.flags = Set(flags.map { $0.lowercased() })
        self.aclCategories = Set(aclCategories.map { category in
            let lowercased = category.lowercased()
            return lowercased.hasPrefix("@") ? lowercased : "@\(lowercased)"
        })
    }
}

enum RedisCommandHistoryDisposition: Equatable, Sendable {
    case record(command: String, wasRedacted: Bool)
    case exclude(reason: String)
}

struct RedisCommandAnalysis: Equatable, Sendable {
    let command: ParsedRedisCommand
    let category: RedisCommandCategory
    let executionPolicy: RedisCommandExecutionPolicy
    let historyDisposition: RedisCommandHistoryDisposition

    var requiresConfirmation: Bool {
        executionPolicy.requiresConfirmation
    }

    var allowsExecution: Bool {
        executionPolicy.allowsExecution
    }

    /// The command to execute after `executionPolicy` has been enforced.
    var transportCommand: RedisCommand {
        command.transportCommand
    }
}

enum RedisCommandSafety {
    static func analyze(
        _ source: String,
        serverMetadata: RedisServerCommandMetadata? = nil
    ) throws -> RedisCommandAnalysis {
        let command = try RedisCommandTokenizer.tokenize(source)
        return analyze(command, serverMetadata: serverMetadata)
    }

    static func analyze(
        _ command: ParsedRedisCommand,
        serverMetadata: RedisServerCommandMetadata? = nil
    ) -> RedisCommandAnalysis {
        let classification = classify(command, serverMetadata: serverMetadata)
        return RedisCommandAnalysis(
            command: command,
            category: classification.category,
            executionPolicy: classification.policy,
            historyDisposition: RedisCommandHistoryRedactor.historyDisposition(for: command)
        )
    }

    private static func classify(
        _ command: ParsedRedisCommand,
        serverMetadata: RedisServerCommandMetadata?
    ) -> (category: RedisCommandCategory, policy: RedisCommandExecutionPolicy) {
        let name = command.name

        if deniedConnectionCommands.contains(name) || isBlocking(command) || metadataIsBlocking(serverMetadata) {
            return (
                .connectionStateful,
                .deny(message: "\(name) is unavailable because it can alter or monopolize a pooled Redis connection.")
            )
        }

        switch name {
        case "FLUSHALL":
            return (
                .destructive,
                .confirm(.destructive, message: "FLUSHALL deletes every key in every Redis database on this server.")
            )
        case "FLUSHDB":
            return (
                .destructive,
                .confirm(.destructive, message: "FLUSHDB deletes every key in the selected Redis database.")
            )
        case "DEL", "UNLINK", "GETDEL":
            let keyCount = max(command.arguments.count - 1, 0)
            let noun = keyCount == 1 ? "key" : "keys"
            return (
                .destructive,
                .confirm(.destructive, message: "\(name) deletes \(keyCount) Redis \(noun).")
            )
        case "RENAME":
            return (
                .destructive,
                .confirm(.destructive, message: "RENAME overwrites the destination key when it already exists.")
            )
        case "COPY" where command.containsArgument("REPLACE", after: 1),
             "RESTORE" where command.containsArgument("REPLACE", after: 1):
            return (
                .destructive,
                .confirm(.destructive, message: "\(name) with REPLACE can overwrite an existing destination key.")
            )
        default:
            break
        }

        if name == "MEMORY", !command.containsArgument("PURGE", after: 1) {
            return (.readOnly, .allow)
        }

        if administrativeCommands.contains(name) || metadataIsAdministrative(serverMetadata) {
            return (
                .administrative,
                .confirm(.administrative, message: "\(name) is an administrative command that can change server-wide state.")
            )
        }

        if readOnlyCommands.contains(name) {
            return (.readOnly, .allow)
        }

        if writeCommands.contains(name) || serverMetadata?.flags.contains("write") == true {
            return (
                .write,
                .confirm(.write, message: "\(name) can modify Redis data.")
            )
        }

        if serverMetadata?.flags.contains("readonly") == true {
            return (.readOnly, .allow)
        }

        return (
            .unknown,
            .confirm(.unknown, message: "Pluk could not verify that \(name) is read-only.")
        )
    }

    private static func isBlocking(_ command: ParsedRedisCommand) -> Bool {
        if blockingCommands.contains(command.name) {
            return true
        }
        if command.name == "SCRIPT",
           command.arguments.count > 1,
           command.arguments[1].equalsIgnoringASCIICase("DEBUG") {
            return true
        }
        if command.name == "XREAD" || command.name == "XREADGROUP" {
            return command.containsArgument("BLOCK", after: 1)
        }
        return false
    }

    private static func metadataIsAdministrative(_ metadata: RedisServerCommandMetadata?) -> Bool {
        guard let metadata else { return false }
        return metadata.flags.contains("admin") || metadata.flags.contains("dangerous") ||
            metadata.aclCategories.contains("@admin") || metadata.aclCategories.contains("@dangerous")
    }

    private static func metadataIsBlocking(_ metadata: RedisServerCommandMetadata?) -> Bool {
        guard let metadata else { return false }
        return metadata.flags.contains("blocking") || metadata.flags.contains("pubsub")
    }

    private static let deniedConnectionCommands: Set<String> = [
        "ASKING", "AUTH", "CLIENT", "DISCARD", "EXEC", "HELLO", "MONITOR", "MULTI",
        "PSUBSCRIBE", "PSYNC", "PUNSUBSCRIBE", "QUIT", "READONLY", "READWRITE", "REPLCONF",
        "RESET", "SELECT", "SSUBSCRIBE", "SUBSCRIBE", "SUNSUBSCRIBE", "SYNC", "UNSUBSCRIBE",
        "UNWATCH", "WATCH",
    ]

    private static let blockingCommands: Set<String> = [
        "BLMOVE", "BLMPOP", "BLPOP", "BRPOPLPUSH", "BRPOP", "BZMPOP", "BZPOPMAX", "BZPOPMIN",
        "WAIT", "WAITAOF",
    ]

    private static let administrativeCommands: Set<String> = [
        "ACL", "BGREWRITEAOF", "BGSAVE", "CLUSTER", "CONFIG", "DEBUG", "FAILOVER", "FUNCTION",
        "LATENCY", "MEMORY", "MIGRATE", "MODULE", "REPLICAOF", "SAVE", "SCRIPT", "SENTINEL",
        "SHUTDOWN", "SLAVEOF", "SLOWLOG", "SWAPDB",
    ]

    private static let readOnlyCommands: Set<String> = [
        "BITCOUNT", "BITFIELD_RO", "BITPOS", "COMMAND", "DBSIZE", "DUMP", "ECHO", "EVAL_RO",
        "EXISTS", "EXPIRETIME", "FCALL_RO", "GEODIST", "GEOHASH", "GEOPOS", "GEORADIUSBYMEMBER_RO",
        "GEORADIUS_RO", "GEOSEARCH", "GET",
        "GETBIT", "GETRANGE", "HEXISTS", "HGET", "HGETALL", "HKEYS", "HLEN", "HMGET", "HRANDFIELD",
        "HSCAN", "HSTRLEN", "HVALS", "INFO", "JSON.ARRLEN", "JSON.GET", "JSON.OBJKEYS", "JSON.OBJLEN",
        "JSON.RESP", "JSON.STRLEN", "JSON.TYPE", "LASTSAVE", "LINDEX", "LLEN", "LPOS", "LRANGE", "MGET",
        "OBJECT", "PEXPIRETIME", "PFCOUNT", "PING", "PTTL", "RANDOMKEY", "SCARD", "SCAN",
        "SDIFF", "SINTER", "SINTERCARD", "SISMEMBER", "SMEMBERS", "SMISMEMBER", "SRANDMEMBER",
        "ROLE", "SORT_RO", "SSCAN", "STRLEN", "SUNION", "TIME", "TOUCH", "TTL", "TYPE", "XINFO", "XLEN", "XPENDING", "XRANGE",
        "XREAD", "XREVRANGE", "ZCARD", "ZCOUNT", "ZDIFF", "ZINTER", "ZINTERCARD", "ZLEXCOUNT",
        "ZMSCORE", "ZRANDMEMBER", "ZRANGE", "ZRANGEBYLEX", "ZRANGEBYSCORE", "ZRANK", "ZREVRANGE",
        "ZREVRANGEBYLEX", "ZREVRANGEBYSCORE", "ZREVRANK", "ZSCAN", "ZSCORE", "ZUNION",
    ]

    private static let writeCommands: Set<String> = [
        "APPEND", "BITFIELD", "BITOP", "COPY", "DECR", "DECRBY", "EXPIRE", "EXPIREAT", "GEOADD",
        "GEOSEARCHSTORE", "GETEX", "GETSET", "HDEL", "HGETEX", "HINCRBY", "HINCRBYFLOAT", "HMSET", "HSET", "HSETEX", "HSETNX", "INCR",
        "INCRBY", "INCRBYFLOAT", "JSON.ARRAPPEND", "JSON.ARRINSERT", "JSON.ARRPOP", "JSON.ARRTRIM",
        "JSON.CLEAR", "JSON.DEBUG", "JSON.DEL", "JSON.FORGET", "JSON.MERGE", "JSON.MSET", "JSON.NUMINCRBY",
        "JSON.NUMMULTBY", "JSON.SET", "JSON.STRAPPEND", "LINSERT", "LMOVE", "LMPOP", "LPOP", "LPUSH",
        "LPUSHX", "LREM", "LSET", "LTRIM", "MSET", "MSETNX", "PERSIST", "PEXPIRE", "PEXPIREAT",
        "PFADD", "PFMERGE", "PSETEX", "PUBLISH", "RENAMENX", "RESTORE", "RPOP", "RPOPLPUSH", "RPUSH",
        "RPUSHX", "SADD", "SET", "SETBIT", "SETEX", "SETNX", "SETRANGE", "SINTERSTORE", "SMOVE", "SPOP",
        "SDIFFSTORE", "SREM", "SUNIONSTORE", "XACK", "XADD", "XAUTOCLAIM", "XCLAIM", "XDEL", "XGROUP", "XREADGROUP", "XSETID",
        "XTRIM", "ZADD", "ZDIFFSTORE", "ZINCRBY", "ZINTERSTORE", "ZMPOP", "ZPOPMAX", "ZPOPMIN",
        "ZRANGESTORE", "ZREM", "ZREMRANGEBYLEX", "ZREMRANGEBYRANK", "ZREMRANGEBYSCORE", "ZUNIONSTORE",
    ]
}

enum RedisCommandHistoryRedactor {
    private static let nestedCredentialExclusionReason =
        "Commands containing authentication credentials are never stored in query history."
    private static let maximumNestedCommandDepth = 8

    struct Redaction: Equatable, Sendable {
        let sanitizedCommand: String
        let wasRedacted: Bool
        let shouldExclude: Bool
    }

    static func historyDisposition(for command: ParsedRedisCommand) -> RedisCommandHistoryDisposition {
        if command.name == "AUTH" {
            return .exclude(reason: "Authentication commands are never stored in query history.")
        }

        if isACLSetUser(command) {
            return .exclude(reason: "ACL SETUSER commands are never stored in query history.")
        }

        if let redaction = parsedRedaction(for: command) {
            if redaction.shouldExclude {
                return .exclude(reason: nestedCredentialExclusionReason)
            }
            return .record(command: redaction.sanitizedCommand, wasRedacted: true)
        }

        return .record(command: command.renderedForHistory, wasRedacted: false)
    }

    static func redactIfNeeded(in source: String) -> Redaction? {
        if let command = try? RedisCommandTokenizer.tokenize(source) {
            return parsedRedaction(for: command)
        }

        return fallbackRedaction(in: source)
    }

    private static func parsedRedaction(
        for command: ParsedRedisCommand,
        depth: Int = 0
    ) -> Redaction? {
        if command.name == "AUTH" {
            return Redaction(
                sanitizedCommand: "AUTH [REDACTED]",
                wasRedacted: true,
                shouldExclude: true
            )
        }

        if isACLSetUser(command) {
            return Redaction(
                sanitizedCommand: sanitizedACLSetUser(command),
                wasRedacted: true,
                shouldExclude: true
            )
        }

        if let nestedStartIndex = nestedCommandStartIndex(in: command) {
            let prefix = command.arguments.prefix(nestedStartIndex)
                .map(\.historyRepresentation)
                .joined(separator: " ")

            // Introspection wrappers can themselves be nested. Bound recursion
            // and conservatively hide an invalid or excessively deep tail.
            guard depth < maximumNestedCommandDepth,
                  command.arguments.count > nestedStartIndex,
                  let nestedCommand = try? ParsedRedisCommand(
                      arguments: Array(command.arguments.dropFirst(nestedStartIndex))
                  ) else {
                return Redaction(
                    sanitizedCommand: prefix + " [REDACTED]",
                    wasRedacted: true,
                    shouldExclude: true
                )
            }

            if let nestedRedaction = parsedRedaction(for: nestedCommand, depth: depth + 1) {
                return Redaction(
                    sanitizedCommand: prefix + " " + nestedRedaction.sanitizedCommand,
                    wasRedacted: true,
                    shouldExclude: nestedRedaction.shouldExclude
                )
            }
        }

        guard let redacted = redactSensitiveArguments(in: command) else {
            return nil
        }
        return Redaction(
            sanitizedCommand: redacted,
            wasRedacted: true,
            shouldExclude: false
        )
    }

    private static func nestedCommandStartIndex(in command: ParsedRedisCommand) -> Int? {
        if command.name == "ACL",
           command.arguments.count > 1,
           command.arguments[1].equalsIgnoringASCIICase("DRYRUN") {
            // ACL DRYRUN <username> <command> [<arg> ...]
            return 3
        }

        if command.name == "COMMAND",
           command.arguments.count > 1,
           command.arguments[1].equalsIgnoringASCIICase("GETKEYS") ||
               command.arguments[1].equalsIgnoringASCIICase("GETKEYSANDFLAGS") {
            // COMMAND GETKEYS[ANDFLAGS] <command> [<arg> ...]
            return 2
        }

        return nil
    }

    private static func redactSensitiveArguments(in command: ParsedRedisCommand) -> String? {
        switch command.name {
        case "HELLO":
            return redactHello(command)
        case "CONFIG":
            return redactConfigSet(command)
        case "MIGRATE":
            return redactMigrate(command)
        case "SENTINEL":
            return redactSentinelSet(command)
        default:
            return nil
        }
    }

    private static func isACLSetUser(_ command: ParsedRedisCommand) -> Bool {
        command.name == "ACL" &&
            command.arguments.count > 1 &&
            command.arguments[1].equalsIgnoringASCIICase("SETUSER")
    }

    private static func sanitizedACLSetUser(_ command: ParsedRedisCommand) -> String {
        guard command.arguments.count > 2 else {
            return "ACL SETUSER [REDACTED]"
        }

        return [
            command.arguments[0].historyRepresentation,
            command.arguments[1].historyRepresentation,
            command.arguments[2].historyRepresentation,
            "[REDACTED]",
        ].joined(separator: " ")
    }

    private static func redactHello(_ command: ParsedRedisCommand) -> String? {
        var arguments = command.arguments
        var redacted = false
        var index = 1

        while index < arguments.count {
            guard arguments[index].equalsIgnoringASCIICase("AUTH") else {
                index += 1
                continue
            }

            // HELLO AUTH requires a username and password. If the command is
            // malformed, redact everything after AUTH rather than risk storing
            // a partial credential.
            guard index + 2 < arguments.count else {
                let prefix = arguments[...index].map(\.historyRepresentation).joined(separator: " ")
                return prefix + " [REDACTED]"
            }

            arguments[index + 2] = RedisCommandToken("[REDACTED]")
            redacted = true
            index += 3
        }

        guard redacted else { return nil }
        return arguments.map(\.historyRepresentation).joined(separator: " ")
    }

    private static func redactConfigSet(_ command: ParsedRedisCommand) -> String? {
        guard command.arguments.count > 1,
              command.arguments[1].equalsIgnoringASCIICase("SET") else {
            return nil
        }

        var arguments = command.arguments
        var redacted = false
        var parameterIndex = 2

        // CONFIG SET arguments are parameter/value pairs. Walking pair
        // boundaries avoids treating an ordinary value that happens to be
        // named "requirepass" as the next parameter.
        while parameterIndex < arguments.count {
            let valueIndex = parameterIndex + 1
            if isSensitiveConfigParameter(arguments[parameterIndex]) {
                if valueIndex < arguments.count {
                    arguments[valueIndex] = RedisCommandToken("[REDACTED]")
                } else {
                    arguments.append(RedisCommandToken("[REDACTED]"))
                }
                redacted = true
            }
            parameterIndex += 2
        }

        guard redacted else { return nil }
        return arguments.map(\.historyRepresentation).joined(separator: " ")
    }

    private static func isSensitiveConfigParameter(_ token: RedisCommandToken) -> Bool {
        guard let parameter = token.uppercasedASCIIValue else { return false }
        return parameter == "REQUIREPASS" || parameter == "MASTERAUTH" ||
            parameter == "PRIMARYAUTH" || parameter.hasSuffix("KEY-FILE-PASS")
    }

    private static func redactMigrate(_ command: ParsedRedisCommand) -> String? {
        // MIGRATE has five required positional arguments after the command;
        // authentication options begin at argument index 6. Everything after
        // KEYS is a key name and must not be mistaken for an AUTH option.
        guard command.arguments.count > 6 else { return nil }

        var arguments = command.arguments
        var redacted = false
        var index = 6

        while index < arguments.count {
            if arguments[index].equalsIgnoringASCIICase("KEYS") {
                break
            }

            if arguments[index].equalsIgnoringASCIICase("AUTH") {
                let passwordIndex = index + 1
                if passwordIndex < arguments.count {
                    arguments[passwordIndex] = RedisCommandToken("[REDACTED]")
                } else {
                    arguments.append(RedisCommandToken("[REDACTED]"))
                }
                redacted = true
                index += 2
                continue
            }

            if arguments[index].equalsIgnoringASCIICase("AUTH2") {
                let passwordIndex = index + 2
                if passwordIndex < arguments.count {
                    arguments[passwordIndex] = RedisCommandToken("[REDACTED]")
                } else {
                    arguments.append(RedisCommandToken("[REDACTED]"))
                }
                redacted = true
                index += 3
                continue
            }

            index += 1
        }

        guard redacted else { return nil }
        return arguments.map(\.historyRepresentation).joined(separator: " ")
    }

    private static func redactSentinelSet(_ command: ParsedRedisCommand) -> String? {
        guard command.arguments.count > 1,
              command.arguments[1].equalsIgnoringASCIICase("SET") else {
            return nil
        }

        var arguments = command.arguments
        var redacted = false
        var parameterIndex = 3

        // SENTINEL SET arguments after the master name are option/value
        // pairs. Only inspect option positions so non-secret values are kept.
        while parameterIndex < arguments.count {
            let valueIndex = parameterIndex + 1
            if arguments[parameterIndex].equalsIgnoringASCIICase("AUTH-PASS") ||
                arguments[parameterIndex].equalsIgnoringASCIICase("AUTH-USER") {
                if valueIndex < arguments.count {
                    arguments[valueIndex] = RedisCommandToken("[REDACTED]")
                } else {
                    arguments.append(RedisCommandToken("[REDACTED]"))
                }
                redacted = true
            }
            parameterIndex += 2
        }

        guard redacted else { return nil }
        return arguments.map(\.historyRepresentation).joined(separator: " ")
    }

    private static func fallbackRedaction(in source: String) -> Redaction? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)

        if startsWithCommand("AUTH", in: trimmed) {
            return Redaction(
                sanitizedCommand: "AUTH [REDACTED]",
                wasRedacted: true,
                shouldExclude: true
            )
        }

        if startsWithCommand("ACL", in: trimmed),
           let setUserMatch = firstMatch(of: #"^ACL\s+SETUSER\b"#, in: trimmed) {
            let prefix = prefix(through: setUserMatch, in: trimmed)
            return Redaction(
                sanitizedCommand: prefix + " [REDACTED]",
                wasRedacted: true,
                shouldExclude: true
            )
        }

        if startsWithCommand("ACL", in: trimmed),
           let dryRunMatch = firstMatch(of: #"^ACL\s+DRYRUN\b"#, in: trimmed) {
            // Tokenization has already failed, so argument boundaries in the
            // nested command are not trustworthy. Drop the complete tail.
            return fallbackRedaction(
                through: dryRunMatch,
                in: trimmed,
                shouldExclude: true
            )
        }

        if startsWithCommand("COMMAND", in: trimmed),
           let getKeysMatch = firstMatch(
               of: #"^COMMAND\s+GETKEYS(?:ANDFLAGS)?\b"#,
               in: trimmed
           ) {
            return fallbackRedaction(
                through: getKeysMatch,
                in: trimmed,
                shouldExclude: true
            )
        }

        if startsWithCommand("HELLO", in: trimmed),
           let authMatch = firstMatch(of: #"\bAUTH\b"#, in: trimmed) {
            return fallbackRedaction(through: authMatch, in: trimmed)
        }

        if startsWithCommand("CONFIG", in: trimmed),
           firstMatch(of: #"^CONFIG\s+SET\b"#, in: trimmed) != nil,
           let parameterMatch = firstMatch(
               of: #"\b(?:REQUIREPASS|MASTERAUTH|PRIMARYAUTH|[A-Z0-9._-]*KEY-FILE-PASS)\b"#,
               in: trimmed
           ) {
            return fallbackRedaction(through: parameterMatch, in: trimmed)
        }

        if startsWithCommand("MIGRATE", in: trimmed),
           let authMatch = firstMatch(of: #"\bAUTH2?\b"#, in: trimmed) {
            return fallbackRedaction(through: authMatch, in: trimmed)
        }

        if startsWithCommand("SENTINEL", in: trimmed),
           firstMatch(of: #"^SENTINEL\s+SET\b"#, in: trimmed) != nil,
           let parameterMatch = firstMatch(of: #"\bAUTH-(?:PASS|USER)\b"#, in: trimmed) {
            return fallbackRedaction(through: parameterMatch, in: trimmed)
        }

        return nil
    }

    private static func startsWithCommand(_ command: String, in source: String) -> Bool {
        guard source.count >= command.count else { return false }
        let commandEnd = source.index(source.startIndex, offsetBy: command.count)
        guard String(source[..<commandEnd]).caseInsensitiveCompare(command) == .orderedSame else {
            return false
        }
        guard commandEnd < source.endIndex else { return true }
        return source[commandEnd].isWhitespace
    }

    private static func firstMatch(of pattern: String, in source: String) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        return regex.firstMatch(
            in: source,
            range: NSRange(source.startIndex..., in: source)
        )
    }

    private static func prefix(through match: NSTextCheckingResult, in source: String) -> String {
        let prefixRange = NSRange(location: 0, length: NSMaxRange(match.range))
        return (source as NSString).substring(with: prefixRange)
    }

    private static func fallbackRedaction(
        through match: NSTextCheckingResult,
        in source: String,
        shouldExclude: Bool = false
    ) -> Redaction {
        Redaction(
            sanitizedCommand: prefix(through: match, in: source) + " [REDACTED]",
            wasRedacted: true,
            shouldExclude: shouldExclude
        )
    }
}

private enum CharacterByte {
    static let asciiCaseOffset: UInt8 = 0x20
    static let backslash: UInt8 = 0x5C
    static let doubleQuote: UInt8 = 0x22
    static let singleQuote: UInt8 = 0x27
    static let lowercaseA: UInt8 = 0x61
    static let lowercaseB: UInt8 = 0x62
    static let lowercaseN: UInt8 = 0x6E
    static let lowercaseR: UInt8 = 0x72
    static let lowercaseT: UInt8 = 0x74
    static let lowercaseX: UInt8 = 0x78
    static let lowercaseZ: UInt8 = 0x7A
}
