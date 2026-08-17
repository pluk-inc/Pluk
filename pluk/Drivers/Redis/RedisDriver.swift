import Foundation
import Logging
import NIOCore
import NIOSSL
import Valkey

struct RedisDatabaseWrapper: DatabaseWrapper {
    let name: String
    let size: String?
    let tableCount: Int?
}

struct RedisCollectionWrapper: CollectionWrapper {
    let id: String
    let name: String
    let type: String
    let schema: String?
}

private struct RedisConnectionSettings: Sendable {
    let host: String
    let port: Int
    let username: String?
    let password: String?
    let database: Int
    let usesTLS: Bool
    let tlsServerName: String

    func selecting(database: Int) -> Self {
        .init(
            host: host,
            port: port,
            username: username,
            password: password,
            database: database,
            usesTLS: usesTLS,
            tlsServerName: tlsServerName
        )
    }
}

private struct RedisRawArgument: RESPRenderable, Hashable, Sendable {
    let bytes: Data
    var respEntries: Int { 1 }

    func encode(into commandEncoder: inout ValkeyCommandEncoder) {
        bytes.encode(into: &commandEncoder)
    }
}

private struct RedisRawCommand: ValkeyCommand {
    static let name = "RAW"

    let arguments: [RedisRawArgument]
    let affectedKeys: [ValkeyKey]
    let readOnly: Bool

    init(_ arguments: [Data], affectedKeys: [RedisKey] = [], readOnly: Bool = false) {
        self.arguments = arguments.map(RedisRawArgument.init(bytes:))
        self.affectedKeys = affectedKeys.map { ValkeyKey(ByteBuffer(bytes: $0.bytes)) }
        self.readOnly = readOnly
    }

    var keysAffected: [ValkeyKey] { affectedKeys }
    var isReadOnly: Bool { readOnly }

    func encode(into commandEncoder: inout ValkeyCommandEncoder) {
        commandEncoder.encodeArray(arguments)
    }
}

struct RedisLifecycleGeneration: Equatable, Sendable {
    private(set) var current: UInt64 = 0

    mutating func begin() -> UInt64 {
        current &+= 1
        return current
    }

    func isCurrent(_ generation: UInt64) -> Bool {
        current == generation
    }
}

actor RedisDriver: DatabaseDriver {
    typealias Database = RedisDatabaseWrapper
    typealias Collection = RedisCollectionWrapper

    private let logger = Logger(label: "redis-driver")
    private var client: ValkeyClient?
    private var clientGeneration: UInt64?
    private var lifecycleTask: Task<Void, Never>?
    private var settings: RedisConnectionSettings?
    private var lifecycleGeneration = RedisLifecycleGeneration()

    deinit {
        lifecycleTask?.cancel()
    }

    // MARK: - Connection

    func connect(to connectionUri: String) async throws -> RedisDatabaseWrapper {
        let parsed = try Self.parseConnectionURI(connectionUri)
        let generation = lifecycleGeneration.begin()
        try await replaceClient(using: parsed, generation: generation)
        let wrapper = try await databaseWrapper(for: parsed.database)
        try ensureCurrentLifecycle(generation)
        return wrapper
    }

    func disconnect() async {
        _ = lifecycleGeneration.begin()
        settings = nil
        await stopClient()
    }

    func reconnect() async throws {
        guard let settings else {
            throw DatabaseError.notConnected("No Redis connection settings are available")
        }
        let generation = lifecycleGeneration.begin()
        try await replaceClient(using: settings, generation: generation)
    }

    func ping(to connectionUri: String) async throws {
        let parsed = try Self.parseConnectionURI(connectionUri)
        let temporaryClient = try Self.makeClient(settings: parsed, logger: logger)
        let task = Task { await temporaryClient.run() }

        do {
            try await temporaryClient.ping()
            // valkey-swift currently ignores errors from the SELECT command it
            // sends while establishing a pooled connection. Validate the
            // configured logical database explicitly so an invalid index (or a
            // cluster endpoint, where SELECT is unsupported) cannot appear to
            // connect successfully on database 0.
            try await temporaryClient.select(index: parsed.database)
            task.cancel()
            await task.value
        } catch {
            task.cancel()
            await task.value
            throw Self.connectionError(error, host: parsed.host, port: parsed.port)
        }
    }

    func getBuildInfo() async throws -> BuildInfo {
        let response = try await execute(arguments: Self.arguments("INFO", "SERVER"), readOnly: true)
        let info = try Self.data(from: response)
        let text = String(decoding: info, as: UTF8.self)
        let version = Self.infoValue(named: "redis_version", in: text)
            ?? Self.infoValue(named: "valkey_version", in: text)
            ?? "Unknown"
        return BuildInfo(version: version, databaseType: .redis)
    }

    func switchDatabase(to databaseName: String) async throws {
        guard let database = Int(databaseName), database >= 0 else {
            throw DatabaseError.configurationError("Redis database must be a non-negative integer")
        }
        guard let settings else {
            throw DatabaseError.notConnected("No active Redis connection")
        }

        let updated = settings.selecting(database: database)
        let generation = lifecycleGeneration.begin()
        try await replaceClient(using: updated, generation: generation)
    }

    private func replaceClient(
        using settings: RedisConnectionSettings,
        generation: UInt64
    ) async throws {
        try ensureCurrentLifecycle(generation)
        await stopClient()
        try ensureCurrentLifecycle(generation)

        let newClient = try Self.makeClient(settings: settings, logger: logger)
        let task = Task { await newClient.run() }
        client = newClient
        clientGeneration = generation
        lifecycleTask = task

        do {
            try await newClient.ping()
            // Connection setup can swallow SELECT failures, then let PING
            // succeed against database 0. An explicit SELECT makes database
            // replacement transactional from Pluk's point of view: settings
            // are published only after the server accepts the requested DB.
            try await newClient.select(index: settings.database)
        } catch {
            await stopClient(ownedBy: generation)
            guard lifecycleGeneration.isCurrent(generation) else {
                throw CancellationError()
            }
            throw Self.connectionError(error, host: settings.host, port: settings.port)
        }

        try ensureCurrentLifecycle(generation, client: newClient)
        self.settings = settings
        logger.info("Connected to Redis at \(settings.host):\(settings.port), database \(settings.database)")
    }

    private func stopClient(ownedBy expectedGeneration: UInt64? = nil) async {
        if let expectedGeneration, clientGeneration != expectedGeneration {
            return
        }

        client = nil
        clientGeneration = nil
        let task = lifecycleTask
        lifecycleTask = nil
        task?.cancel()
        await task?.value
    }

    private func ensureCurrentLifecycle(
        _ generation: UInt64,
        client expectedClient: ValkeyClient? = nil
    ) throws {
        guard lifecycleGeneration.isCurrent(generation) else {
            throw CancellationError()
        }
        if let expectedClient {
            guard clientGeneration == generation, client === expectedClient else {
                throw CancellationError()
            }
        }
    }

    private static func makeClient(settings: RedisConnectionSettings, logger: Logger) throws -> ValkeyClient {
        let authentication = settings.password.map {
            ValkeyClientConfiguration.Authentication(
                username: settings.username ?? "default",
                password: $0
            )
        }

        let tls: ValkeyClientConfiguration.TLS
        if settings.usesTLS {
            var tlsConfiguration = TLSConfiguration.makeClientConfiguration()
            tlsConfiguration.certificateVerification = .fullVerification
            tls = try .enable(tlsConfiguration, tlsServerName: settings.tlsServerName)
        } else {
            tls = .disable
        }

        let configuration = ValkeyClientConfiguration(
            authentication: authentication,
            connectionPool: .init(
                minimumConnectionCount: 0,
                maximumConnectionSoftLimit: 4,
                maximumConnectionHardLimit: 8,
                // A desktop connection test must surface DNS, TCP, and TLS
                // failures promptly instead of waiting for the pool's
                // 60-second default circuit-breaker window.
                circuitBreakerTripAfter: .seconds(8),
                maximumConcurrentConnectionRequests: 4
            ),
            commandTimeout: .seconds(30),
            blockingCommandTimeout: .seconds(120),
            tls: tls,
            databaseNumber: settings.database,
            enableClientCapaRedirect: false
        )

        return ValkeyClient(
            .hostname(settings.host, port: settings.port),
            configuration: configuration,
            logger: logger
        )
    }

    nonisolated private static func parseConnectionURI(_ connectionURI: String) throws -> RedisConnectionSettings {
        let parsed: ParsedRedisConnectionURL
        do {
            parsed = try ConnectionURLParser.parseRedis(connectionURI)
        } catch {
            throw DatabaseError.invalidConnectionString(error.localizedDescription)
        }

        let tlsServerName = URLComponents(string: connectionURI)?
            .queryItems?
            .last { $0.name.lowercased() == "pluk-tls-server-name" }?
            .value
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? parsed.hostname

        return RedisConnectionSettings(
            host: parsed.hostname,
            port: parsed.port,
            username: parsed.username,
            password: parsed.password,
            database: parsed.databaseIndex,
            usesTLS: parsed.usesTLS,
            tlsServerName: tlsServerName
        )
    }

    // MARK: - Redis UI API

    func scanRedisKeys(
        cursor: UInt64,
        pattern: String?,
        type: RedisKeyType?,
        count: Int
    ) async throws -> RedisScanPage {
        let safeCount = min(max(count, 1), 10_000)
        let response = try await execute(
            arguments: Self.scanCommandArguments(
                cursor: cursor,
                pattern: pattern,
                type: type,
                count: safeCount
            ),
            readOnly: true
        )
        return try Self.decodeScanPage(from: response)
    }

    func redisKeyMetadata(for key: RedisKey) async throws -> RedisKeyMetadata {
        let commands: [any ValkeyCommand] = [
            RedisRawCommand(Self.arguments("TYPE") + [key.bytes], affectedKeys: [key], readOnly: true),
            RedisRawCommand(Self.arguments("PTTL") + [key.bytes], affectedKeys: [key], readOnly: true),
            RedisRawCommand(Self.arguments("MEMORY", "USAGE") + [key.bytes], affectedKeys: [key], readOnly: true),
            RedisRawCommand(Self.arguments("OBJECT", "ENCODING") + [key.bytes], affectedKeys: [key], readOnly: true),
        ]
        let results = try await requireClient().execute(commands)
        guard results.count == 4 else {
            throw DatabaseError.operationFailed("Redis returned an incomplete metadata response")
        }

        let typeToken = try Self.unwrap(results[0])
        let ttlToken = try Self.unwrap(results[1])

        let memoryUsageBytes: Int64?
        if case .success(let memoryToken) = results[2] {
            memoryUsageBytes = (try? Self.optionalInt64(from: memoryToken)) ?? nil
        } else {
            memoryUsageBytes = nil
        }

        let encoding: String?
        if case .success(let encodingToken) = results[3],
           let bytes = (try? Self.optionalData(from: encodingToken)) ?? nil {
            encoding = String(decoding: bytes, as: UTF8.self)
        } else {
            encoding = nil
        }

        let serverType = String(decoding: try Self.data(from: typeToken), as: UTF8.self)
        let rawTTL = try Self.int64(from: ttlToken)
        return RedisKeyMetadata(
            key: key,
            type: RedisKeyType(serverName: serverType),
            ttlMilliseconds: rawTTL >= 0 ? rawTTL : nil,
            memoryUsageBytes: memoryUsageBytes,
            encoding: encoding
        )
    }

    func redisValue(for key: RedisKey, page: RedisValuePage) async throws -> RedisValue {
        let keyType = try await redisKeyType(for: key)
        let pageCount = Self.boundedPageCount(page.count)
        let pageOffset = max(0, page.offset)
        let pageCursor = page.cursor

        switch keyType {
        case .none:
            return .none

        case .string:
            let response = try await execute(
                arguments: Self.arguments("GET") + [key.bytes],
                affectedKeys: [key],
                readOnly: true
            )
            return .string(try Self.data(from: response))

        case .hash:
            let response = try await execute(
                arguments: Self.arguments("HSCAN") + [
                    key.bytes,
                    Self.data(pageCursor),
                    Self.data("COUNT"),
                    Self.data(pageCount),
                ],
                affectedKeys: [key],
                readOnly: true
            )
            let (nextCursor, values) = try Self.scanResponse(from: response)
            let totalCount = try await integerCommand("HLEN", key: key)
            return .hash(
                entries: try Self.hashEntries(from: values),
                totalCount: totalCount,
                nextCursor: nextCursor
            )

        case .list:
            let stop = Self.redisRangeEnd(offset: pageOffset, count: pageCount)
            let response = try await execute(
                arguments: Self.arguments("LRANGE") + [key.bytes, Self.data(pageOffset), Self.data(stop)],
                affectedKeys: [key],
                readOnly: true
            )
            return .list(
                elements: try Self.dataArray(from: response),
                totalCount: try await integerCommand("LLEN", key: key),
                offset: pageOffset
            )

        case .set:
            let response = try await execute(
                arguments: Self.arguments("SSCAN") + [
                    key.bytes,
                    Self.data(pageCursor),
                    Self.data("COUNT"),
                    Self.data(pageCount),
                ],
                affectedKeys: [key],
                readOnly: true
            )
            let (nextCursor, values) = try Self.scanResponse(from: response)
            return .set(
                members: try values.map(Self.data(from:)),
                totalCount: try await integerCommand("SCARD", key: key),
                nextCursor: nextCursor
            )

        case .sortedSet:
            let stop = Self.redisRangeEnd(offset: pageOffset, count: pageCount)
            let response = try await execute(
                arguments: Self.arguments("ZRANGE") + [
                    key.bytes,
                    Self.data(pageOffset),
                    Self.data(stop),
                    Self.data("WITHSCORES"),
                ],
                affectedKeys: [key],
                readOnly: true
            )
            return .sortedSet(
                entries: try Self.sortedSetEntries(from: response),
                totalCount: try await integerCommand("ZCARD", key: key),
                offset: pageOffset
            )

        case .stream:
            // XRANGE has an ID cursor rather than a numeric offset. Fetching a bounded
            // prefix keeps this API simple while the dedicated editor owns navigation.
            let fetchCount = min(Self.saturatingAdd(pageOffset, pageCount), 10_000)
            let response = try await execute(
                arguments: Self.arguments("XRANGE") + [
                    key.bytes,
                    Self.data("-"),
                    Self.data("+"),
                    Self.data("COUNT"),
                    Self.data(fetchCount),
                ],
                affectedKeys: [key],
                readOnly: true
            )
            let entries = try Self.streamEntries(from: response)
            return .stream(
                entries: Array(entries.dropFirst(min(pageOffset, entries.count)).prefix(pageCount)),
                totalCount: try await integerCommand("XLEN", key: key)
            )

        case .json:
            let response = try await execute(
                arguments: Self.arguments("JSON.GET") + [key.bytes],
                affectedKeys: [key],
                readOnly: true
            )
            return .json(try Self.data(from: response))

        case .unknown:
            let response = try await execute(
                arguments: Self.arguments("DUMP") + [key.bytes],
                affectedKeys: [key],
                readOnly: true
            )
            return .unsupported(type: keyType, raw: Self.commandValue(from: response))
        }
    }

    func updateRedisValue(_ update: RedisValueUpdate, for key: RedisKey, preserveTTL: Bool) async throws {
        guard let mutationArguments = try Self.mutationCommandArguments(
            for: update,
            key: key,
            preserveTTL: preserveTTL
        ) else {
            return
        }
        _ = try await execute(arguments: mutationArguments, affectedKeys: [key])
    }

    func renameRedisKey(_ key: RedisKey, to newKey: RedisKey, overwrite: Bool) async throws {
        let command = overwrite ? "RENAME" : "RENAMENX"
        let response = try await execute(
            arguments: Self.arguments(command) + [key.bytes, newKey.bytes],
            affectedKeys: [key, newKey]
        )
        if !overwrite, try Self.int64(from: response) == 0 {
            throw DatabaseError.operationFailed("A Redis key with the destination name already exists")
        }
    }

    func deleteRedisKeys(_ keys: [RedisKey], asynchronously: Bool) async throws -> Int {
        guard !keys.isEmpty else { return 0 }
        let response = try await execute(
            arguments: Self.arguments(asynchronously ? "UNLINK" : "DEL") + keys.map(\.bytes),
            affectedKeys: keys
        )
        return try Self.int(from: response)
    }

    func setRedisExpiration(for key: RedisKey, milliseconds: Int64?) async throws -> Bool {
        let arguments: [Data]
        if let milliseconds {
            guard milliseconds >= 0 else {
                throw DatabaseError.operationFailed("Redis expiration cannot be negative")
            }
            arguments = Self.arguments("PEXPIRE") + [key.bytes, Self.data(milliseconds)]
        } else {
            arguments = Self.arguments("PERSIST") + [key.bytes]
        }

        let response = try await execute(arguments: arguments, affectedKeys: [key])
        return try Self.int64(from: response) == 1
    }

    func executeRedisCommand(_ command: RedisCommand) async throws -> RedisCommandResult {
        guard !command.arguments.isEmpty, !command.arguments[0].isEmpty else {
            throw DatabaseError.operationFailed("Redis command cannot be empty")
        }

        let startedAt = ContinuousClock.now
        let response = try await execute(arguments: command.arguments)
        let duration = startedAt.duration(to: .now)
        let milliseconds = Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
        return RedisCommandResult(
            value: Self.commandValue(from: response),
            durationMilliseconds: milliseconds
        )
    }

    func parseRedisCommand(_ commandText: String) async throws -> RedisCommand {
        try RedisCommandTokenizer.tokenize(commandText).transportCommand
    }

    // MARK: - DatabaseDriver compatibility

    func listDatabases() async throws -> [RedisDatabaseWrapper] {
        let current = settings?.database ?? 0
        do {
            let response = try await execute(arguments: Self.arguments("INFO", "KEYSPACE"), readOnly: true)
            let text = String(decoding: try Self.data(from: response), as: UTF8.self)
            let databases = text.split(whereSeparator: \.isNewline).compactMap { line -> RedisDatabaseWrapper? in
                guard line.hasPrefix("db"), let colon = line.firstIndex(of: ":") else { return nil }
                let name = String(line[line.index(line.startIndex, offsetBy: 2)..<colon])
                guard Int(name) != nil else { return nil }
                let metadata = line[line.index(after: colon)...]
                let keys = metadata.split(separator: ",").first(where: { $0.hasPrefix("keys=") })
                    .flatMap { Int($0.dropFirst(5)) }
                return RedisDatabaseWrapper(name: name, size: nil, tableCount: keys)
            }
            if databases.isEmpty {
                return [try await databaseWrapper(for: current)]
            }
            return databases.sorted { (Int($0.name) ?? 0) < (Int($1.name) ?? 0) }
        } catch {
            // Managed services may deny INFO; the selected logical DB remains usable.
            return [try await databaseWrapper(for: current)]
        }
    }

    func getDatabaseMetadata() async throws -> [RedisDatabaseWrapper] {
        try await listDatabases()
    }

    func listCollections(schema: String?) async throws -> [RedisCollectionWrapper] {
        []
    }

    func getDocumentCount(for collectionName: String, filter: DatabaseDocument) async throws -> Int {
        try await integerCommand("DBSIZE")
    }

    func findDocuments(in collectionName: String, filter: DatabaseDocument) async throws -> [QueryResult] {
        [try await findDocuments(in: collectionName, filter: filter, skip: 0, limit: 300)]
    }

    func findDocuments(
        in collectionName: String,
        filter: DatabaseDocument,
        skip: Int,
        limit: Int
    ) async throws -> QueryResult {
        try await findDocuments(
            in: collectionName,
            databaseSchema: nil,
            filter: filter,
            skip: skip,
            limit: limit,
            sortBy: nil,
            ascending: nil
        )
    }

    func findDocuments(
        in collectionName: String,
        databaseSchema: String?,
        filter: DatabaseDocument,
        skip: Int,
        limit: Int,
        sortBy: String?,
        ascending: Bool?
    ) async throws -> QueryResult {
        let pattern = filter["rawQuery"]?.stringValue
        var cursor: UInt64 = 0
        var keys: [RedisKey] = []
        repeat {
            let page = try await scanRedisKeys(cursor: cursor, pattern: pattern, type: nil, count: min(max(limit, 1), 1_000))
            cursor = page.nextCursor
            keys.append(contentsOf: page.keys)
        } while cursor != 0 && keys.count < skip + limit

        let selected = Array(keys.dropFirst(max(skip, 0)).prefix(max(limit, 0)))
        return Self.keyQueryResult(selected)
    }

    func createDocument(in collectionName: String, databaseSchema: String?, document: DatabaseDocument) async throws {
        throw DatabaseError.notImplemented("Use Redis type-specific editing to create keys")
    }

    func updateDocument(
        in collectionName: String,
        databaseSchema: String?,
        id: DatabaseRecordID,
        data: DatabaseDocument
    ) async throws {
        throw DatabaseError.notImplemented("Use Redis type-specific editing to update keys")
    }

    func deleteDocument(
        in collectionName: String,
        databaseSchema: String?,
        id: DatabaseRecordID
    ) async throws {
        let key = RedisKey(id.value.description)
        _ = try await deleteRedisKeys([key], asynchronously: true)
    }

    func executeRawQuery(_ query: String, databaseSchema: String?) async throws -> [QueryResult] {
        let analysis = try RedisCommandSafety.analyze(query)
        guard analysis.category == .readOnly,
              analysis.executionPolicy == .allow else {
            throw DatabaseError.operationFailed(
                "Use the Redis command workspace to confirm write or administrative commands"
            )
        }
        return [Self.queryResult(try await executeRedisCommand(analysis.transportCommand))]
    }

    func getSchema(for collectionName: String, schema: String?) async throws -> DatabaseSchemaResult? { nil }
    func getInformationSchema() async throws -> [InformationSchema] { [] }
    func getIndexes(for collectionName: String, schema: String?) async throws -> [DatabaseIndexInfo] { [] }

    func createCollection(named collectionName: String) async throws {
        throw DatabaseError.notImplemented("Redis does not have collections")
    }

    func renameCollection(databaseSchema: String?, from oldName: String, to newName: String) async throws {
        try await renameRedisKey(RedisKey(oldName), to: RedisKey(newName), overwrite: false)
    }

    func deleteCollection(named collectionName: String, databaseSchema: String?) async throws {
        _ = try await deleteRedisKeys([RedisKey(collectionName)], asynchronously: true)
    }

    func buildSystemPrompt(for collectionName: String, databaseSchema: String?) async throws -> String {
        """
        You are working with Redis database \(settings?.database ?? 0). Use Redis commands, prefer SCAN over KEYS,
        preserve TTLs when editing values, and never run destructive commands unless the user explicitly asks.
        """
    }

    func buildAICommandPromptSystemPrompt(_ message: String) async throws -> String {
        "Return one valid Redis command for the request. Do not wrap the command in Markdown."
    }

    // MARK: - Command helpers

    nonisolated static func scanCommandArguments(
        cursor: UInt64,
        pattern: String?,
        type: RedisKeyType?,
        count: Int
    ) -> [Data] {
        var arguments = Self.arguments("SCAN") + [Self.data(cursor)]
        if let pattern, !pattern.isEmpty {
            arguments += Self.arguments("MATCH") + [Self.data(pattern)]
        }
        arguments += Self.arguments("COUNT") + [Self.data(count)]
        if let type = type?.scanFilter {
            arguments += Self.arguments("TYPE") + [Self.data(type)]
        }
        return arguments
    }

    nonisolated static func boundedPageCount(_ count: Int) -> Int {
        min(max(count, 1), 10_000)
    }

    nonisolated static func redisRangeEnd(offset: Int, count: Int) -> Int {
        saturatingAdd(max(offset, 0), boundedPageCount(count) - 1)
    }

    nonisolated private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : result
    }

    nonisolated static func decodeScanPage(from token: RESPToken) throws -> RedisScanPage {
        let (nextCursor, values) = try Self.scanResponse(from: token)
        return RedisScanPage(
            nextCursor: nextCursor,
            keys: try values.map { RedisKey(bytes: try Self.data(from: $0)) }
        )
    }

    nonisolated static func mutationCommandArguments(
        for update: RedisValueUpdate,
        key: RedisKey,
        preserveTTL: Bool
    ) throws -> [Data]? {
        switch update {
        case .string(let value):
            return Self.arguments("SET") + [key.bytes, value]
                + (preserveTTL ? Self.arguments("KEEPTTL") : [])

        case .json(let value):
            do {
                _ = try JSONSerialization.jsonObject(with: value, options: [.fragmentsAllowed])
            } catch {
                throw DatabaseError.operationFailed("RedisJSON value is not valid JSON: \(error.localizedDescription)")
            }
            // JSON.SET updates an existing module value in place, as do the
            // collection mutations below, so Redis retains the key's expiry.
            return Self.arguments("JSON.SET") + [key.bytes, Self.data("$"), value]

        case .hashField(let field, let value):
            return Self.arguments("HSET") + [key.bytes, field, value]

        case .deleteHashField(let field):
            return Self.arguments("HDEL") + [key.bytes, field]

        case .listElement(let index, let value):
            return Self.arguments("LSET") + [key.bytes, Self.data(index), value]

        case .appendList(let values, let toHead):
            guard !values.isEmpty else { return nil }
            return Self.arguments(toHead ? "LPUSH" : "RPUSH") + [key.bytes] + values

        case .setMember(let member, let isPresent):
            return Self.arguments(isPresent ? "SADD" : "SREM") + [key.bytes, member]

        case .sortedSetMember(let member, let score):
            if let score {
                return Self.arguments("ZADD") + [key.bytes, Self.data(score), member]
            }
            return Self.arguments("ZREM") + [key.bytes, member]

        case .appendStream(let fields, let id):
            guard !fields.isEmpty else {
                throw DatabaseError.operationFailed("A Redis stream entry must contain at least one field")
            }
            let fieldArguments = fields.flatMap { [$0.field, $0.value] }
            return Self.arguments("XADD") + [key.bytes, id ?? Self.data("*")] + fieldArguments

        case .deleteStreamEntry(let id):
            return Self.arguments("XDEL") + [key.bytes, id]
        }
    }

    private func redisKeyType(for key: RedisKey) async throws -> RedisKeyType {
        let response = try await execute(
            arguments: Self.arguments("TYPE") + [key.bytes],
            affectedKeys: [key],
            readOnly: true
        )
        return RedisKeyType(
            serverName: String(decoding: try Self.data(from: response), as: UTF8.self)
        )
    }

    private func requireClient() throws -> ValkeyClient {
        guard let client else {
            throw DatabaseError.notConnected("No active Redis connection")
        }
        return client
    }

    private func execute(
        arguments: [Data],
        affectedKeys: [RedisKey] = [],
        readOnly: Bool = false
    ) async throws -> RESPToken {
        guard !arguments.isEmpty else {
            throw DatabaseError.operationFailed("Redis command cannot be empty")
        }
        do {
            return try await requireClient().execute(
                RedisRawCommand(arguments, affectedKeys: affectedKeys, readOnly: readOnly)
            )
        } catch let error as DatabaseError {
            throw error
        } catch {
            throw Self.operationError(error)
        }
    }

    private func integerCommand(_ command: String, key: RedisKey? = nil) async throws -> Int {
        var arguments = Self.arguments(command)
        if let key { arguments.append(key.bytes) }
        let response = try await execute(
            arguments: arguments,
            affectedKeys: key.map { [$0] } ?? [],
            readOnly: true
        )
        return try Self.int(from: response)
    }

    private func databaseWrapper(for database: Int) async throws -> RedisDatabaseWrapper {
        let count = try? await integerCommand("DBSIZE")
        return RedisDatabaseWrapper(name: String(database), size: nil, tableCount: count)
    }

    nonisolated private static func arguments(_ values: String...) -> [Data] {
        values.map(data(_:))
    }

    nonisolated private static func data<T: LosslessStringConvertible>(_ value: T) -> Data {
        Data(String(value).utf8)
    }

    nonisolated private static func data(_ value: String) -> Data {
        Data(value.utf8)
    }

    nonisolated private static func unwrap(_ result: Result<RESPToken, ValkeyClientError>) throws -> RESPToken {
        do {
            return try result.get()
        } catch {
            throw operationError(error)
        }
    }

    nonisolated private static func operationError(_ error: Error) -> DatabaseError {
        let message: String
        if let valkeyError = error as? ValkeyClientError {
            message = valkeyError.message ?? valkeyError.errorCode.description
        } else {
            message = error.localizedDescription
        }
        let uppercase = message.uppercased()
        if uppercase.contains("NOAUTH") || uppercase.contains("WRONGPASS") || uppercase.contains("AUTHENTICATION") {
            return DatabaseError(code: .authenticationFailed, message: message, underlyingError: error)
        }
        return DatabaseError(code: .operationFailed, message: message, underlyingError: error)
    }

    nonisolated private static func connectionError(_ error: Error, host: String, port: Int) -> DatabaseError {
        let mapped = operationError(error)
        if mapped.code == .authenticationFailed { return mapped }
        return DatabaseError(
            code: .connectionFailed,
            message: "Could not connect to Redis at \(host):\(port): \(mapped.message)",
            underlyingError: error
        )
    }

    nonisolated private static func data(from token: RESPToken) throws -> Data {
        switch token.value {
        case .simpleString(let buffer), .bulkString(let buffer), .bigNumber(let buffer):
            return Data(buffer.readableBytesView)
        case .verbatimString(let buffer):
            let bytes = Data(buffer.readableBytesView)
            return bytes.count >= 4 ? Data(bytes.dropFirst(4)) : bytes
        default:
            throw DatabaseError.operationFailed("Redis response was not a string")
        }
    }

    nonisolated private static func optionalData(from token: RESPToken) throws -> Data? {
        if case .null = token.value { return nil }
        return try data(from: token)
    }

    nonisolated private static func int64(from token: RESPToken) throws -> Int64 {
        switch token.value {
        case .number(let value): return value
        case .simpleString, .bulkString, .bigNumber:
            guard let value = Int64(String(decoding: try data(from: token), as: UTF8.self)) else {
                throw DatabaseError.operationFailed("Redis response was not an integer")
            }
            return value
        default:
            throw DatabaseError.operationFailed("Redis response was not an integer")
        }
    }

    nonisolated private static func optionalInt64(from token: RESPToken) throws -> Int64? {
        if case .null = token.value { return nil }
        return try int64(from: token)
    }

    nonisolated private static func int(from token: RESPToken) throws -> Int {
        let value = try int64(from: token)
        guard let converted = Int(exactly: value) else {
            throw DatabaseError.operationFailed("Redis integer response is out of range")
        }
        return converted
    }

    nonisolated private static func tokenArray(from token: RESPToken) throws -> [RESPToken] {
        switch token.value {
        case .array(let values), .set(let values), .push(let values): Array(values)
        default: throw DatabaseError.operationFailed("Redis response was not an array")
        }
    }

    nonisolated private static func dataArray(from token: RESPToken) throws -> [Data] {
        try tokenArray(from: token).map(data(from:))
    }

    nonisolated private static func scanResponse(from token: RESPToken) throws -> (UInt64, [RESPToken]) {
        let values = try tokenArray(from: token)
        guard values.count == 2 else {
            throw DatabaseError.operationFailed("Redis returned an invalid SCAN response")
        }
        return (try uint64(from: values[0]), try tokenArray(from: values[1]))
    }

    nonisolated private static func uint64(from token: RESPToken) throws -> UInt64 {
        switch token.value {
        case .number(let value) where value >= 0:
            return UInt64(value)
        case .simpleString, .bulkString, .bigNumber:
            guard let value = UInt64(String(decoding: try data(from: token), as: UTF8.self)) else {
                throw DatabaseError.operationFailed("Redis response was not an unsigned integer")
            }
            return value
        default:
            throw DatabaseError.operationFailed("Redis response was not an unsigned integer")
        }
    }

    nonisolated private static func hashEntries(from tokens: [RESPToken]) throws -> [RedisHashEntry] {
        guard tokens.count.isMultiple(of: 2) else {
            throw DatabaseError.operationFailed("Redis returned an invalid hash response")
        }
        return try stride(from: 0, to: tokens.count, by: 2).map {
            RedisHashEntry(field: try data(from: tokens[$0]), value: try data(from: tokens[$0 + 1]))
        }
    }

    nonisolated private static func sortedSetEntries(from token: RESPToken) throws -> [RedisSortedSetEntry] {
        let values = try tokenArray(from: token)
        if values.allSatisfy({ if case .array = $0.value { true } else { false } }) {
            return try values.map { pair in
                let elements = try tokenArray(from: pair)
                guard elements.count == 2 else {
                    throw DatabaseError.operationFailed("Redis returned an invalid sorted-set response")
                }
                return RedisSortedSetEntry(
                    member: try data(from: elements[0]),
                    score: try double(from: elements[1])
                )
            }
        }
        guard values.count.isMultiple(of: 2) else {
            throw DatabaseError.operationFailed("Redis returned an invalid sorted-set response")
        }
        return try stride(from: 0, to: values.count, by: 2).map {
            RedisSortedSetEntry(member: try data(from: values[$0]), score: try double(from: values[$0 + 1]))
        }
    }

    nonisolated private static func double(from token: RESPToken) throws -> Double {
        if case .double(let value) = token.value { return value }
        guard let value = Double(String(decoding: try data(from: token), as: UTF8.self)) else {
            throw DatabaseError.operationFailed("Redis response was not a floating-point number")
        }
        return value
    }

    nonisolated private static func streamEntries(from token: RESPToken) throws -> [RedisStreamEntry] {
        try tokenArray(from: token).map { entryToken in
            let entry = try tokenArray(from: entryToken)
            guard entry.count == 2 else {
                throw DatabaseError.operationFailed("Redis returned an invalid stream entry")
            }
            return RedisStreamEntry(
                id: try data(from: entry[0]),
                fields: try hashEntries(from: tokenArray(from: entry[1]))
            )
        }
    }

    nonisolated static func commandValue(from token: RESPToken) -> RedisCommandValue {
        switch token.value {
        case .null:
            .null
        case .simpleString(let buffer):
            .simpleString(Data(buffer.readableBytesView))
        case .bulkString(let buffer):
            .bulkString(Data(buffer.readableBytesView))
        case .simpleError(let buffer):
            .simpleError(Data(buffer.readableBytesView))
        case .bulkError(let buffer):
            .bulkError(Data(buffer.readableBytesView))
        case .verbatimString(let buffer):
            verbatimValue(buffer)
        case .number(let value):
            .integer(value)
        case .double(let value):
            .double(value)
        case .boolean(let value):
            .boolean(value)
        case .bigNumber(let buffer):
            .bigNumber(Data(buffer.readableBytesView))
        case .array(let values):
            .array(values.map(commandValue(from:)))
        case .map(let values):
            .map(values.map { RedisCommandMapEntry(key: commandValue(from: $0.key), value: commandValue(from: $0.value)) })
        case .set(let values):
            .set(values.map(commandValue(from:)))
        case .push(let values):
            .push(values.map(commandValue(from:)))
        case .attribute(let values):
            .attribute(values.map { RedisCommandMapEntry(key: commandValue(from: $0.key), value: commandValue(from: $0.value)) })
        }
    }

    nonisolated private static func verbatimValue(_ buffer: ByteBuffer) -> RedisCommandValue {
        let bytes = Data(buffer.readableBytesView)
        guard bytes.count >= 4, bytes[bytes.index(bytes.startIndex, offsetBy: 3)] == 58 else {
            return .verbatimString(format: nil, data: bytes)
        }
        let formatData = bytes.prefix(3)
        return .verbatimString(
            format: String(data: formatData, encoding: .utf8),
            data: Data(bytes.dropFirst(4))
        )
    }

    nonisolated private static func infoValue(named key: String, in text: String) -> String? {
        let prefix = key + ":"
        return text.split(whereSeparator: \.isNewline)
            .first(where: { $0.hasPrefix(prefix) })
            .map { String($0.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    nonisolated private static func keyQueryResult(_ keys: [RedisKey]) -> QueryResult {
        let column = QueryColumnInfo(name: "key", dataType: "redis-key", format: nil, index: 0)
        let rows = keys.map { key in
            ["key": QueryRowInfo(value: .data(key.bytes), dataType: "redis-key", format: nil)]
        }
        let rawRows: [DatabaseRawRow] = keys.map { ["key": .data($0.bytes)] }
        return QueryResult(columns: [column], rows: rows, totalCount: rows.count, rawRows: rawRows)
    }

    nonisolated private static func queryResult(_ result: RedisCommandResult) -> QueryResult {
        switch result.value {
        case .map(let entries), .attribute(let entries):
            let columns = [
                QueryColumnInfo(name: "key", dataType: "RESP3", format: nil, index: 0),
                QueryColumnInfo(name: "value", dataType: "RESP3", format: nil, index: 1),
            ]
            let rows = entries.map {
                [
                    "key": QueryRowInfo(value: databaseValue(from: $0.key), dataType: "RESP3", format: nil),
                    "value": QueryRowInfo(value: databaseValue(from: $0.value), dataType: "RESP3", format: nil),
                ]
            }
            let rawRows: [DatabaseRawRow] = entries.map {
                ["key": databaseValue(from: $0.key), "value": databaseValue(from: $0.value)]
            }
            return QueryResult(columns: columns, rows: rows, totalCount: rows.count, rawRows: rawRows)

        case .array(let values), .set(let values), .push(let values):
            return valueRows(values)

        default:
            return valueRows([result.value])
        }
    }

    nonisolated private static func valueRows(_ values: [RedisCommandValue]) -> QueryResult {
        let column = QueryColumnInfo(name: "result", dataType: "RESP3", format: nil, index: 0)
        let rows = values.map {
            ["result": QueryRowInfo(value: databaseValue(from: $0), dataType: "RESP3", format: nil)]
        }
        let rawRows: [DatabaseRawRow] = values.map { ["result": databaseValue(from: $0)] }
        return QueryResult(columns: [column], rows: rows, totalCount: rows.count, rawRows: rawRows)
    }

    nonisolated private static func databaseValue(from value: RedisCommandValue) -> DatabaseValue {
        switch value {
        case .null: .null
        case .simpleString(let data), .bulkString(let data), .simpleError(let data), .bulkError(let data), .bigNumber(let data): .data(data)
        case .verbatimString(_, let data): .data(data)
        case .integer(let value): .int64(value)
        case .double(let value): .double(value)
        case .boolean(let value): .bool(value)
        case .array(let values), .set(let values), .push(let values): .array(values.map(databaseValue(from:)))
        case .map(let entries), .attribute(let entries):
            .array(entries.map {
                .object([
                    "key": databaseValue(from: $0.key),
                    "value": databaseValue(from: $0.value),
                ])
            })
        }
    }
}
