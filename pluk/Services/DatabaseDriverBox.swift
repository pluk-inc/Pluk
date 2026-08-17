import Foundation

actor DatabaseDriverBox {
    private let driver: any DatabaseDriver

    init(databaseType: DatabaseType) {
        self.driver = DatabaseDriverFactory.createDriver(for: databaseType)
    }

    func connect(to connectionUri: String) async throws -> any DatabaseWrapper {
        try await driver.connect(to: connectionUri)
    }

    func disconnect() async {
        await driver.disconnect()
    }

    func reconnect() async throws {
        try await driver.reconnect()
    }

    func ping(to connectionUri: String) async throws {
        try await driver.ping(to: connectionUri)
    }

    func getBuildInfo() async throws -> BuildInfo {
        try await driver.getBuildInfo()
    }

    func switchDatabase(to databaseName: String) async throws {
        try await driver.switchDatabase(to: databaseName)
    }

    func getCurrentDeploymentUrl() async -> String? {
        await driver.getCurrentDeploymentUrl()
    }

    func getCurrentDatabaseWrapper() async -> (any DatabaseWrapper)? {
        if let mongoDriver = driver as? MongoDBDriver {
            return await mongoDriver.getCurrentDatabaseWrapper()
        }
        return nil
    }

    func listDatabases() async throws -> [any DatabaseWrapper] {
        try await driver.listDatabases()
    }

    func getDatabaseMetadata() async throws -> [any DatabaseWrapper] {
        try await driver.getDatabaseMetadata()
    }

    func listCollections(schema: String?) async throws -> [any CollectionWrapper] {
        try await driver.listCollections(schema: schema)
    }

    func createDatabase(named databaseName: String, options: CreateDatabaseOptions) async throws {
        try await driver.createDatabase(named: databaseName, options: options)
    }

    func createSchema(named schemaName: String, options: CreateSchemaOptions) async throws {
        try await driver.createSchema(named: schemaName, options: options)
    }

    func getDocumentCount(for collectionName: String, filter: DatabaseDocument) async throws -> Int {
        try await driver.getDocumentCount(for: collectionName, filter: filter)
    }

    func findDocuments(in collectionName: String, filter: DatabaseDocument) async throws -> [QueryResult] {
        try await driver.findDocuments(in: collectionName, filter: filter)
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
        try await driver.findDocuments(
            in: collectionName,
            databaseSchema: databaseSchema,
            filter: filter,
            skip: skip,
            limit: limit,
            sortBy: sortBy,
            ascending: ascending
        )
    }

    func createDocument(in collectionName: String, databaseSchema: String?, document: DatabaseDocument) async throws {
        try await driver.createDocument(in: collectionName, databaseSchema: databaseSchema, document: document)
    }

    func updateDocument(
        in collectionName: String,
        databaseSchema: String?,
        id: DatabaseRecordID,
        data: DatabaseDocument
    ) async throws {
        try await driver.updateDocument(in: collectionName, databaseSchema: databaseSchema, id: id, data: data)
    }

    func deleteDocument(in collectionName: String, databaseSchema: String?, id: DatabaseRecordID) async throws {
        try await driver.deleteDocument(in: collectionName, databaseSchema: databaseSchema, id: id)
    }

    func executeRawQuery(_ query: String, databaseSchema: String?) async throws -> [QueryResult] {
        try await driver.executeRawQuery(query, databaseSchema: databaseSchema)
    }

    func scanRedisKeys(
        cursor: UInt64,
        pattern: String?,
        type: RedisKeyType?,
        count: Int
    ) async throws -> RedisScanPage {
        try await driver.scanRedisKeys(cursor: cursor, pattern: pattern, type: type, count: count)
    }

    func redisKeyMetadata(for key: RedisKey) async throws -> RedisKeyMetadata {
        try await driver.redisKeyMetadata(for: key)
    }

    func redisValue(for key: RedisKey, page: RedisValuePage) async throws -> RedisValue {
        try await driver.redisValue(for: key, page: page)
    }

    func updateRedisValue(
        _ update: RedisValueUpdate,
        for key: RedisKey,
        preserveTTL: Bool
    ) async throws {
        try await driver.updateRedisValue(update, for: key, preserveTTL: preserveTTL)
    }

    func renameRedisKey(_ key: RedisKey, to newKey: RedisKey, overwrite: Bool) async throws {
        try await driver.renameRedisKey(key, to: newKey, overwrite: overwrite)
    }

    func deleteRedisKeys(_ keys: [RedisKey], asynchronously: Bool) async throws -> Int {
        try await driver.deleteRedisKeys(keys, asynchronously: asynchronously)
    }

    func setRedisExpiration(for key: RedisKey, milliseconds: Int64?) async throws -> Bool {
        try await driver.setRedisExpiration(for: key, milliseconds: milliseconds)
    }

    func executeRedisCommand(_ command: RedisCommand) async throws -> RedisCommandResult {
        try await driver.executeRedisCommand(command)
    }

    func parseRedisCommand(_ commandText: String) async throws -> RedisCommand {
        try await driver.parseRedisCommand(commandText)
    }

    func getSchema(for collectionName: String, schema: String?) async throws -> DatabaseSchemaResult? {
        try await driver.getSchema(for: collectionName, schema: schema)
    }

    func getInformationSchema() async throws -> [InformationSchema] {
        try await driver.getInformationSchema()
    }

    func getIndexes(for collectionName: String, schema: String?) async throws -> [DatabaseIndexInfo] {
        try await driver.getIndexes(for: collectionName, schema: schema)
    }

    func createCollection(named collectionName: String) async throws {
        try await driver.createCollection(named: collectionName)
    }

    func renameCollection(databaseSchema: String?, from oldName: String, to newName: String) async throws {
        try await driver.renameCollection(databaseSchema: databaseSchema, from: oldName, to: newName)
    }

    func deleteCollection(named collectionName: String, databaseSchema: String?) async throws {
        try await driver.deleteCollection(named: collectionName, databaseSchema: databaseSchema)
    }

    func buildSystemPrompt(for collectionName: String, databaseSchema: String?) async throws -> String {
        try await driver.buildSystemPrompt(for: collectionName, databaseSchema: databaseSchema)
    }

    func buildAICommandPromptSystemPrompt(_ message: String) async throws -> String {
        try await driver.buildAICommandPromptSystemPrompt(message)
    }

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
        try await driver.subscribeToCollectionChanges(
            collectionName: collectionName,
            databaseSchema: databaseSchema,
            filter: filter,
            limit: limit,
            sortBy: sortBy,
            ascending: ascending,
            page: page,
            onUpdate: onUpdate,
            onError: onError
        )
    }

    func clearSubscriptionCache(for tableName: String) async {
        await driver.clearSubscriptionCache(for: tableName)
    }

    func clearSchemaCache(for tableName: String, schema: String?) async {
        await driver.clearSchemaCache(for: tableName, schema: schema)
    }

    func addColumn(to tableName: String, schema: String?, column: DatabaseSchemaInfo) async throws {
        try await driver.addColumn(to: tableName, schema: schema, column: column)
    }

    func modifyColumn(
        in tableName: String,
        schema: String?,
        columnName: String,
        newColumn: DatabaseSchemaInfo
    ) async throws {
        try await driver.modifyColumn(in: tableName, schema: schema, columnName: columnName, newColumn: newColumn)
    }

    func dropColumn(from tableName: String, schema: String?, columnName: String) async throws {
        try await driver.dropColumn(from: tableName, schema: schema, columnName: columnName)
    }

    func createIndex(on tableName: String, schema: String?, index: DatabaseIndexInfo) async throws {
        try await driver.createIndex(on: tableName, schema: schema, index: index)
    }

    func dropIndex(indexName: String, tableName: String, schema: String?) async throws {
        try await driver.dropIndex(indexName: indexName, tableName: tableName, schema: schema)
    }

    func getFunctionDefinition(oid: String) async throws -> String? {
        guard let postgresDriver = driver as? PostgreSQLDriver else { return nil }
        return try await postgresDriver.getFunctionDefinition(oid: oid)
    }

    func buildUpdatedConvexEmbeddedToken() async -> String? {
        guard let convexDriver = driver as? ConvexDriver else { return nil }
        return await convexDriver.buildUpdatedEmbeddedToken()
    }

    func refreshConvexDeployments() async throws -> [any DatabaseWrapper] {
        guard let convexDriver = driver as? ConvexDriver else { return [] }
        return try await convexDriver.refreshDeploymentsFromAPI()
    }
}
