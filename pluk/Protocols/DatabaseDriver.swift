import Foundation

typealias DatabaseDocument = [String: DatabaseValue]
typealias DatabaseRawRow = [String: DatabaseValue?]

enum DatabaseValue: Hashable, Sendable, Codable, CustomStringConvertible {
    case null
    case bool(Bool)
    case int(Int)
    case int64(Int64)
    case double(Double)
    case string(String)
    case date(Date)
    case data(Data)
    case uuid(UUID)
    case decimalString(String)
    case objectID(String)
    case array([DatabaseValue])
    case object([String: DatabaseValue])

    init?(_ value: Any?) {
        switch value {
        case nil:
            self = .null
        case is NSNull:
            self = .null
        case let value as DatabaseValue:
            self = value
        case let value as Bool:
            self = .bool(value)
        case let value as Int:
            self = .int(value)
        case let value as Int64:
            self = .int64(value)
        case let value as Int32:
            self = .int64(Int64(value))
        case let value as Int16:
            self = .int(Int(value))
        case let value as Int8:
            self = .int(Int(value))
        case let value as UInt:
            self = .int64(Int64(value))
        case let value as UInt64:
            guard value <= UInt64(Int64.max) else { return nil }
            self = .int64(Int64(value))
        case let value as UInt32:
            self = .int64(Int64(value))
        case let value as UInt16:
            self = .int(Int(value))
        case let value as UInt8:
            self = .int(Int(value))
        case let value as Double:
            self = .double(value)
        case let value as Float:
            self = .double(Double(value))
        case let value as String:
            self = .string(value)
        case let value as Date:
            self = .date(value)
        case let value as Data:
            self = .data(value)
        case let value as UUID:
            self = .uuid(value)
        case let value as Decimal:
            self = .decimalString(NSDecimalNumber(decimal: value).stringValue)
        case let value as [DatabaseValue]:
            self = .array(value)
        case let value as [Any]:
            let converted = value.compactMap(DatabaseValue.init)
            guard converted.count == value.count else { return nil }
            self = .array(converted)
        case let value as [String: DatabaseValue]:
            self = .object(value)
        case let value as [String: Any]:
            var converted: [String: DatabaseValue] = [:]
            for (key, nestedValue) in value {
                guard let nested = DatabaseValue(nestedValue) else { return nil }
                converted[key] = nested
            }
            self = .object(converted)
        default:
            return nil
        }
    }

    var anyValue: Any? {
        switch self {
        case .null:
            nil
        case .bool(let value):
            value
        case .int(let value):
            value
        case .int64(let value):
            value
        case .double(let value):
            value
        case .string(let value):
            value
        case .date(let value):
            value
        case .data(let value):
            value
        case .uuid(let value):
            value
        case .decimalString(let value):
            value
        case .objectID(let value):
            value
        case .array(let values):
            values.compactMap(\.anyValue)
        case .object(let values):
            values.mapValues(\.anyValue)
        }
    }

    var stringValue: String? {
        switch self {
        case .string(let value), .decimalString(let value), .objectID(let value):
            value
        case .uuid(let value):
            value.uuidString
        default:
            nil
        }
    }

    var int64Value: Int64? {
        switch self {
        case .int(let value):
            Int64(value)
        case .int64(let value):
            value
        case .double(let value):
            Int64(value)
        case .string(let value), .decimalString(let value):
            Int64(value)
        default:
            nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .int(let value):
            Double(value)
        case .int64(let value):
            Double(value)
        case .double(let value):
            value
        case .string(let value), .decimalString(let value):
            Double(value)
        default:
            nil
        }
    }

    var description: String {
        switch self {
        case .null:
            "NULL"
        case .bool(let value):
            value.description
        case .int(let value):
            value.description
        case .int64(let value):
            value.description
        case .double(let value):
            value.description
        case .string(let value):
            value
        case .date(let value):
            value.description
        case .data(let value):
            value.base64EncodedString()
        case .uuid(let value):
            value.uuidString
        case .decimalString(let value):
            value
        case .objectID(let value):
            value
        case .array(let values):
            "[\(values.map(\.description).joined(separator: ", "))]"
        case .object(let values):
            "{\(values.map { "\($0): \($1.description)" }.sorted().joined(separator: ", "))}"
        }
    }
}

struct DatabaseRecordID: Hashable, Sendable, Codable {
    let columnName: String
    let value: DatabaseValue
}

// MARK: - Unified Query Result Types
struct QueryColumnInfo: Sendable {
    let name: String
    let dataType: String
    let format: String?
    let index: Int
}

enum MongoFormattedColorToken: String, Sendable, Hashable {
    case primary
    case secondary
    case gray
    case orange
    case purple
    case cyan
    case green
    case blue
    case white
}

struct MongoFormattedPrimitivePayload: Sendable, Hashable {
    let value: String
    let colorToken: MongoFormattedColorToken
    let isExpandable: Bool
    let type: String
}

struct MongoFormattedFieldPayload: Sendable, Hashable {
    let key: String
    let formattedValue: MongoFormattedPrimitivePayload
    let nestedFields: [MongoFormattedFieldPayload]?
}

struct MongoFormattedDocumentPayload: Sendable, Hashable {
    let id: String
    let jsonString: String
    let fields: [MongoFormattedFieldPayload]
}

enum QueryRowMetadata: Sendable, Hashable {
    case mongoDocument(MongoFormattedDocumentPayload)
    case mongoField(MongoFormattedFieldPayload)
}

struct QueryRowInfo: Sendable {
    let value: DatabaseValue?
    let dataType: String
    let format: String?
    let metadata: QueryRowMetadata?

    init(value: DatabaseValue?, dataType: String, format: String?, metadata: QueryRowMetadata? = nil) {
        self.value = value
        self.dataType = dataType
        self.format = format
        self.metadata = metadata
    }

    init(value: Any?, dataType: String, format: String?, metadata: QueryRowMetadata? = nil) {
        self.value = DatabaseValue(value) ?? (value as? any CustomStringConvertible).map { .string($0.description) }
        self.dataType = dataType
        self.format = format
        self.metadata = metadata
    }
}

struct InformationSchema: Sendable {
    let name: String
}

struct CreateDatabaseOptions: Sendable {
    let encoding: String?
    let charset: String?
    let collation: String?

    init(encoding: String? = nil, charset: String? = nil, collation: String? = nil) {
        self.encoding = encoding
        self.charset = charset
        self.collation = collation
    }

    static let `default` = CreateDatabaseOptions()
}

struct CreateSchemaOptions: Sendable {
    let authorization: String?

    init(authorization: String? = nil) {
        self.authorization = authorization
    }

    static let `default` = CreateSchemaOptions()
}

struct QueryResult: Sendable {
    let columns: [QueryColumnInfo]
    let rows: [[String: QueryRowInfo]]
    let totalCount: Int
    let rawRows: [DatabaseRawRow]
    
    // Convenience computed properties
    var columnNames: [String] {
        return columns.map { $0.name }
    }
    
    var columnCount: Int {
        return columns.count
    }
    
    // Get specific column info by name
    func column(named name: String) -> QueryColumnInfo? {
        return columns.first { $0.name == name }
    }
    
    // Get column info by index
    func column(at index: Int) -> QueryColumnInfo? {
        guard index >= 0 && index < columns.count else { return nil }
        return columns[index]
    }
    
    // Get value from row by column name
    func value(row: Int, column: String) -> QueryRowInfo? {
        guard row < rows.count else { return nil }
        return rows[row][column] ?? nil
    }
    
    // Get raw value from row by column name (for lazy decoding)
    func rawValue(row: Int, column: String) -> DatabaseValue? {
        guard row < rawRows.count else { return nil }
        return rawRows[row][column] ?? nil
    }

    func recordID(row: Int) -> DatabaseRecordID? {
        guard row < rows.count else { return nil }

        let rowData = rows[row]
        if let id = rowData["_id"]?.value {
            return DatabaseRecordID(columnName: "_id", value: id)
        }
        if let id = rowData["id"]?.value {
            return DatabaseRecordID(columnName: "id", value: id)
        }
        guard let firstColumn = columns.first,
              let value = rowData[firstColumn.name]?.value else {
            return nil
        }
        return DatabaseRecordID(columnName: firstColumn.name, value: value)
    }
}

// MARK: - Redis Models

/// A Redis key whose original bytes are retained even when they are not valid UTF-8.
public struct RedisKey: Identifiable, Hashable, Sendable, Codable {
    public let bytes: Data

    public init(bytes: Data) {
        self.bytes = bytes
    }

    public init(_ string: String) {
        self.bytes = Data(string.utf8)
    }

    public var id: Data { bytes }
    public var utf8String: String? { String(data: bytes, encoding: .utf8) }

    public var displayString: String {
        utf8String ?? "0x" + bytes.map { String(format: "%02x", $0) }.joined()
    }
}

public enum RedisKeyType: Hashable, Sendable, Codable {
    case none
    case string
    case hash
    case list
    case set
    case sortedSet
    case stream
    case json
    case unknown(String)

    public init(serverName: String) {
        switch serverName.lowercased() {
        case "none": self = .none
        case "string": self = .string
        case "hash": self = .hash
        case "list": self = .list
        case "set": self = .set
        case "zset": self = .sortedSet
        case "stream": self = .stream
        case "json", "rejson-rl": self = .json
        default: self = .unknown(serverName)
        }
    }

    /// The value accepted by SCAN TYPE for built-in Redis data types.
    public var scanFilter: String? {
        switch self {
        case .none: nil
        case .string: "string"
        case .hash: "hash"
        case .list: "list"
        case .set: "set"
        case .sortedSet: "zset"
        case .stream: "stream"
        case .json: "ReJSON-RL"
        case .unknown(let value): value
        }
    }

    public var displayName: String {
        switch self {
        case .none: "None"
        case .string: "String"
        case .hash: "Hash"
        case .list: "List"
        case .set: "Set"
        case .sortedSet: "Sorted Set"
        case .stream: "Stream"
        case .json: "JSON"
        case .unknown(let value): value
        }
    }
}

public struct RedisScanPage: Equatable, Sendable {
    /// Redis SCAN cursors are opaque unsigned 64-bit values.
    public let nextCursor: UInt64
    public let keys: [RedisKey]

    public init(nextCursor: UInt64, keys: [RedisKey]) {
        self.nextCursor = nextCursor
        self.keys = keys
    }

    public var isComplete: Bool { nextCursor == 0 }
}

public struct RedisKeyMetadata: Equatable, Sendable {
    public let key: RedisKey
    public let type: RedisKeyType
    /// Remaining lifetime in milliseconds. `nil` means the key is persistent.
    public let ttlMilliseconds: Int64?
    public let memoryUsageBytes: Int64?
    public let encoding: String?

    public init(
        key: RedisKey,
        type: RedisKeyType,
        ttlMilliseconds: Int64?,
        memoryUsageBytes: Int64?,
        encoding: String?
    ) {
        self.key = key
        self.type = type
        self.ttlMilliseconds = ttlMilliseconds
        self.memoryUsageBytes = memoryUsageBytes
        self.encoding = encoding
    }

    public var exists: Bool { type != .none }
}

public struct RedisValuePage: Equatable, Sendable {
    public let offset: Int
    public let count: Int
    public let cursor: UInt64

    public init(offset: Int = 0, count: Int = 200, cursor: UInt64 = 0) {
        self.offset = max(0, offset)
        self.count = min(max(1, count), 10_000)
        self.cursor = cursor
    }
}

public struct RedisHashEntry: Equatable, Sendable {
    public let field: Data
    public let value: Data

    public init(field: Data, value: Data) {
        self.field = field
        self.value = value
    }
}

public struct RedisSortedSetEntry: Equatable, Sendable {
    public let member: Data
    public let score: Double

    public init(member: Data, score: Double) {
        self.member = member
        self.score = score
    }
}

public struct RedisStreamEntry: Equatable, Sendable {
    public let id: Data
    public let fields: [RedisHashEntry]

    public init(id: Data, fields: [RedisHashEntry]) {
        self.id = id
        self.fields = fields
    }
}

public enum RedisValue: Equatable, Sendable {
    case none
    case string(Data)
    case hash(entries: [RedisHashEntry], totalCount: Int, nextCursor: UInt64)
    case list(elements: [Data], totalCount: Int, offset: Int)
    case set(members: [Data], totalCount: Int, nextCursor: UInt64)
    case sortedSet(entries: [RedisSortedSetEntry], totalCount: Int, offset: Int)
    case stream(entries: [RedisStreamEntry], totalCount: Int)
    case json(Data)
    case unsupported(type: RedisKeyType, raw: RedisCommandValue)
}

public enum RedisValueUpdate: Equatable, Sendable {
    case string(Data)
    case json(Data)
    case hashField(field: Data, value: Data)
    case deleteHashField(field: Data)
    case listElement(index: Int, value: Data)
    case appendList(values: [Data], toHead: Bool)
    case setMember(Data, isPresent: Bool)
    /// A nil score removes the member.
    case sortedSetMember(member: Data, score: Double?)
    case appendStream(fields: [RedisHashEntry], id: Data?)
    case deleteStreamEntry(id: Data)
}

/// A binary-safe Redis command. The first argument is the command name.
public struct RedisCommand: Equatable, Sendable {
    public let arguments: [Data]

    public init(arguments: [Data]) {
        self.arguments = arguments
    }

    public init(arguments: [String]) {
        self.arguments = arguments.map { Data($0.utf8) }
    }
}

public struct RedisCommandMapEntry: Equatable, Sendable {
    public let key: RedisCommandValue
    public let value: RedisCommandValue

    public init(key: RedisCommandValue, value: RedisCommandValue) {
        self.key = key
        self.value = value
    }
}

/// A lossless, binary-safe representation of a RESP3 response.
public indirect enum RedisCommandValue: Equatable, Sendable {
    case null
    case simpleString(Data)
    case bulkString(Data)
    case simpleError(Data)
    case bulkError(Data)
    case verbatimString(format: String?, data: Data)
    case integer(Int64)
    case double(Double)
    case boolean(Bool)
    case bigNumber(Data)
    case array([RedisCommandValue])
    case map([RedisCommandMapEntry])
    case set([RedisCommandValue])
    case push([RedisCommandValue])
    case attribute([RedisCommandMapEntry])
}

public struct RedisCommandResult: Equatable, Sendable {
    public let value: RedisCommandValue
    public let durationMilliseconds: Double

    public init(value: RedisCommandValue, durationMilliseconds: Double) {
        self.value = value
        self.durationMilliseconds = durationMilliseconds
    }
}

// MARK: - Database Driver Protocol
protocol DatabaseDriver: Actor {
    associatedtype Database: DatabaseWrapper
    associatedtype Collection: CollectionWrapper
    
    // Connection management
    func connect(to connectionUri: String) async throws -> Database
    func disconnect() async
    func reconnect() async throws
    /// Lightweight connectivity check that does not modify driver state
    func ping(to connectionUri: String) async throws
    func getBuildInfo() async throws -> BuildInfo
    func switchDatabase(to databaseName: String) async throws

    // Optional: Get the current deployment/host URL (useful for Convex environments)
    func getCurrentDeploymentUrl() async -> String?
    
    // Database operations
    func listDatabases() async throws -> [Database]
    func getDatabaseMetadata()  async throws -> [Database]
    func listCollections(schema: String?) async throws -> [Collection]

    // Database management
    func createDatabase(named databaseName: String, options: CreateDatabaseOptions) async throws
    func createSchema(named schemaName: String, options: CreateSchemaOptions) async throws
    
    // Collection operations
    func getDocumentCount(for collectionName: String, filter: DatabaseDocument) async throws -> Int
    func findDocuments(in collectionName: String, filter: DatabaseDocument) async throws -> [QueryResult]
    func findDocuments(in collectionName: String, filter: DatabaseDocument, skip: Int, limit: Int) async throws -> QueryResult
    func findDocuments(in collectionName: String,  databaseSchema: String?, filter: DatabaseDocument, skip: Int, limit: Int, sortBy: String?, ascending: Bool?) async throws -> QueryResult
    func createDocument(in collectionName: String, databaseSchema: String?, document: DatabaseDocument) async throws
    func updateDocument(in collectionName: String, databaseSchema: String?, id: DatabaseRecordID, data: DatabaseDocument) async throws
    func deleteDocument(in collectionName: String, databaseSchema: String?, id: DatabaseRecordID) async throws
    
    // Raw Query Execution
    @discardableResult
    func executeRawQuery(_ query: String, databaseSchema: String?) async throws -> [QueryResult]

    // Redis operations. Non-Redis drivers use the default unsupported implementations below.
    func scanRedisKeys(cursor: UInt64, pattern: String?, type: RedisKeyType?, count: Int) async throws -> RedisScanPage
    func redisKeyMetadata(for key: RedisKey) async throws -> RedisKeyMetadata
    func redisValue(for key: RedisKey, page: RedisValuePage) async throws -> RedisValue
    func updateRedisValue(_ update: RedisValueUpdate, for key: RedisKey, preserveTTL: Bool) async throws
    func renameRedisKey(_ key: RedisKey, to newKey: RedisKey, overwrite: Bool) async throws
    func deleteRedisKeys(_ keys: [RedisKey], asynchronously: Bool) async throws -> Int
    func setRedisExpiration(for key: RedisKey, milliseconds: Int64?) async throws -> Bool
    func executeRedisCommand(_ command: RedisCommand) async throws -> RedisCommandResult
    func parseRedisCommand(_ commandText: String) async throws -> RedisCommand
    
    func getSchema(for collectionName: String, schema: String?) async throws -> DatabaseSchemaResult?
    func getInformationSchema() async throws -> [InformationSchema]
    func getIndexes(for collectionName: String, schema: String?) async throws -> [DatabaseIndexInfo]

    // Collection management
    func createCollection(named collectionName: String) async throws
    func renameCollection(databaseSchema: String?, from oldName: String, to newName: String) async throws
    func deleteCollection(named collectionName: String, databaseSchema: String?) async throws
    
    // AI Functions
    func buildSystemPrompt(for collectionName: String, databaseSchema: String?) async throws -> String
    func buildAICommandPromptSystemPrompt(_ message: String) async throws -> String
    
    // Real-time subscription (optional - only implemented by databases that support it)
    func subscribeToCollectionChanges(
        collectionName: String,
        databaseSchema: String?,
        filter: String?,
        limit: Int,
        sortBy: String?,
        ascending: Bool?,
        page: Int?,
        onUpdate: @escaping @Sendable (QueryResult) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) async throws

    // Clear subscription cache for a specific table (optional - only needed for databases with caching)
    func clearSubscriptionCache(for tableName: String) async

    // Clear schema cache for a specific table (optional - only needed for databases with schema caching)
    func clearSchemaCache(for tableName: String, schema: String?) async

    // MARK: - Schema Modification Methods

    /// Add a new column to a table
    func addColumn(
        to tableName: String,
        schema: String?,
        column: DatabaseSchemaInfo
    ) async throws

    /// Modify an existing column in a table
    func modifyColumn(
        in tableName: String,
        schema: String?,
        columnName: String,
        newColumn: DatabaseSchemaInfo
    ) async throws

    /// Drop a column from a table
    func dropColumn(
        from tableName: String,
        schema: String?,
        columnName: String
    ) async throws

    /// Create a new index on a table
    func createIndex(
        on tableName: String,
        schema: String?,
        index: DatabaseIndexInfo
    ) async throws

    /// Drop an index from a table
    func dropIndex(
        indexName: String,
        tableName: String,
        schema: String?
    ) async throws
}

// MARK: - Default Implementations
extension DatabaseDriver {
    // Default implementation for drivers that don't need deployment URL
    func getCurrentDeploymentUrl() async -> String? {
        return nil
    }
}

// MARK: - Default DatabaseDriver Implementation
extension DatabaseDriver {
    // Provide default no-op implementation for real-time subscriptions
    // Only databases that support real-time will override this
    func subscribeToCollectionChanges(
        collectionName: String,
        databaseSchema: String?,
        filter: String?,
        limit: Int,
        sortBy: String?,
        ascending: Bool?,
        page: Int?,
        onUpdate: @escaping @Sendable (QueryResult) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) async throws {
        throw DatabaseError.notImplemented("Real-time subscriptions not supported for this database type")
    }

    // Provide default no-op implementation for subscription cache clearing
    // Only databases that support real-time caching will override this
    func clearSubscriptionCache(for tableName: String) async {
        // Default implementation does nothing
    }

    // Provide default no-op implementation for schema cache clearing
    // Only databases with schema caching will override this
    func clearSchemaCache(for tableName: String, schema: String?) async {
        // Default implementation does nothing
    }

    func scanRedisKeys(cursor: UInt64, pattern: String?, type: RedisKeyType?, count: Int) async throws -> RedisScanPage {
        throw DatabaseError.notImplemented("Redis key scanning is only available for Redis connections")
    }

    func redisKeyMetadata(for key: RedisKey) async throws -> RedisKeyMetadata {
        throw DatabaseError.notImplemented("Redis metadata is only available for Redis connections")
    }

    func redisValue(for key: RedisKey, page: RedisValuePage) async throws -> RedisValue {
        throw DatabaseError.notImplemented("Redis values are only available for Redis connections")
    }

    func updateRedisValue(_ update: RedisValueUpdate, for key: RedisKey, preserveTTL: Bool) async throws {
        throw DatabaseError.notImplemented("Redis value editing is only available for Redis connections")
    }

    func renameRedisKey(_ key: RedisKey, to newKey: RedisKey, overwrite: Bool) async throws {
        throw DatabaseError.notImplemented("Redis key renaming is only available for Redis connections")
    }

    func deleteRedisKeys(_ keys: [RedisKey], asynchronously: Bool) async throws -> Int {
        throw DatabaseError.notImplemented("Redis key deletion is only available for Redis connections")
    }

    func setRedisExpiration(for key: RedisKey, milliseconds: Int64?) async throws -> Bool {
        throw DatabaseError.notImplemented("Redis expiration is only available for Redis connections")
    }

    func executeRedisCommand(_ command: RedisCommand) async throws -> RedisCommandResult {
        throw DatabaseError.notImplemented("Redis commands are only available for Redis connections")
    }

    func parseRedisCommand(_ commandText: String) async throws -> RedisCommand {
        throw DatabaseError.notImplemented("Redis commands are only available for Redis connections")
    }


    // Default implementation for createDatabase - throws not implemented
    func createDatabase(named databaseName: String, options: CreateDatabaseOptions) async throws {
        throw DatabaseError.notImplemented("Creating databases is not supported for this database type")
    }

    // Default implementation for createSchema - throws not implemented
    func createSchema(named schemaName: String, options: CreateSchemaOptions) async throws {
        throw DatabaseError.notImplemented("Creating schemas is not supported for this database type")
    }

    // MARK: - Default Schema Modification Implementations

    /// Default implementation throws not implemented error
    func addColumn(
        to tableName: String,
        schema: String?,
        column: DatabaseSchemaInfo
    ) async throws {
        throw DatabaseError.notImplemented("Schema modification not supported for this database type")
    }

    /// Default implementation throws not implemented error
    func modifyColumn(
        in tableName: String,
        schema: String?,
        columnName: String,
        newColumn: DatabaseSchemaInfo
    ) async throws {
        throw DatabaseError.notImplemented("Schema modification not supported for this database type")
    }

    /// Default implementation throws not implemented error
    func dropColumn(
        from tableName: String,
        schema: String?,
        columnName: String
    ) async throws {
        throw DatabaseError.notImplemented("Schema modification not supported for this database type")
    }

    /// Default implementation throws not implemented error
    func createIndex(
        on tableName: String,
        schema: String?,
        index: DatabaseIndexInfo
    ) async throws {
        throw DatabaseError.notImplemented("Schema modification not supported for this database type")
    }

    /// Default implementation throws not implemented error
    func dropIndex(
        indexName: String,
        tableName: String,
        schema: String?
    ) async throws {
        throw DatabaseError.notImplemented("Schema modification not supported for this database type")
    }
}

// MARK: - Build Info Structure
struct BuildInfo: Sendable {
    let version: String
    let databaseType: DatabaseType
}

// MARK: - Database Constraint Information Structure
enum ConstraintType: String, Equatable, Sendable {
    case foreignKey = "f"
    case primaryKey = "p"
    case unique = "u"
    case check = "c"
    case exclusion = "x"
    case trigger = "t"
}

struct ConstraintInfo: Equatable, Sendable {
    let oid: Int64
    let name: String
    let type: ConstraintType
    let columns: [String]
    let isDeferrable: Bool
    let isDeferred: Bool
    let definition: String?
    let description: String?
    
    // Foreign key specific properties
    let referencedSchema: String?
    let referencedTable: String?
    let referencedColumns: [String]?
    let onUpdate: String?
    let onDelete: String?
    
    // Extension info
    let extensionName: String?
    
    init(
        oid: Int64 = 0,
        name: String,
        type: ConstraintType,
        columns: [String] = [],
        isDeferrable: Bool = false,
        isDeferred: Bool = false,
        definition: String? = nil,
        description: String? = nil,
        referencedSchema: String? = nil,
        referencedTable: String? = nil,
        referencedColumns: [String]? = nil,
        onUpdate: String? = nil,
        onDelete: String? = nil,
        extensionName: String? = nil
    ) {
        self.oid = oid
        self.name = name
        self.type = type
        self.columns = columns
        self.isDeferrable = isDeferrable
        self.isDeferred = isDeferred
        self.definition = definition
        self.description = description
        self.referencedSchema = referencedSchema
        self.referencedTable = referencedTable
        self.referencedColumns = referencedColumns
        self.onUpdate = onUpdate
        self.onDelete = onDelete
        self.extensionName = extensionName
    }
    
    // Convenience property for foreign key navigation
    var isForeignKey: Bool {
        return type == .foreignKey
    }
    
    // Convenience property for primary key identification
    var isPrimaryKey: Bool {
        return type == .primaryKey
    }
}

// MARK: - Database Index Information Structure
enum IndexType: String, Equatable, Sendable {
    case btree = "btree"
    case hash = "hash"
    case gin = "gin"
    case gist = "gist"
    case spgist = "spgist"
    case brin = "brin"
    case fulltext = "fulltext"
    case spatial = "spatial"
    case other = "other"
}

struct DatabaseIndexInfo: Equatable, Sendable {
    let name: String
    let tableName: String
    let schemaName: String
    let columns: [String]
    let indexType: IndexType
    let isUnique: Bool
    let isPrimaryKey: Bool
    let definition: String?
    let condition: String?  // For partial indexes (WHERE clause)
    let includeColumns: [String]?  // For INCLUDE clause
    let comment: String?

    init(
        name: String,
        tableName: String,
        schemaName: String,
        columns: [String],
        indexType: IndexType,
        isUnique: Bool = false,
        isPrimaryKey: Bool = false,
        definition: String? = nil,
        condition: String? = nil,
        includeColumns: [String]? = nil,
        comment: String? = nil
    ) {
        self.name = name
        self.tableName = tableName
        self.schemaName = schemaName
        self.columns = columns
        self.indexType = indexType
        self.isUnique = isUnique
        self.isPrimaryKey = isPrimaryKey
        self.definition = definition
        self.condition = condition
        self.includeColumns = includeColumns
        self.comment = comment
    }

    // Convenience computed property for display
    var columnsDisplay: String {
        return columns.joined(separator: ", ")
    }

    var includeColumnsDisplay: String? {
        guard let includeColumns = includeColumns, !includeColumns.isEmpty else {
            return nil
        }
        return includeColumns.joined(separator: ", ")
    }
}

// MARK: - Schema Information Structures
struct DatabaseSchemaInfo: Equatable, Sendable {
    let ordinalPosition: Int?
    let columnName: String
    let dataType: String
    let formatType: String
    let typeOid: Int
    let numericPrecision: Int?
    let datetimePrecision: Int?
    let numericScale: Int?
    let dataLength: Int?
    let isNullable: String
    let check: String
    let checkConstraint: String
    let columnDefault: String?
    let foreignKey: String
    let constraints: [ConstraintInfo]
    let comment: String?
    let isReadOnly: Bool
    let enumValues: [String]?

    var isEnum: Bool {
        enumValues != nil && !(enumValues?.isEmpty ?? true)
    }

    init(
        ordinalPosition: Int? = nil,
        columnName: String,
        dataType: String,
        formatType: String,
        typeOid: Int,
        numericPrecision: Int? = nil,
        datetimePrecision: Int? = nil,
        numericScale: Int? = nil,
        dataLength: Int? = nil,
        isNullable: String = "YES",
        check: String = "",
        checkConstraint: String = "",
        columnDefault: String? = nil,
        foreignKey: String = "",
        constraints: [ConstraintInfo] = [],
        comment: String? = nil,
        isReadOnly: Bool = false,
        enumValues: [String]? = nil
    ) {
        self.ordinalPosition = ordinalPosition
        self.columnName = columnName
        self.dataType = dataType
        self.formatType = formatType
        self.numericPrecision = numericPrecision
        self.datetimePrecision = datetimePrecision
        self.numericScale = numericScale
        self.dataLength = dataLength
        self.isNullable = isNullable
        self.check = check
        self.checkConstraint = checkConstraint
        self.columnDefault = columnDefault
        self.foreignKey = foreignKey
        self.constraints = constraints
        self.comment = comment
        self.typeOid = typeOid
        self.isReadOnly = isReadOnly
        self.enumValues = enumValues
    }
    
    // MARK: - Constraint convenience methods
    
    /// Get all foreign key constraints for this column
    var foreignKeyConstraints: [ConstraintInfo] {
        return constraints.filter { $0.type == .foreignKey }
    }
    
    /// Get the primary foreign key constraint (first one if multiple exist)
    var primaryForeignKeyConstraint: ConstraintInfo? {
        return foreignKeyConstraints.first
    }
    
    /// Get all primary key constraints for this column
    var primaryKeyConstraints: [ConstraintInfo] {
        return constraints.filter { $0.type == .primaryKey }
    }
    
    /// Check if this column has any foreign key constraints
    var hasForeignKey: Bool {
        return !foreignKeyConstraints.isEmpty
    }
    
    /// Check if this column is part of a primary key
    var isPrimaryKey: Bool {
        return !primaryKeyConstraints.isEmpty
    }
    
    /// Get all unique constraints for this column
    var uniqueConstraints: [ConstraintInfo] {
        return constraints.filter { $0.type == .unique }
    }
    
    /// Get all check constraints for this column
    var checkConstraints: [ConstraintInfo] {
        return constraints.filter { $0.type == .check }
    }
}

struct DatabaseSchemaResult: Equatable, Sendable {
    let tableName: String
    let schemaName: String
    let columns: [DatabaseSchemaInfo]
    let totalCount: Int
    
    var columnCount: Int {
        return columns.count
    }
    
    // Get specific column info by name
    func column(named name: String) -> DatabaseSchemaInfo? {
        return columns.first { $0.columnName == name }
    }
    
    // Get columns by data type
    func columns(ofType dataType: String) -> [DatabaseSchemaInfo] {
        return columns.filter { $0.dataType == dataType }
    }
    
    // Get nullable columns
    var nullableColumns: [DatabaseSchemaInfo] {
        return columns.filter { $0.isNullable == "YES" }
    }
    
    // Get non-nullable columns
    var nonNullableColumns: [DatabaseSchemaInfo] {
        return columns.filter { $0.isNullable == "NO" }
    }
    
    // Get columns with defaults
    var columnsWithDefaults: [DatabaseSchemaInfo] {
        return columns.filter { $0.columnDefault != nil }
    }
    
    var hashValue: Int {
         var hasher = Hasher()
         for column in columns {
             hasher.combine(column.columnName)
             hasher.combine(column.dataType)
             // Add other relevant column properties if needed
         }
         return hasher.finalize()
     }
}

// MARK: - Generic Database Wrapper
protocol DatabaseWrapper: Sendable {
    var name: String { get }
    var size: String? { get }
    var tableCount: Int? { get }
}

// MARK: - Generic Collection Wrapper
protocol CollectionWrapper: Identifiable, Sendable {
    var name: String { get }
    var type: String { get }
    var schema: String? { get }
}

// MARK: - Database Driver Factory
class DatabaseDriverFactory {
    static func createDriver(for databaseType: DatabaseType) -> any DatabaseDriver {
        switch databaseType {
        case .mongodb:
            return MongoDBDriver()
        case .postgres, .supabase:
            return PostgreSQLDriver()
        case .convex:
            return ConvexDriver()
        case .mysql:
            return MySQLDriver()
        case .sqlite:
            return SQLiteDriver()
        case .redis:
            return RedisDriver()
        }
    }
}
