//
//  RedisConnectionURLParserTests.swift
//  collectionTests
//

import Testing
@testable import Pluk

struct RedisConnectionURLParserTests {
    @Test func parsesPlainRedisURLWithDefaults() throws {
        let parsed = try ConnectionURLParser.parseRedis("redis://localhost")

        #expect(parsed.hostname == "localhost")
        #expect(parsed.port == 6379)
        #expect(parsed.username == nil)
        #expect(parsed.password == nil)
        #expect(parsed.databaseIndex == 0)
        #expect(!parsed.usesTLS)
    }

    @Test func parsesTLSACLAndPercentEncodedCredentials() throws {
        let parsed = try ConnectionURLParser.parseRedis(
            "rediss://app%20user:p%40ss%2Fword@redis.example.com:6380/12"
        )

        #expect(parsed.scheme == "rediss")
        #expect(parsed.hostname == "redis.example.com")
        #expect(parsed.port == 6380)
        #expect(parsed.username == "app user")
        #expect(parsed.password == "p@ss/word")
        #expect(parsed.databaseIndex == 12)
        #expect(parsed.usesTLS)
    }

    @Test func parsesPasswordOnlyAuthentication() throws {
        let parsed = try ConnectionURLParser.parseRedis(
            "redis://:s%3Aecret@localhost:6379/2"
        )

        #expect(parsed.username == nil)
        #expect(parsed.password == "s:ecret")
        #expect(parsed.databaseIndex == 2)
    }

    @Test func buildsAndRoundTripsTLSURL() throws {
        let url = try ConnectionURLParser.makeRedisURL(
            hostname: "::1",
            port: 6380,
            username: "cache user",
            password: "p@ss/word",
            databaseIndex: 3,
            usesTLS: true
        )
        let parsed = try ConnectionURLParser.parseRedis(url)

        #expect(parsed.hostname == "::1")
        #expect(parsed.port == 6380)
        #expect(parsed.username == "cache user")
        #expect(parsed.password == "p@ss/word")
        #expect(parsed.databaseIndex == 3)
        #expect(parsed.usesTLS)
    }

    @Test func buildsPasswordOnlyURL() throws {
        let url = try ConnectionURLParser.makeRedisURL(
            hostname: "localhost",
            password: "secret",
            databaseIndex: 1
        )

        #expect(url == "redis://:secret@localhost:6379/1")
        let parsed = try ConnectionURLParser.parseRedis(url)
        #expect(parsed.username == nil)
        #expect(parsed.password == "secret")
    }

    @Test func rejectsUnsupportedScheme() {
        #expect(throws: ConnectionURLParserError.unsupportedScheme("http")) {
            try ConnectionURLParser.parseRedis("http://localhost:6379/0")
        }
    }

    @Test func rejectsInvalidPort() {
        #expect(throws: ConnectionURLParserError.invalidPort(65_536)) {
            try ConnectionURLParser.parseRedis("redis://localhost:65536/0")
        }
    }

    @Test func rejectsACLUsernameWithoutPassword() {
        #expect(throws: ConnectionURLParserError.missingPassword) {
            try ConnectionURLParser.parseRedis("redis://cache-user@localhost/0")
        }
    }

    @Test(arguments: ["-1", "abc", "1/extra"])
    func rejectsInvalidDatabaseIndex(_ index: String) {
        #expect(throws: ConnectionURLParserError.invalidDatabaseIndex(index)) {
            try ConnectionURLParser.parseRedis("redis://localhost/\(index)")
        }
    }

    @Test func redisCapabilitiesExcludeRelationalSurfaces() {
        #expect(!DatabaseType.redis.supportsTableBrowser)
        #expect(!DatabaseType.redis.supportsSchemaBrowser)
        #expect(!DatabaseType.redis.supportsCanvas)
        #expect(!DatabaseType.redis.supportsNotebookAnalytics)
        #expect(DatabaseType.redis.supportsKeyValueBrowser)
        #expect(DatabaseType.redis.supportsCommandWorkspace)
        #expect(!DatabaseType.redis.supportsDatabaseCreation)
    }

    @Test func fieldBasedRedisConnectionDoesNotPersistAURL() {
        let connection = Connection(
            databaseType: .redis,
            name: "Local Redis",
            color: .red,
            environment: .local,
            hostname: "localhost",
            port: "6379",
            username: "",
            database: "4",
            sslMode: "disable"
        )

        #expect(connection.url == nil)
        #expect(connection.connectionUri == "redis://localhost:6379/4")
        #expect(connection.usesFieldBasedConnection)
    }

    @Test func fieldBasedRedisConnectionMapsRequiredTLS() {
        let connection = Connection(
            databaseType: .redis,
            name: "Secure Redis",
            color: .red,
            environment: .production,
            hostname: "redis.example.com",
            port: "6380",
            username: "",
            database: "7",
            sslMode: "require"
        )

        #expect(
            connection.connectionUri
                == "rediss://redis.example.com:6380/7"
        )
    }
}
