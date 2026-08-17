import Foundation
import NIOCore
import Testing
import Valkey
@testable import Pluk

struct RedisDriverCoreTests {
    @Test
    func lifecycleGenerationInvalidatesOlderOperations() {
        var lifecycle = RedisLifecycleGeneration()
        let first = lifecycle.begin()
        let second = lifecycle.begin()

        #expect(second > first)
        #expect(!lifecycle.isCurrent(first))
        #expect(lifecycle.isCurrent(second))
    }

    @Test
    func browserScanBuildsScanCommandAndNeverKeys() throws {
        let arguments = RedisDriver.scanCommandArguments(
            cursor: 42,
            pattern: "user:*",
            type: .hash,
            count: 250
        )

        let rendered = arguments.map { String(decoding: $0, as: UTF8.self) }
        #expect(rendered == ["SCAN", "42", "MATCH", "user:*", "COUNT", "250", "TYPE", "hash"])
        #expect(rendered.first == "SCAN")
        #expect(!rendered.contains("KEYS"))
    }

    @Test
    func decodesBinarySafeScanPage() throws {
        var bytes = Array("*2\r\n$1\r\n0\r\n*2\r\n$3\r\nfoo\r\n$2\r\n".utf8)
        bytes += [0xFF, 0x00]
        bytes += Array("\r\n".utf8)
        var buffer = ByteBuffer(bytes: bytes)
        let decodedToken = try RESPToken(consuming: &buffer)
        let token = try #require(decodedToken)

        let page = try RedisDriver.decodeScanPage(from: token)

        #expect(page.nextCursor == 0)
        #expect(page.isComplete)
        #expect(page.keys == [RedisKey("foo"), RedisKey(bytes: Data([0xFF, 0x00]))])
    }

    @Test
    func roundTripsMaximumUnsignedScanCursor() throws {
        let cursorText = String(UInt64.max)
        var buffer = ByteBuffer(
            bytes: Array("*2\r\n$\(cursorText.utf8.count)\r\n\(cursorText)\r\n*0\r\n".utf8)
        )
        let decodedToken = try RESPToken(consuming: &buffer)
        let token = try #require(decodedToken)

        let page = try RedisDriver.decodeScanPage(from: token)
        let arguments = RedisDriver.scanCommandArguments(
            cursor: page.nextCursor,
            pattern: nil,
            type: nil,
            count: 200
        )

        #expect(page.nextCursor == UInt64.max)
        #expect(!page.isComplete)
        #expect(String(decoding: arguments[1], as: UTF8.self) == cursorText)
        #expect(RedisValuePage(cursor: .max).cursor == UInt64.max)
    }

    @Test
    func decodesRESP3MapWithoutLosingBinaryValues() throws {
        var bytes = Array("%2\r\n+ok\r\n$3\r\n".utf8)
        bytes += [0x00, 0xFF, 0x41]
        bytes += Array("\r\n+count\r\n:2\r\n".utf8)
        var buffer = ByteBuffer(bytes: bytes)
        let decodedToken = try RESPToken(consuming: &buffer)
        let token = try #require(decodedToken)

        let value = RedisDriver.commandValue(from: token)

        #expect(
            value == .map([
                RedisCommandMapEntry(
                    key: .simpleString(Data("ok".utf8)),
                    value: .bulkString(Data([0x00, 0xFF, 0x41]))
                ),
                RedisCommandMapEntry(
                    key: .simpleString(Data("count".utf8)),
                    value: .integer(2)
                ),
            ])
        )
    }

    @Test
    func encodesTypeSpecificMutationsWithoutChangingBytes() throws {
        let key = RedisKey(bytes: Data([0x6B, 0x00, 0xFF]))
        let value = Data([0x00, 0xFE, 0x41])

        let encodedStringCommand = try RedisDriver.mutationCommandArguments(
            for: .string(value), key: key, preserveTTL: true
        )
        let stringCommand = try #require(encodedStringCommand)
        #expect(stringCommand == [Data("SET".utf8), key.bytes, value, Data("KEEPTTL".utf8)])
        #expect(!stringCommand.contains(Data("PTTL".utf8)))
        #expect(!stringCommand.contains(Data("PEXPIRE".utf8)))

        let encodedExpiringStringCommand = try RedisDriver.mutationCommandArguments(
            for: .string(value), key: key, preserveTTL: false
        )
        let expiringStringCommand = try #require(encodedExpiringStringCommand)
        #expect(expiringStringCommand == [Data("SET".utf8), key.bytes, value])

        let encodedHashCommand = try RedisDriver.mutationCommandArguments(
            for: .hashField(field: Data([0xFF]), value: value),
            key: key,
            preserveTTL: true
        )
        let hashCommand = try #require(encodedHashCommand)
        #expect(hashCommand == [Data("HSET".utf8), key.bytes, Data([0xFF]), value])

        let json = Data(#"{"enabled":true}"#.utf8)
        let encodedJSONCommand = try RedisDriver.mutationCommandArguments(
            for: .json(json), key: key, preserveTTL: true
        )
        let jsonCommand = try #require(encodedJSONCommand)
        #expect(jsonCommand == [Data("JSON.SET".utf8), key.bytes, Data("$".utf8), json])
        #expect(!jsonCommand.contains(Data("PTTL".utf8)))
        #expect(!jsonCommand.contains(Data("PEXPIRE".utf8)))
    }

    @Test
    func boundsValuePagesAndAvoidsRangeOverflow() {
        let page = RedisValuePage(offset: .max, count: .max, cursor: .max)

        #expect(page.count == 10_000)
        #expect(RedisDriver.boundedPageCount(.max) == 10_000)
        #expect(RedisDriver.redisRangeEnd(offset: .max, count: page.count) == .max)
    }
}
