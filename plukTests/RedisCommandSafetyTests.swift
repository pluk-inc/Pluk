import Testing
import SwiftData
import Foundation
@testable import Pluk

struct RedisCommandTokenizerTests {
    @Test
    func tokenizesQuotesEscapesEmptyArgumentsAndBinaryBytes() throws {
        let command = try RedisCommandTokenizer.tokenize(
            #"SET "spaced key" 'single quoted' plain\ value "" "\x00\xFF\n""#
        )

        #expect(command.name == "SET")
        #expect(command.arguments.map(\.bytes) == [
            Array("SET".utf8),
            Array("spaced key".utf8),
            Array("single quoted".utf8),
            Array("plain value".utf8),
            [],
            [0x00, 0xFF, 0x0A],
        ])
        #expect(command.transportCommand.arguments == command.arguments.map { Data($0.bytes) })
    }

    @Test
    func concatenatesQuotedAndUnquotedTokenSegments() throws {
        let command = try RedisCommandTokenizer.tokenize(#"SET pre"mid"'post' value"#)

        #expect(command.arguments[1].stringValue == "premidpost")
    }

    @Test
    func acceptsWhitespaceAcrossLinesAsArgumentsOfOneCommand() throws {
        let command = try RedisCommandTokenizer.tokenize("MGET first\nsecond\tthird")

        #expect(command.name == "MGET")
        #expect(command.arguments.compactMap(\.stringValue) == ["MGET", "first", "second", "third"])
    }

    @Test
    func rejectsMalformedInput() {
        #expect(throws: RedisCommandTokenizerError.emptyCommand) {
            try RedisCommandTokenizer.tokenize("  \n\t")
        }
        #expect(throws: RedisCommandTokenizerError.unterminatedQuote(Character("\""))) {
            try RedisCommandTokenizer.tokenize(#"GET "unfinished"#)
        }
        #expect(throws: RedisCommandTokenizerError.danglingEscape) {
            try RedisCommandTokenizer.tokenize(#"GET trailing\"#)
        }
        #expect(throws: RedisCommandTokenizerError.invalidHexEscape) {
            try RedisCommandTokenizer.tokenize(#"GET \xG0"#)
        }
    }
}

struct RedisCommandRedactionTests {
    @Test
    func excludesAuthFromRedisHistoryAndSanitizesGenericHistory() throws {
        let analysis = try RedisCommandSafety.analyze(#"AUTH "very secret""#)

        #expect(
            analysis.historyDisposition == .exclude(
                reason: "Authentication commands are never stored in query history."
            )
        )

        let sanitized = QuerySanitizer.sanitize(#"AUTH "very secret""#)
        #expect(sanitized.sanitizedQuery == "AUTH [REDACTED]")
        #expect(sanitized.wasSanitized)
        #expect(!sanitized.sanitizedQuery.contains("very secret"))
    }

    @Test
    func redactsHelloAuthPasswordButKeepsNonSecretArguments() throws {
        let analysis = try RedisCommandSafety.analyze(
            #"HELLO 3 AUTH "user name" "very secret" SETNAME Pluk"#
        )

        guard case .record(let command, let wasRedacted) = analysis.historyDisposition else {
            Issue.record("HELLO should remain recordable after credential redaction")
            return
        }

        #expect(wasRedacted)
        #expect(command.contains("user name"))
        #expect(command.contains("[REDACTED]"))
        #expect(command.contains("SETNAME Pluk"))
        #expect(!command.contains("very secret"))

        let reparsed = try RedisCommandTokenizer.tokenize(command)
        #expect(reparsed.arguments[4].stringValue == "[REDACTED]")
    }

    @Test
    func malformedHelloCannotLeakTrailingCredential() {
        let sanitized = QuerySanitizer.sanitize(#"HELLO 3 AUTH user "unterminated secret"#)

        #expect(sanitized.wasSanitized)
        #expect(sanitized.sanitizedQuery == "HELLO 3 AUTH [REDACTED]")
        #expect(!sanitized.sanitizedQuery.contains("secret"))
    }

    @Test
    func excludesACLSetUserAndSanitizesGenericHistory() throws {
        let source = #"ACL SETUSER alice on >"very secret" ~cached:* +get"#
        let analysis = try RedisCommandSafety.analyze(source)

        #expect(
            analysis.historyDisposition == .exclude(
                reason: "ACL SETUSER commands are never stored in query history."
            )
        )

        let sanitized = QuerySanitizer.sanitize(source)
        #expect(sanitized.sanitizedQuery == "ACL SETUSER alice [REDACTED]")
        #expect(sanitized.wasSanitized)
        #expect(!sanitized.sanitizedQuery.contains("very secret"))
    }

    @Test
    func redactsSensitiveConfigSetValuesWithoutDroppingOtherArguments() throws {
        let source = #"CONFIG SET maxmemory 1gb requirepass "server secret" tls-key-file-pass "key secret" appendonly yes"#
        let analysis = try RedisCommandSafety.analyze(source)

        guard case .record(let command, let wasRedacted) = analysis.historyDisposition else {
            Issue.record("CONFIG SET should remain recordable after credential redaction")
            return
        }

        #expect(wasRedacted)
        #expect(
            command == "CONFIG SET maxmemory 1gb requirepass [REDACTED] " +
                "tls-key-file-pass [REDACTED] appendonly yes"
        )
        #expect(!command.contains("server secret"))
        #expect(!command.contains("key secret"))

        for parameter in ["masterauth", "primaryauth", "tls-client-key-file-pass"] {
            let sanitized = QuerySanitizer.sanitize("CONFIG SET \(parameter) hidden-\(parameter)")
            #expect(sanitized.sanitizedQuery == "CONFIG SET \(parameter) [REDACTED]")
            #expect(!sanitized.sanitizedQuery.contains("hidden-"))
        }
    }

    @Test
    func configRedactionOnlyTreatsParameterPositionsAsSensitive() throws {
        let analysis = try RedisCommandSafety.analyze(
            "CONFIG SET logfile requirepass masterauth actual-secret"
        )

        guard case .record(let command, true) = analysis.historyDisposition else {
            Issue.record("CONFIG SET masterauth should be redacted")
            return
        }

        #expect(command == "CONFIG SET logfile requirepass masterauth [REDACTED]")
        #expect(!command.contains("actual-secret"))
    }

    @Test
    func redactsMigrateAuthAndAuth2WhilePreservingOptionsAndKeys() throws {
        let auth = try RedisCommandSafety.analyze(
            #"MIGRATE cache.example 6379 item 0 5000 COPY AUTH "migration secret" REPLACE"#
        )
        let auth2 = try RedisCommandSafety.analyze(
            #"MIGRATE cache.example 6379 "" 0 5000 AUTH2 "user name" "second secret" KEYS key1 AUTH"#
        )

        guard case .record(let authCommand, true) = auth.historyDisposition,
              case .record(let auth2Command, true) = auth2.historyDisposition else {
            Issue.record("MIGRATE authentication should be redacted and remain recordable")
            return
        }

        #expect(
            authCommand == "MIGRATE cache.example 6379 item 0 5000 COPY AUTH [REDACTED] REPLACE"
        )
        #expect(
            auth2Command == "MIGRATE cache.example 6379 \"\" 0 5000 AUTH2 \"user name\" " +
                "[REDACTED] KEYS key1 AUTH"
        )
        #expect(!authCommand.contains("migration secret"))
        #expect(!auth2Command.contains("second secret"))
    }

    @Test
    func redactsSentinelAuthenticationSettings() throws {
        let analysis = try RedisCommandSafety.analyze(
            #"SENTINEL SET primary auth-user "sentinel user" auth-pass "sentinel secret" down-after-milliseconds 5000"#
        )

        guard case .record(let command, true) = analysis.historyDisposition else {
            Issue.record("SENTINEL SET should remain recordable after credential redaction")
            return
        }

        #expect(
            command == "SENTINEL SET primary auth-user [REDACTED] auth-pass [REDACTED] " +
                "down-after-milliseconds 5000"
        )
        #expect(!command.contains("sentinel user"))
        #expect(!command.contains("sentinel secret"))
    }

    @Test
    func sentinelRedactionOnlyTreatsOptionPositionsAsSensitive() throws {
        let analysis = try RedisCommandSafety.analyze(
            "SENTINEL SET primary notification-script auth-pass auth-user actual-user"
        )

        guard case .record(let command, true) = analysis.historyDisposition else {
            Issue.record("SENTINEL auth-user should be redacted")
            return
        }

        #expect(
            command == "SENTINEL SET primary notification-script auth-pass auth-user [REDACTED]"
        )
        #expect(!command.contains("actual-user"))
    }

    @Test
    func malformedSecretBearingCommandsUseConservativeFallbacks() {
        let cases = [
            (#"ACL SETUSER alice on >"unterminated acl-secret"#, "ACL SETUSER [REDACTED]"),
            (#"CONFIG SET maxmemory 1gb requirepass "unterminated config-secret"#,
             "CONFIG SET maxmemory 1gb requirepass [REDACTED]"),
            (#"MIGRATE host 6379 key 0 5000 AUTH2 user "unterminated migrate-secret"#,
             "MIGRATE host 6379 key 0 5000 AUTH2 [REDACTED]"),
            (#"SENTINEL SET primary auth-pass "unterminated sentinel-secret"#,
             "SENTINEL SET primary auth-pass [REDACTED]"),
        ]

        for (source, expected) in cases {
            let sanitized = QuerySanitizer.sanitize(source)
            #expect(sanitized.wasSanitized)
            #expect(sanitized.sanitizedQuery == expected)
            #expect(!sanitized.sanitizedQuery.localizedCaseInsensitiveContains("secret"))
        }
    }

    @Test
    func excludesAuthNestedInCommandIntrospectionWrappers() throws {
        let sources = [
            "ACL DRYRUN alice AUTH default acl-dryrun-secret",
            "COMMAND GETKEYS AUTH command-secret",
            "COMMAND GETKEYSANDFLAGS AUTH default command-flags-secret",
            "COMMAND GETKEYS COMMAND GETKEYS AUTH recursive-secret",
        ]

        for source in sources {
            let analysis = try RedisCommandSafety.analyze(source)
            guard case .exclude = analysis.historyDisposition else {
                Issue.record("Nested AUTH credentials must be excluded from history")
                continue
            }

            let sanitized = QuerySanitizer.sanitize(source)
            #expect(sanitized.wasSanitized)
            #expect(sanitized.sanitizedQuery.hasSuffix("AUTH [REDACTED]"))
            #expect(!sanitized.sanitizedQuery.localizedCaseInsensitiveContains("secret"))
        }
    }

    @Test
    func redactsRecordableNestedCredentialsWithoutDroppingWrapperArguments() throws {
        let analysis = try RedisCommandSafety.analyze(
            "COMMAND GETKEYS HELLO 3 AUTH default nested-secret SETNAME Pluk"
        )

        guard case .record(let command, true) = analysis.historyDisposition else {
            Issue.record("Recordable nested credentials should be redacted")
            return
        }

        #expect(
            command == "COMMAND GETKEYS HELLO 3 AUTH default [REDACTED] SETNAME Pluk"
        )
        #expect(!command.contains("nested-secret"))
    }

    @Test
    func malformedNestedAuthUsesConservativeFallback() {
        let cases = [
            #"ACL DRYRUN alice AUTH default "unterminated acl-secret"#,
            #"COMMAND GETKEYS AUTH "unterminated command-secret"#,
            #"COMMAND GETKEYSANDFLAGS HELLO 3 AUTH default "unterminated hello-secret"#,
        ]

        for source in cases {
            let sanitized = QuerySanitizer.sanitize(source)
            #expect(sanitized.wasSanitized)
            #expect(sanitized.sanitizedQuery.hasSuffix("[REDACTED]"))
            #expect(!sanitized.sanitizedQuery.localizedCaseInsensitiveContains("secret"))
        }
    }
}

struct RedisCommandClassifierTests {
    @Test
    func permitsKnownReadOnlyCommands() throws {
        for source in ["GET key", "SCAN 0 COUNT 100", "MEMORY USAGE key", "JSON.GET key"] {
            let analysis = try RedisCommandSafety.analyze(source)
            #expect(analysis.category == .readOnly)
            #expect(analysis.executionPolicy == .allow)
        }
    }

    @Test
    func requiresWriteConfirmation() throws {
        for source in ["SET key value", "HSET key field value", "RENAMENX source destination"] {
            let analysis = try RedisCommandSafety.analyze(source)
            #expect(analysis.category == .write)
            #expect(analysis.requiresConfirmation)
            #expect(analysis.executionPolicy.confirmationKind == .write)
        }
    }

    @Test
    func requiresDestructiveConfirmationForExplicitDataLoss() throws {
        let commands = [
            "FLUSHALL",
            "FLUSHDB ASYNC",
            "DEL one two",
            "UNLINK one",
            "RENAME source destination",
            "COPY source destination REPLACE",
        ]

        for source in commands {
            let analysis = try RedisCommandSafety.analyze(source)
            #expect(analysis.category == .destructive)
            #expect(analysis.executionPolicy.confirmationKind == .destructive)
            #expect(analysis.requiresConfirmation)
        }
    }

    @Test
    func classifiesAdminAndUnknownCommandsConservatively() throws {
        let admin = try RedisCommandSafety.analyze("CONFIG SET maxmemory 1gb")
        #expect(admin.category == .administrative)
        #expect(admin.executionPolicy.confirmationKind == .administrative)

        let unknown = try RedisCommandSafety.analyze("MYMODULE.DO key")
        #expect(unknown.category == .unknown)
        #expect(unknown.executionPolicy.confirmationKind == .unknown)
    }

    @Test
    func usesServerMetadataWithoutOverridingLocalDestructiveRules() throws {
        let readMetadata = RedisServerCommandMetadata(flags: ["readonly"])
        let customRead = try RedisCommandSafety.analyze("MYMODULE.GET key", serverMetadata: readMetadata)
        #expect(customRead.category == .readOnly)
        #expect(customRead.executionPolicy == .allow)

        let incorrectlyReadDelete = try RedisCommandSafety.analyze("DEL key", serverMetadata: readMetadata)
        #expect(incorrectlyReadDelete.category == .destructive)
        #expect(incorrectlyReadDelete.requiresConfirmation)
    }

    @Test
    func deniesCommandsThatPoisonOrMonopolizePooledConnections() throws {
        let commands = [
            "AUTH secret",
            "SELECT 2",
            "MULTI",
            "SUBSCRIBE channel",
            "XREAD BLOCK 0 STREAMS s $",
            "SYNC",
            "PSYNC ? -1",
            "REPLCONF listening-port 0",
            "WAIT 1 1000",
            "WAITAOF 1 1 1000",
            "SCRIPT DEBUG yes",
        ]

        for source in commands {
            let analysis = try RedisCommandSafety.analyze(source)
            #expect(analysis.category == .connectionStateful)
            #expect(!analysis.allowsExecution)
            #expect(!analysis.requiresConfirmation)
        }
    }
}

struct RedisCommandHistoryTests {
    @MainActor
    @Test
    func excludesAuthAndPersistsOnlyRedactedHelloCredentials() throws {
        let schema = Schema([QueryHistoryEntry.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let service = QueryHistoryService(
            modelContext: container.mainContext,
            connectionKeychainId: "redis-history-test"
        )

        let auth = try RedisCommandSafety.analyze("AUTH default top-secret")
        #expect(!service.recordRedisCommand(analysis: auth, databaseType: .redis))
        #expect(service.getHistoryCount() == 0)

        let acl = try RedisCommandSafety.analyze("ACL SETUSER alice >acl-secret")
        #expect(!service.recordRedisCommand(analysis: acl, databaseType: .redis))
        #expect(service.getHistoryCount() == 0)

        let hello = try RedisCommandSafety.analyze("HELLO 3 AUTH default top-secret SETNAME Pluk")
        #expect(service.recordRedisCommand(analysis: hello, databaseType: .redis, databaseName: "0"))

        let config = try RedisCommandSafety.analyze("CONFIG SET requirepass config-secret")
        #expect(service.recordRedisCommand(analysis: config, databaseType: .redis, databaseName: "0"))

        let history = service.fetchHistory()
        #expect(history.count == 2)
        let allEntriesWereSanitized = history.allSatisfy { $0.wasSanitized }
        #expect(allEntriesWereSanitized)
        #expect(history.allSatisfy { !$0.isReplayable })
        #expect(history.allSatisfy { $0.querySource == .redisCommandEditor })
        #expect(history.contains { $0.query == "HELLO 3 AUTH default [REDACTED] SETNAME Pluk" })
        #expect(history.contains { $0.query == "CONFIG SET requirepass [REDACTED]" })
        #expect(history.allSatisfy { !$0.query.contains("top-secret") })
        #expect(history.allSatisfy { !$0.query.contains("acl-secret") })
        #expect(history.allSatisfy { !$0.query.contains("config-secret") })
    }
}
