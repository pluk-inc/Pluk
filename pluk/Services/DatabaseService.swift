//
//  DatabaseService.swift
//  Pluk
//
//  Created by Fauzaan on 4/11/25.
//

import Foundation
import SwiftUI

@Observable @MainActor class DatabaseService {
    // MARK: - Current Connection State
    private var activeConnection: Connection?
    private var activeDriverBox: DatabaseDriverBox?
    private var activeSSHTunnelID: UUID?
    public var connectedDatabase: (any DatabaseWrapper)?
    public var currentSchema: String?
    private var currentDeploymentURL: String?

    // MARK: - Query History
    weak var queryHistoryService: QueryHistoryService?

    private func recordQueryHistory(
        query: String,
        queryType: QueryType? = nil,
        source: QuerySource,
        databaseType: DatabaseType,
        databaseName: String?,
        schemaName: String?,
        tableName: String? = nil,
        executionDurationMs: Int?,
        rowsAffected: Int? = nil,
        wasSuccessful: Bool,
        errorMessage: String? = nil
    ) {
        let service = queryHistoryService
        Task { @MainActor in
            service?.recordQuery(
                query: query,
                queryType: queryType,
                source: source,
                databaseType: databaseType,
                databaseName: databaseName,
                schemaName: schemaName,
                tableName: tableName,
                executionDurationMs: executionDurationMs,
                rowsAffected: rowsAffected,
                wasSuccessful: wasSuccessful,
                errorMessage: errorMessage
            )
        }
    }

    // MARK: - Results Cache
    private var queryCache: [String: QueryResult] = [:]

    private func makeDriverDocument(from document: [String: Any]) throws -> DatabaseDocument {
        var converted: DatabaseDocument = [:]
        for (key, value) in document {
            guard let driverValue = DatabaseValue(value) else {
                throw DatabaseError.operationFailed("Unsupported value for field '\(key)'")
            }
            converted[key] = driverValue
        }
        return converted
    }

    func makeRecordID(columnName: String, value: Any?) throws -> DatabaseRecordID {
        guard let driverValue = DatabaseValue(value) else {
            throw DatabaseError.operationFailed("Unsupported identifier value for column '\(columnName)'")
        }
        return DatabaseRecordID(columnName: columnName, value: driverValue)
    }

    func makeSchemaModificationService() -> SchemaModificationService? {
        guard let activeDriverBox else { return nil }
        return SchemaModificationService(driverBox: activeDriverBox)
    }
    
    // MARK: - Real-time Subscription Management
    private var activeSubscriptionTasks: [String: Task<Void, Never>] = [:]
    private var subscriptionTableNames: [String: String] = [:] // Maps tabId to tableName
    
    // MARK: - Connection Management
    func setActiveConnection(_ connection: Connection, targetDatabase: String? = nil) async throws {
        let targetDatabaseName = targetDatabase ?? self.connectedDatabase?.name

        if activeDriverBox != nil || activeConnection != nil || connectedDatabase != nil {
            await disconnect()
        }

        self.activeConnection = connection

        // Create and isolate the driver behind the actor boundary.
        self.activeDriverBox = DatabaseDriverBox(databaseType: connection.databaseType)

        let requiresDatabaseSelection = shouldDeferDatabaseSelection(for: connection, targetDatabaseName: targetDatabaseName)
        let baseConnectionUri = connectionUriForInitialConnect(
            connection,
            targetDatabaseName: targetDatabaseName,
            requiresDatabaseSelection: requiresDatabaseSelection
        )

        // Connect to database
        guard let driverBox = activeDriverBox else {
            throw DatabaseError.operationFailed("Failed to create database driver")
        }

        var createdTunnelID: UUID?

        do {
            let preparedConnection = try await prepareConnectionUri(
                baseConnectionUri,
                databaseType: connection.databaseType,
                sshConfiguration: connection.sshConfiguration,
                sshPassword: connection.sshPassword,
                sshKeyPassphrase: connection.sshKeyPassphrase
            )
            createdTunnelID = preparedConnection.sshTunnelID

            let initialDatabase = try await driverBox.connect(to: preparedConnection.uri)
            activeSSHTunnelID = createdTunnelID
            self.connectedDatabase = requiresDatabaseSelection ? nil : initialDatabase
            self.currentDeploymentURL = await driverBox.getCurrentDeploymentUrl()

            // For non-Convex databases, switch to target database if needed
            if connection.databaseType != .convex,
               let targetName = targetDatabaseName,
               !targetName.isEmpty,
               connectedDatabase?.name != targetName {
                try await driverBox.switchDatabase(to: targetName)
                // Update connectedDatabase to reflect the switch using the appropriate wrapper type
                switch connection.databaseType {
                case .postgres, .supabase:
                    self.connectedDatabase = PostgreSQLDatabaseWrapper(name: targetName, size: nil, tableCount: nil)
                case .mysql:
                    self.connectedDatabase = MySQLDatabaseWrapper(name: targetName, size: nil, tableCount: nil)
                case .sqlite:
                    self.connectedDatabase = SQLiteDatabaseWrapper(name: targetName, size: nil, tableCount: nil)
                case .redis:
                    self.connectedDatabase = RedisDatabaseWrapper(name: targetName, size: nil, tableCount: nil)
                case .mongodb:
                    if let wrapper = await driverBox.getCurrentDatabaseWrapper() {
                        self.connectedDatabase = wrapper
                    }
                default:
                    break
                }
            }

            // Post notification about database connection change
            NotificationCenter.default.post(name: .connectedDatabaseChanged, object: self)
        } catch {
            await driverBox.disconnect()
            await SSHTunnelService.shared.closeTunnel(id: createdTunnelID)
            activeSSHTunnelID = nil
            activeConnection = nil
            activeDriverBox = nil
            connectedDatabase = nil
            currentSchema = nil
            currentDeploymentURL = nil
            clearCache()
            throw error
        }
    }

    private func shouldDeferDatabaseSelection(for connection: Connection, targetDatabaseName: String?) -> Bool {
        guard targetDatabaseName?.isEmpty != false else { return false }

        switch connection.databaseType {
        case .postgres, .supabase:
            return connection.defaultDatabase?.isEmpty != false
        default:
            return false
        }
    }

    private func connectionUriForInitialConnect(
        _ connection: Connection,
        targetDatabaseName: String?,
        requiresDatabaseSelection: Bool
    ) -> String {
        var connectionUri = connection.connectionUri

        if connection.databaseType == .convex, let targetName = targetDatabaseName {
            connectionUri += "#target=\(targetName)"
            return connectionUri
        }

        guard requiresDatabaseSelection else { return connectionUri }

        if let queryStart = connectionUri.firstIndex(of: "?") {
            let prefix = String(connectionUri[..<queryStart])
            let suffix = String(connectionUri[queryStart...])
            return "\(appendingPostgresDatabase(to: prefix))\(suffix)"
        }

        return appendingPostgresDatabase(to: connectionUri)
    }

    private func appendingPostgresDatabase(to connectionUri: String) -> String {
        let prefix = connectionUri.hasSuffix("/") ? String(connectionUri.dropLast()) : connectionUri
        return "\(prefix)/postgres"
    }

    private struct PreparedConnectionUri {
        let uri: String
        let sshTunnelID: UUID?
    }

    private struct RemoteDatabaseEndpoint {
        let host: String
        let port: Int
    }

    private func prepareConnectionUri(
        _ connectionUri: String,
        databaseType: DatabaseType,
        sshConfiguration: SSHConfiguration?,
        sshPassword: String?,
        sshKeyPassphrase: String?
    ) async throws -> PreparedConnectionUri {
        guard let sshConfiguration, sshConfiguration.enabled else {
            return PreparedConnectionUri(uri: connectionUri, sshTunnelID: nil)
        }

        guard supportsSSHTunnel(databaseType) else {
            throw DatabaseError.configurationError("SSH tunneling is not supported for \(databaseType.displayName)")
        }

        let remoteEndpoint = try remoteDatabaseEndpoint(from: connectionUri, databaseType: databaseType)
        let tunnelEndpoint = try await SSHTunnelService.shared.createTunnel(
            config: sshConfiguration,
            sshPassword: sshPassword,
            keyPassphrase: sshKeyPassphrase,
            remoteHost: remoteEndpoint.host,
            remotePort: remoteEndpoint.port
        )

        do {
            let rewritten = try rewriteConnectionUri(
                connectionUri,
                databaseType: databaseType,
                tunnelEndpoint: tunnelEndpoint
            )
            return PreparedConnectionUri(uri: rewritten, sshTunnelID: tunnelEndpoint.id)
        } catch {
            await SSHTunnelService.shared.closeTunnel(id: tunnelEndpoint.id)
            throw error
        }
    }

    private func supportsSSHTunnel(_ databaseType: DatabaseType) -> Bool {
        switch databaseType {
        case .postgres, .supabase, .mysql, .mongodb:
            return true
        case .convex, .sqlite, .redis:
            return false
        }
    }

    private func remoteDatabaseEndpoint(
        from connectionUri: String,
        databaseType: DatabaseType
    ) throws -> RemoteDatabaseEndpoint {
        guard let components = URLComponents(string: connectionUri) else {
            throw DatabaseError.invalidConnectionString("Unable to parse connection URI for SSH tunnel")
        }

        if components.scheme?.lowercased() == "mongodb+srv" {
            throw DatabaseError.configurationError("SSH tunneling requires a mongodb:// URI with an explicit host and port")
        }

        guard let host = components.host, !host.isEmpty else {
            throw DatabaseError.invalidConnectionString("Connection URI must include a host for SSH tunneling")
        }

        return RemoteDatabaseEndpoint(
            host: host,
            port: components.port ?? defaultPort(for: databaseType)
        )
    }

    private func rewriteConnectionUri(
        _ connectionUri: String,
        databaseType: DatabaseType,
        tunnelEndpoint: SSHTunnelEndpoint
    ) throws -> String {
        guard var components = URLComponents(string: connectionUri) else {
            throw DatabaseError.invalidConnectionString("Unable to rewrite connection URI for SSH tunnel")
        }

        if components.scheme?.lowercased() == "mongodb+srv" {
            throw DatabaseError.configurationError("SSH tunneling requires a mongodb:// URI with an explicit host and port")
        }

        components.host = tunnelEndpoint.localHost
        components.port = tunnelEndpoint.localPort

        if databaseType == .mongodb {
            var queryItems = components.queryItems ?? []
            queryItems.removeAll { $0.name.lowercased() == "directconnection" }
            queryItems.append(URLQueryItem(name: "directConnection", value: "true"))
            components.queryItems = queryItems
        } else if databaseType == .postgres || databaseType == .supabase {
            var queryItems = components.queryItems ?? []
            queryItems.removeAll {
                let name = $0.name.lowercased()
                return name == "pluk-ssh-tunnel" || name == "pluk-tls-server-name"
            }
            queryItems.append(URLQueryItem(name: "pluk-ssh-tunnel", value: "1"))
            if let originalHost = remoteDatabaseHost(from: connectionUri) {
                queryItems.append(URLQueryItem(name: "pluk-tls-server-name", value: originalHost))
            }
            components.queryItems = queryItems
        }

        guard let rewritten = components.url?.absoluteString else {
            throw DatabaseError.invalidConnectionString("Unable to create SSH tunnel connection URI")
        }

        return rewritten
    }

    private func remoteDatabaseHost(from connectionUri: String) -> String? {
        guard let components = URLComponents(string: connectionUri),
              let host = components.host,
              !host.isEmpty else {
            return nil
        }
        return host
    }

    private func defaultPort(for databaseType: DatabaseType) -> Int {
        switch databaseType {
        case .mysql:
            return 3306
        case .mongodb:
            return 27017
        case .redis:
            return 6379
        default:
            return 5432
        }
    }
    
    func setCurrentSchema(_ schema: String) {
        guard currentSchema != schema else { return }
        self.currentSchema = schema
        NotificationCenter.default.post(name: .connectedDatabaseChanged, object: self)
    }
    
    func switchActiveDatabase(to database: any DatabaseWrapper) async throws {
        guard let driverBox = activeDriverBox else {
            throw DatabaseError.operationFailed("No active database driver")
        }
        
        try await driverBox.switchDatabase(to: database.name)
        self.connectedDatabase = database
        currentDeploymentURL = await driverBox.getCurrentDeploymentUrl()
        
        // Post notification about database switch
        NotificationCenter.default.post(name: .connectedDatabaseChanged, object: self)
    }
    
    func disconnect() async {
        // Cancel all active subscriptions (this also clears subscription caches)
        cancelAllSubscriptions()
        
        await activeDriverBox?.disconnect()
        await SSHTunnelService.shared.closeTunnel(id: activeSSHTunnelID)
        activeSSHTunnelID = nil
        activeConnection = nil
        activeDriverBox = nil
        connectedDatabase = nil
        currentSchema = nil
        currentDeploymentURL = nil
        clearCache()
    }
    
    func reconnect() async throws {
        guard let driverBox = activeDriverBox else {
            throw DatabaseError.operationFailed("No active database driver")
        }

        try await driverBox.reconnect()
        currentDeploymentURL = await driverBox.getCurrentDeploymentUrl()
    }

    // MARK: - Real-time Support
    
    var supportsRealTime: Bool {
        return activeConnection?.databaseType.supportsRealTime ?? false
    }
    
    func subscribeToTableChanges(
           tabId: UUID,
           tableName: String,
           schema: String?,
           filter: String?,
           limit: Int = 200,
           sortBy: String? = nil,
           ascending: Bool? = nil,
           page: Int? = nil,
           onUpdate: @escaping @Sendable (QueryResult) -> Void,
           onError: @escaping @Sendable (Error) -> Void
       ) async throws {
           guard let driverBox = activeDriverBox else {
               throw DatabaseError.operationFailed("No active database driver")
           }
           
           let subscriptionKey = tabId.uuidString
           
           // Cancel existing subscription for this tab if any
           if let existingTask = activeSubscriptionTasks[subscriptionKey] {
               existingTask.cancel()
               activeSubscriptionTasks.removeValue(forKey: subscriptionKey)

               // Clear subscription cache for the previous table synchronously
               // so the new subscription doesn't race with a stale dedup hash.
               if let previousTableName = subscriptionTableNames[subscriptionKey] {
                   await driverBox.clearSubscriptionCache(for: previousTableName)
               }
               subscriptionTableNames.removeValue(forKey: subscriptionKey)
           }
           
           // Create new subscription task
           let subscriptionTask = Task {
               do {
                   try await driverBox.subscribeToCollectionChanges(
                       collectionName: tableName,
                       databaseSchema: schema,
                       filter: filter,
                       limit: limit,
                       sortBy: sortBy,
                       ascending: ascending,
                       page: page,
                       onUpdate: onUpdate,
                       onError: onError
                   )
               } catch {
                   await MainActor.run {
                       onError(error)
                   }
               }
           }
           
           activeSubscriptionTasks[subscriptionKey] = subscriptionTask
           subscriptionTableNames[subscriptionKey] = tableName
       }
       
       func cancelSubscription(forTabId tabId: UUID) {
           let subscriptionKey = tabId.uuidString
           if let task = activeSubscriptionTasks[subscriptionKey] {
               task.cancel()
               activeSubscriptionTasks.removeValue(forKey: subscriptionKey)
               
               // Clear subscription cache for this table
               if let tableName = subscriptionTableNames[subscriptionKey],
                  let activeDriverBox {
                   Task { [activeDriverBox] in
                       await activeDriverBox.clearSubscriptionCache(for: tableName)
                   }
               }
               subscriptionTableNames.removeValue(forKey: subscriptionKey)
           }
       }
       
       func cancelAllSubscriptions() {
           for task in activeSubscriptionTasks.values {
               task.cancel()
           }

           if let activeDriverBox {
               for tableName in subscriptionTableNames.values {
                   Task { [activeDriverBox] in
                       await activeDriverBox.clearSubscriptionCache(for: tableName)
                   }
               }
           }
           
           activeSubscriptionTasks.removeAll()
           subscriptionTableNames.removeAll()
       }
    
    // MARK: - Connectivity Test
    func testConnection(_ connection: Connection) async -> Result<Void, DatabaseError> {
        let driver = DatabaseDriverFactory.createDriver(for: connection.databaseType)
        var tunnelID: UUID?
        do {
            let preparedConnection = try await prepareConnectionUri(
                connection.connectionUri,
                databaseType: connection.databaseType,
                sshConfiguration: connection.sshConfiguration,
                sshPassword: connection.sshPassword,
                sshKeyPassphrase: connection.sshKeyPassphrase
            )
            tunnelID = preparedConnection.sshTunnelID
            try await driver.ping(to: preparedConnection.uri)
            await SSHTunnelService.shared.closeTunnel(id: tunnelID)
            return .success(())
        } catch let dbError as DatabaseError {
            await SSHTunnelService.shared.closeTunnel(id: tunnelID)
            return .failure(dbError)
        } catch {
            await SSHTunnelService.shared.closeTunnel(id: tunnelID)
            return .failure(DatabaseError.connectionFailed(error.localizedDescription))
        }
    }
    
    func testConnection(
        databaseType: DatabaseType,
        uri: String,
        sshConfiguration: SSHConfiguration? = nil,
        sshPassword: String? = nil,
        sshKeyPassphrase: String? = nil
    ) async -> Result<Void, DatabaseError> {
        let driver = DatabaseDriverFactory.createDriver(for: databaseType)
        var tunnelID: UUID?
        do {
            let preparedConnection = try await prepareConnectionUri(
                uri,
                databaseType: databaseType,
                sshConfiguration: sshConfiguration,
                sshPassword: sshPassword,
                sshKeyPassphrase: sshKeyPassphrase
            )
            tunnelID = preparedConnection.sshTunnelID
            try await driver.ping(to: preparedConnection.uri)
            await SSHTunnelService.shared.closeTunnel(id: tunnelID)
            return .success(())
        } catch let dbError as DatabaseError {
            await SSHTunnelService.shared.closeTunnel(id: tunnelID)
            return .failure(dbError)
        } catch {
            await SSHTunnelService.shared.closeTunnel(id: tunnelID)
            return .failure(DatabaseError.connectionFailed(error.localizedDescription))
        }
    }
    
    // MARK: - Database Operations
    func getBuildInfo() async throws -> BuildInfo? {
        guard let activeDriverBox else { return nil }
        return try await activeDriverBox.getBuildInfo()
    }
    
    /// Get the current deployment URL (useful for Convex environments)
    func getCurrentDeploymentUrl() -> String? {
        currentDeploymentURL
    }

    func getFunctionDefinition(oid: String) async throws -> String {
        guard let activeDriverBox,
              let definition = try await activeDriverBox.getFunctionDefinition(oid: oid) else {
            throw DatabaseError.operationFailed("Function definitions are only available for PostgreSQL connections")
        }
        return definition
    }

    func buildUpdatedConvexEmbeddedToken() async -> String? {
        guard let activeDriverBox else { return nil }
        return await activeDriverBox.buildUpdatedConvexEmbeddedToken()
    }

    func refreshConvexDeployments() async throws -> [any DatabaseWrapper] {
        guard let activeDriverBox else {
            throw DatabaseError.operationFailed("No active database connection")
        }

        let deployments = try await activeDriverBox.refreshConvexDeployments()
        currentDeploymentURL = await activeDriverBox.getCurrentDeploymentUrl()
        return deployments
    }
    
    func listDatabases() async throws -> [any DatabaseWrapper] {
        guard let activeDriverBox else {
            throw DatabaseError.operationFailed("No active database connection")
        }
        return try await activeDriverBox.listDatabases()
    }
    
    func listCollections(schema: String?) async throws -> [any CollectionWrapper] {
        guard let activeDriverBox else {
            throw DatabaseError.operationFailed("No active database connection")
        }
        return try await activeDriverBox.listCollections(schema: schema)
    }

    // MARK: - Redis Operations

    func scanRedisKeys(
        cursor: UInt64 = 0,
        pattern: String? = nil,
        type: RedisKeyType? = nil,
        count: Int = 200
    ) async throws -> RedisScanPage {
        try await requireRedisDriverBox().scanRedisKeys(
            cursor: cursor,
            pattern: pattern,
            type: type,
            count: count
        )
    }

    func redisKeyMetadata(for key: RedisKey) async throws -> RedisKeyMetadata {
        try await requireRedisDriverBox().redisKeyMetadata(for: key)
    }

    func redisValue(
        for key: RedisKey,
        page: RedisValuePage = RedisValuePage()
    ) async throws -> RedisValue {
        try await requireRedisDriverBox().redisValue(for: key, page: page)
    }

    func updateRedisValue(
        _ update: RedisValueUpdate,
        for key: RedisKey,
        preserveTTL: Bool = true
    ) async throws {
        try await requireRedisDriverBox().updateRedisValue(update, for: key, preserveTTL: preserveTTL)
    }

    func renameRedisKey(_ key: RedisKey, to newKey: RedisKey, overwrite: Bool = false) async throws {
        try await requireRedisDriverBox().renameRedisKey(key, to: newKey, overwrite: overwrite)
    }

    @discardableResult
    func deleteRedisKeys(_ keys: [RedisKey], asynchronously: Bool = true) async throws -> Int {
        try await requireRedisDriverBox().deleteRedisKeys(keys, asynchronously: asynchronously)
    }

    @discardableResult
    func setRedisExpiration(for key: RedisKey, milliseconds: Int64?) async throws -> Bool {
        try await requireRedisDriverBox().setRedisExpiration(for: key, milliseconds: milliseconds)
    }

    func executeRedisCommand(
        _ command: RedisCommand,
        analysis suppliedAnalysis: RedisCommandAnalysis? = nil,
        confirmationGranted: Bool = false
    ) async throws -> RedisCommandResult {
        let analysis = try validatedRedisCommandAnalysis(for: command, supplied: suppliedAnalysis)
        guard analysis.allowsExecution else {
            throw DatabaseError.operationFailed(
                analysis.executionPolicy.message ?? "This Redis command is unavailable"
            )
        }
        guard !analysis.requiresConfirmation || confirmationGranted else {
            throw DatabaseError.operationFailed(
                analysis.executionPolicy.message ?? "This Redis command requires confirmation"
            )
        }

        let driverBox = try requireRedisDriverBox()
        let startedAt = ContinuousClock.now

        do {
            let result = try await driverBox.executeRedisCommand(command)
            queryHistoryService?.recordRedisCommand(
                analysis: analysis,
                databaseType: .redis,
                databaseName: connectedDatabase?.name,
                executionDurationMs: Int(result.durationMilliseconds.rounded()),
                wasSuccessful: true
            )
            return result
        } catch {
            let duration = startedAt.duration(to: .now)
            let durationMilliseconds = Int(duration.components.seconds * 1_000)
                + Int(duration.components.attoseconds / 1_000_000_000_000_000)
            queryHistoryService?.recordRedisCommand(
                analysis: analysis,
                databaseType: .redis,
                databaseName: connectedDatabase?.name,
                executionDurationMs: durationMilliseconds,
                wasSuccessful: false,
                errorMessage: error.localizedDescription
            )
            throw error
        }
    }

    func executeRedisCommand(
        _ commandText: String,
        confirmationGranted: Bool = false
    ) async throws -> RedisCommandResult {
        let analysis = try RedisCommandSafety.analyze(commandText)
        return try await executeRedisCommand(
            analysis.transportCommand,
            analysis: analysis,
            confirmationGranted: confirmationGranted
        )
    }

    private func requireRedisDriverBox() throws -> DatabaseDriverBox {
        guard activeConnection?.databaseType == .redis, let activeDriverBox else {
            throw DatabaseError.operationFailed("No active Redis connection")
        }
        return activeDriverBox
    }

    private func validatedRedisCommandAnalysis(
        for command: RedisCommand,
        supplied: RedisCommandAnalysis?
    ) throws -> RedisCommandAnalysis {
        let parsed = try ParsedRedisCommand(
            arguments: command.arguments.map { RedisCommandToken(bytes: Array($0)) }
        )
        if let supplied {
            guard supplied.command == parsed else {
                throw DatabaseError.operationFailed("Redis command analysis does not match the command arguments")
            }
            return supplied
        }
        return RedisCommandSafety.analyze(parsed)
    }

    // MARK: - Document Operations
    /// Exposes the underlying driver actor so prewarm paths can fire DB queries
    /// without going through this @MainActor entry point. Calls into the
    /// returned actor hop to its own executor (not Main), so they don't block
    /// behind tab UI mounting.
    func currentDriverBox() -> DatabaseDriverBox? {
        activeDriverBox
    }

    func findDocuments(
        in collectionName: String,
        databaseSchema: String?,
        filter: String = "",
        skip: Int = 0,
        limit: Int = 300,
        sortBy: String?,
        ascending: Bool?
    ) async throws -> QueryResult {
        guard let activeDriverBox,
              let connection = activeConnection else {
            throw DatabaseError.operationFailed("No active database connection")
        }
        
        let result: QueryResult
        
        switch connection.databaseType {
        case .postgres, .supabase, .convex, .mysql, .sqlite, .redis:
            result = try await activeDriverBox.findDocuments(
                in: collectionName,
                databaseSchema: databaseSchema,
                filter: ["rawQuery": .string(filter)],
                skip: skip,
                limit: limit,
                sortBy: sortBy,
                ascending: ascending
            )
            
        case .mongodb:
            result = try await activeDriverBox.findDocuments(
                in: collectionName,
                databaseSchema: databaseSchema,
                filter: ["rawQuery": .string(filter)],
                skip: skip,
                limit: limit,
                sortBy: nil,
                ascending: nil
            )
        }
        
        return result
    }
    
    /// Generates a filter query from conditions using the appropriate database driver
    func generateFilterQuery(from conditions: [FilterCondition], tableName: String, databaseSchema: String?) -> String {
        guard let connection = activeConnection else {
            return ""
        }
        
        switch connection.databaseType {
        case .postgres, .supabase:
            return PostgreSQLDriver().generateFilterQuery(from: conditions, tableName: tableName, databaseSchema: databaseSchema)
        case .sqlite:
            return SQLiteDriver().generateFilterQuery(from: conditions, tableName: tableName)
        case .convex:
            return ConvexDriver().generateFilterQuery(from: conditions, tableName: tableName)
        case .mysql:
            return MySQLDriver().generateFilterQuery(from: conditions, tableName: tableName)
        case .mongodb:
            // TODO: Implement MongoDB filter generation
            return ""
        case .redis:
            return ""
        }
    }
    
    func getSchema(for collectionName: String, databaseSchema: String?, forceFetch: Bool = false) async throws -> DatabaseSchemaResult? {
        guard let activeDriverBox else {
            throw DatabaseError.operationFailed("No active database connection")
        }

        if forceFetch {
            await activeDriverBox.clearSchemaCache(for: collectionName, schema: databaseSchema)
        }

        return try await activeDriverBox.getSchema(for: collectionName, schema: databaseSchema)
    }
    
    func getInformationSchema() async throws -> [InformationSchema] {
        guard let activeDriverBox else {
            throw DatabaseError.operationFailed("No active database connection")
        }
        return try await activeDriverBox.getInformationSchema()
    }

    func getIndexes(for collectionName: String, databaseSchema: String?, forceFetch: Bool = false) async throws -> [DatabaseIndexInfo]? {
        guard let activeDriverBox else {
            throw DatabaseError.operationFailed("No active database connection")
        }

        if forceFetch {
            await activeDriverBox.clearSchemaCache(for: collectionName, schema: databaseSchema)
        }

        return try await activeDriverBox.getIndexes(for: collectionName, schema: databaseSchema)
    }

    func getDocumentCount(for collectionName: String, filter: [String: Any] = [:]) async throws -> Int {
        guard let activeDriverBox else { return 0 }
        return try await activeDriverBox.getDocumentCount(for: collectionName, filter: try makeDriverDocument(from: filter))
    }
    
    func getDatabaseMetadata() async throws -> [any DatabaseWrapper] {
        guard let activeDriverBox else {
            return []
        }
        
        return try await activeDriverBox.getDatabaseMetadata()
    }
    
    // MARK: - Database Management
    func createDatabase(named databaseName: String, options: CreateDatabaseOptions = .default) async throws {
        guard let activeDriverBox,
              let connection = activeConnection else {
            throw DatabaseError.operationFailed("No active database connection")
        }

        try await activeDriverBox.createDatabase(named: databaseName, options: options)
        clearCache()

        Task { @MainActor in
            AnalyticsService.shared.trackDatabaseCreated(databaseType: connection.databaseType)
        }
    }

    func createSchema(named schemaName: String, options: CreateSchemaOptions = .default) async throws {
        guard let activeDriverBox else {
            throw DatabaseError.operationFailed("No active database connection")
        }

        try await activeDriverBox.createSchema(named: schemaName, options: options)
        clearCache()
    }

    // MARK: - Collection Management
    func createCollection(named collectionName: String) async throws {
        guard let activeDriverBox else {
            throw DatabaseError.operationFailed("No active database connection")
        }

        try await activeDriverBox.createCollection(named: collectionName)
        clearCache() // Clear cache after structural changes
    }
    
    func renameCollection(databaseSchema: String?, from oldName: String, to newName: String) async throws {
        guard let activeDriverBox else {
            throw DatabaseError.operationFailed("No active database connection")
        }
        
        try await activeDriverBox.renameCollection(databaseSchema: databaseSchema, from: oldName, to: newName)
        clearCache() // Clear cache after structural changes
    }
    
    func deleteCollection(named collectionName: String, databaseSchema: String?) async throws {
        guard let activeDriverBox else {
            throw DatabaseError.operationFailed("No active database connection")
        }
        
        try await activeDriverBox.deleteCollection(named: collectionName, databaseSchema: databaseSchema)
        clearCache() // Clear cache after structural changes
    }
    
    // MARK: - Document Modification
    func createDocument(in collectionName: String, databaseSchema: String?, document: [String: Any]) async throws {
        guard let activeDriverBox,
              let connection = activeConnection else {
            throw DatabaseError.operationFailed("No active database connection")
        }

        let startTime = ContinuousClock.now
        let documentDescription = "INSERT INTO \(collectionName) - \(document.keys.joined(separator: ", "))"

        do {
            let driverDocument = try makeDriverDocument(from: document)
            try await activeDriverBox.createDocument(in: collectionName, databaseSchema: databaseSchema, document: driverDocument)

            let duration = startTime.duration(to: .now)
            let durationMs = Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)

            recordQueryHistory(
                query: documentDescription,
                queryType: .insert,
                source: .documentCreate,
                databaseType: connection.databaseType,
                databaseName: connectedDatabase?.name,
                schemaName: databaseSchema,
                tableName: collectionName,
                executionDurationMs: durationMs,
                rowsAffected: 1,
                wasSuccessful: true
            )

            Task { @MainActor in
                AnalyticsService.shared.trackDocumentCreated(databaseType: connection.databaseType)
            }

            clearDocumentCache(for: collectionName)
        } catch {
            let duration = startTime.duration(to: .now)
            let durationMs = Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)

            recordQueryHistory(
                query: documentDescription,
                queryType: .insert,
                source: .documentCreate,
                databaseType: connection.databaseType,
                databaseName: connectedDatabase?.name,
                schemaName: databaseSchema,
                tableName: collectionName,
                executionDurationMs: durationMs,
                wasSuccessful: false,
                errorMessage: error.localizedDescription
            )

            throw error
        }
    }

    func updateDocument(in collectionName: String, databaseSchema: String?, id: DatabaseRecordID, data: [String: Any]) async throws {
        guard let activeDriverBox,
              let connection = activeConnection else {
            throw DatabaseError.operationFailed("No active database connection")
        }

        let startTime = ContinuousClock.now
        let setDescription = data.map { key, value in
            let escaped = "\(value)".replacing("'", with: "''")
            return "\"\(key)\" = \(value is NSNull ? "NULL" : "'\(escaped)'")"
        }.joined(separator: ", ")
        let qualifiedTable = databaseSchema.map { "\"\($0)\".\"\(collectionName)\"" } ?? "\"\(collectionName)\""
        let documentDescription = "UPDATE \(qualifiedTable) SET \(setDescription) WHERE \"\(id.columnName)\" = '\(id.value)'"

        do {
            let driverDocument = try makeDriverDocument(from: data)
            try await activeDriverBox.updateDocument(in: collectionName, databaseSchema: databaseSchema, id: id, data: driverDocument)

            let duration = startTime.duration(to: .now)
            let durationMs = Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)

            recordQueryHistory(
                query: documentDescription,
                queryType: .update,
                source: .documentUpdate,
                databaseType: connection.databaseType,
                databaseName: connectedDatabase?.name,
                schemaName: databaseSchema,
                tableName: collectionName,
                executionDurationMs: durationMs,
                rowsAffected: 1,
                wasSuccessful: true
            )

            Task { @MainActor in
                AnalyticsService.shared.trackDocumentUpdated(databaseType: connection.databaseType)
            }
        } catch {
            let duration = startTime.duration(to: .now)
            let durationMs = Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)

            recordQueryHistory(
                query: documentDescription,
                queryType: .update,
                source: .documentUpdate,
                databaseType: connection.databaseType,
                databaseName: connectedDatabase?.name,
                schemaName: databaseSchema,
                tableName: collectionName,
                executionDurationMs: durationMs,
                wasSuccessful: false,
                errorMessage: error.localizedDescription
            )

            throw error
        }
    }

    func deleteDocument(in collectionName: String, databaseSchema: String?, id: DatabaseRecordID) async throws {
        guard let activeDriverBox,
              let connection = activeConnection else {
            throw DatabaseError.operationFailed("No active database connection")
        }

        let startTime = ContinuousClock.now
        let qualifiedTable = databaseSchema.map { "\"\($0)\".\"\(collectionName)\"" } ?? "\"\(collectionName)\""
        let documentDescription = "DELETE FROM \(qualifiedTable) WHERE \"\(id.columnName)\" = '\(id.value)'"

        do {
            try await activeDriverBox.deleteDocument(in: collectionName, databaseSchema: databaseSchema, id: id)

            let duration = startTime.duration(to: .now)
            let durationMs = Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)

            recordQueryHistory(
                query: documentDescription,
                queryType: .delete,
                source: .documentDelete,
                databaseType: connection.databaseType,
                databaseName: connectedDatabase?.name,
                schemaName: databaseSchema,
                tableName: collectionName,
                executionDurationMs: durationMs,
                rowsAffected: 1,
                wasSuccessful: true
            )

            Task { @MainActor in
                AnalyticsService.shared.trackDocumentDeleted(databaseType: connection.databaseType)
            }

            clearDocumentCache(for: collectionName)
        } catch {
            let duration = startTime.duration(to: .now)
            let durationMs = Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)

            recordQueryHistory(
                query: documentDescription,
                queryType: .delete,
                source: .documentDelete,
                databaseType: connection.databaseType,
                databaseName: connectedDatabase?.name,
                schemaName: databaseSchema,
                tableName: collectionName,
                executionDurationMs: durationMs,
                wasSuccessful: false,
                errorMessage: error.localizedDescription
            )

            throw error
        }
    }
    
    // MARK: - Raw Query Execution
    func executeRawQuery(_ query: String, databaseSchema: String? = nil) async throws -> [QueryResult] {
        guard let activeDriverBox,
              let connection = activeConnection else {
            throw DatabaseError.operationFailed("No active database connection")
        }

        let schemaToUse = databaseSchema ?? currentSchema
        let startTime = ContinuousClock.now

        do {
            let results = try await activeDriverBox.executeRawQuery(query, databaseSchema: schemaToUse)
            let duration = startTime.duration(to: .now)
            let durationMs = Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)

            let totalRows = results.reduce(0) { $0 + $1.rows.count }

            recordQueryHistory(
                query: query,
                source: .sqlEditor,
                databaseType: connection.databaseType,
                databaseName: connectedDatabase?.name,
                schemaName: schemaToUse,
                executionDurationMs: durationMs,
                rowsAffected: totalRows,
                wasSuccessful: true
            )

            let queryType = AnalyticsService.detectQueryType(from: query)
            Task { @MainActor in
                AnalyticsService.shared.trackQueryExecuted(
                    databaseType: connection.databaseType,
                    queryType: queryType,
                    executionTimeMs: durationMs,
                    rowCount: totalRows,
                    success: true
                )
            }

            return results
        } catch {
            let duration = startTime.duration(to: .now)
            let durationMs = Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)

            recordQueryHistory(
                query: query,
                source: .sqlEditor,
                databaseType: connection.databaseType,
                databaseName: connectedDatabase?.name,
                schemaName: schemaToUse,
                executionDurationMs: durationMs,
                wasSuccessful: false,
                errorMessage: error.localizedDescription
            )

            let errorCategory = AnalyticsService.categorizeError(error)
            Task { @MainActor in
                AnalyticsService.shared.trackQueryFailed(
                    databaseType: connection.databaseType,
                    errorCategory: errorCategory
                )
            }

            throw error
        }
    }
    
    // MARK: - AI Operations
    func buildSystemPrompt(for collectionName: String, databaseSchema: String?) async throws -> String {
        guard let activeDriverBox else {
            throw DatabaseError.operationFailed("No active database connection")
        }
        
        return try await activeDriverBox.buildSystemPrompt(for: collectionName, databaseSchema: databaseSchema)
    }
    
    // MARK: - AI Operations
    func buildAICommandPromptSystemPrompt(_ message: String) async throws -> String {
        guard let activeDriverBox else {
            throw DatabaseError.operationFailed("No active database connection")
        }
        
        return try await activeDriverBox.buildAICommandPromptSystemPrompt(message)
    }
    
    // MARK: - Cache Management
    private func clearCache() {
        queryCache.removeAll()
    }
    
    private func clearDocumentCache(for collectionName: String) {
        let keysToRemove = queryCache.keys.filter { $0.hasPrefix(collectionName) }
        keysToRemove.forEach { queryCache.removeValue(forKey: $0) }
    }
    
    // MARK: - Getters for Current State
    var currentConnection: Connection? { activeConnection }
    var currentDatabase: (any DatabaseWrapper)? { connectedDatabase }
    var isConnected: Bool {
        activeDriverBox != nil && connectedDatabase?.name.isEmpty == false
    }
}
