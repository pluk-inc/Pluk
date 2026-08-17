import Foundation
import Testing
@testable import Pluk

/// Opt-in integration coverage for a disposable Redis/Valkey server.
/// Provide `PLUK_REDIS_TEST_URL` to the hosted test process (for example through
/// the generated `.xctestrun` environment) to run it. Setting the variable only
/// on `xcodebuild` does not propagate it to this app-hosted test bundle.
struct RedisDriverLiveTests {
    @Test
    func failedDatabaseSwitchRetainsSettingsForReconnect() async throws {
        guard let connectionURL = ProcessInfo.processInfo.environment["PLUK_REDIS_TEST_URL"],
              !connectionURL.isEmpty else {
            return
        }

        let driver = RedisDriver()
        _ = try await driver.connect(to: connectionURL)

        do {
            do {
                try await driver.switchDatabase(to: String(Int.max))
                Issue.record("Expected Redis to reject an out-of-range logical database")
            } catch {
                // A failed replacement stops the pool, but reconnect must still be
                // able to use the last successfully connected settings.
                try await driver.reconnect()
                let ping = try await driver.executeRedisCommand(RedisCommand(arguments: ["PING"]))
                #expect(ping.value == .simpleString(Data("PONG".utf8)))
            }

            await driver.disconnect()
        } catch {
            await driver.disconnect()
            throw error
        }
    }

    @Test
    func liveServerRoundTripCoversScanningTypesTTLAndDatabaseIsolation() async throws {
        guard let connectionURL = ProcessInfo.processInfo.environment["PLUK_REDIS_TEST_URL"],
              !connectionURL.isEmpty else {
            return
        }

        let driver = RedisDriver()
        let originalDatabase = try ConnectionURLParser.parseRedis(connectionURL).databaseIndex
        let isolationDatabase = originalDatabase == 0 ? 1 : 0
        _ = try await driver.connect(to: connectionURL)

        let prefix = "pluk:integration:\(UUID().uuidString)"
        var binaryKeyBytes = Data("\(prefix):binary:".utf8)
        binaryKeyBytes.append(contentsOf: [0x00, 0xFF])
        let binaryKey = RedisKey(bytes: binaryKeyBytes)
        let hashKey = RedisKey("\(prefix):hash")
        let listKey = RedisKey("\(prefix):list")
        let setKey = RedisKey("\(prefix):set")
        let sortedSetKey = RedisKey("\(prefix):zset")
        let streamKey = RedisKey("\(prefix):stream")
        let keys = [binaryKey, hashKey, listKey, setKey, sortedSetKey, streamKey]

        do {
            let originalValue = Data([0x00, 0x41, 0xFF])
            _ = try await driver.executeRedisCommand(
                RedisCommand(arguments: [bytes("SET"), binaryKey.bytes, originalValue, bytes("PX"), bytes("60000")])
            )

            let initialMetadata = try await driver.redisKeyMetadata(for: binaryKey)
            #expect(initialMetadata.type == .string)
            #expect((initialMetadata.ttlMilliseconds ?? 0) > 0)

            let initialValue = try await driver.redisValue(for: binaryKey, page: RedisValuePage())
            #expect(initialValue == .string(originalValue))

            let replacement = Data([0xFE, 0x00, 0x42])
            try await driver.updateRedisValue(.string(replacement), for: binaryKey, preserveTTL: true)
            let updatedMetadata = try await driver.redisKeyMetadata(for: binaryKey)
            #expect((updatedMetadata.ttlMilliseconds ?? 0) > 0)
            let updatedValue = try await driver.redisValue(for: binaryKey, page: RedisValuePage())
            #expect(updatedValue == .string(replacement))

            _ = try await driver.executeRedisCommand(
                RedisCommand(arguments: [bytes("HSET"), hashKey.bytes, Data([0xFF]), Data([0x00, 0x01])])
            )
            _ = try await driver.executeRedisCommand(
                RedisCommand(arguments: [bytes("RPUSH"), listKey.bytes, Data([0x80]), bytes("two")])
            )
            _ = try await driver.executeRedisCommand(
                RedisCommand(arguments: [bytes("SADD"), setKey.bytes, Data([0x00]), bytes("member")])
            )
            _ = try await driver.executeRedisCommand(
                RedisCommand(arguments: [bytes("ZADD"), sortedSetKey.bytes, bytes("1.5"), Data([0xFE])])
            )
            _ = try await driver.executeRedisCommand(
                RedisCommand(arguments: [bytes("XADD"), streamKey.bytes, bytes("*"), bytes("field"), Data([0xFF])])
            )

            let decodedTypes = try await [hashKey, listKey, setKey, sortedSetKey, streamKey]
                .asyncMap { try await driver.redisKeyMetadata(for: $0).type }
            #expect(decodedTypes == [.hash, .list, .set, .sortedSet, .stream])

            let hashValue = try await driver.redisValue(for: hashKey, page: RedisValuePage())
            if case .hash(let entries, let totalCount, _) = hashValue {
                #expect(totalCount == 1)
                #expect(entries == [RedisHashEntry(field: Data([0xFF]), value: Data([0x00, 0x01]))])
            } else {
                Issue.record("Expected a decoded Redis hash")
            }

            let listValue = try await driver.redisValue(for: listKey, page: RedisValuePage())
            if case .list(let elements, let totalCount, _) = listValue {
                #expect(totalCount == 2)
                #expect(elements == [Data([0x80]), bytes("two")])
            } else {
                Issue.record("Expected a decoded Redis list")
            }

            let setValue = try await driver.redisValue(for: setKey, page: RedisValuePage())
            if case .set(let members, let totalCount, _) = setValue {
                #expect(totalCount == 2)
                #expect(Set(members) == Set([Data([0x00]), bytes("member")]))
            } else {
                Issue.record("Expected a decoded Redis set")
            }

            let sortedSetValue = try await driver.redisValue(for: sortedSetKey, page: RedisValuePage())
            if case .sortedSet(let entries, let totalCount, _) = sortedSetValue {
                #expect(totalCount == 1)
                #expect(entries == [RedisSortedSetEntry(member: Data([0xFE]), score: 1.5)])
            } else {
                Issue.record("Expected a decoded Redis sorted set")
            }

            let streamValue = try await driver.redisValue(for: streamKey, page: RedisValuePage())
            if case .stream(let entries, let totalCount) = streamValue {
                #expect(totalCount == 1)
                #expect(entries.count == 1)
                #expect(entries.first?.fields == [RedisHashEntry(field: bytes("field"), value: Data([0xFF]))])
            } else {
                Issue.record("Expected a decoded Redis stream")
            }

            var cursor: UInt64 = 0
            var scanned = Set<RedisKey>()
            repeat {
                let page = try await driver.scanRedisKeys(
                    cursor: cursor,
                    pattern: "\(prefix):*",
                    type: nil,
                    count: 2
                )
                scanned.formUnion(page.keys)
                cursor = page.nextCursor
            } while cursor != 0
            #expect(Set(keys).isSubset(of: scanned))

            try await driver.switchDatabase(to: String(isolationDatabase))
            let isolatedPage = try await driver.scanRedisKeys(
                cursor: 0,
                pattern: "\(prefix):*",
                type: nil,
                count: 100
            )
            #expect(isolatedPage.keys.isEmpty)
            try await driver.switchDatabase(to: String(originalDatabase))

            _ = try await driver.deleteRedisKeys(keys, asynchronously: true)
            await driver.disconnect()
        } catch {
            try? await driver.switchDatabase(to: String(originalDatabase))
            _ = try? await driver.deleteRedisKeys(keys, asynchronously: true)
            await driver.disconnect()
            throw error
        }
    }

    private func bytes(_ value: String) -> Data {
        Data(value.utf8)
    }
}

private extension Array {
    func asyncMap<Output>(_ transform: (Element) async throws -> Output) async rethrows -> [Output] {
        var result: [Output] = []
        result.reserveCapacity(count)
        for element in self {
            result.append(try await transform(element))
        }
        return result
    }
}
