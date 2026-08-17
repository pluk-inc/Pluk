//
//  ConnectionInstance.swift
//  Collection
//
//  Created by Fauzaan on 1/21/25.
//

import Foundation
import MongoKitten
import MongoCore
import SwiftUI
import SwiftData

struct CachedCollectionWrapper: CollectionWrapper, Codable, Sendable {
    var id: String { name }
    let name: String
    let type: String
    let schema: String?

    enum CodingKeys: String, CodingKey {
        case name, type, schema
    }
}

@Observable @MainActor class ConnectionInstance: Identifiable {
    let id = UUID()
    let connection: Connection
    private var _databaseDriver: (any DatabaseDriver)?
    @ObservationIgnored
    nonisolated(unsafe) private var connectedDatabaseObserver: NSObjectProtocol?
    private var connectionAttemptID = UUID()
    private var isConnectionAttemptActive = false
    var databaseService = DatabaseService()
    var queryHistoryService: QueryHistoryService?
    var recentTablesService: RecentTablesService?
    
    // Public getter for database driver (needed by ConnectionService)
    var databaseDriver: (any DatabaseDriver)? {
        _databaseDriver
    }
    
    var connectedDatabase: (any DatabaseWrapper)? {
        databaseService.connectedDatabase
    }
    
    var databaseType: DatabaseType? {
        connection.databaseType
    }
    
    // Generic collections and databases storage
    var collections: [String: [any CollectionWrapper]] = [:]
    var isLoadingCollections: Bool = false
    var databases: [any DatabaseWrapper] = []
    
    var documents: [String: PostgreSQLQueryResult] = [:]
    var schema: [String: DatabaseSchemaResult] = [:]
    
    // Legacy MongoDB support - these will be deprecated gradually
    var database: MongoDatabase?
    
    // Connection state
    var connectionStatus: ConnectionStatus = .disconnected
    var connectionGeneration = 0
    var connectionVersion: String?
    var lastError: Error?
    
    // UI State
    var tabs: [DatabaseTab] = []

    var selectedTab: DatabaseTab?

    /// Pre-created `TableDataController` instances keyed by tab id. Created at
    /// `createNewTab` time so the data fetch can race the lazy UI mount. The
    /// `TableContentViewController` adopts the existing controller when it
    /// finally mounts, then paints whatever state the fetch has reached.
    @ObservationIgnored
    var tableDataControllers: [UUID: TableDataController] = [:]

    var isLoadingAnimation: Bool = true
    var isLoading = true
    var error: Error?
    var lastFetchTimestamp: Date = Date()

    init(connection: Connection) {
        self.connection = connection
        setupNotificationObservation()
        setupQueryHistoryService()
    }

    @MainActor
    private func setupQueryHistoryService() {
        guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else { return }
        let modelContext = ModelContext(appDelegate.sharedModelContainer)
        queryHistoryService = QueryHistoryService(
            modelContext: modelContext,
            connectionKeychainId: connection.keychainId
        )
        databaseService.queryHistoryService = queryHistoryService
        recentTablesService = RecentTablesService(
            modelContext: modelContext,
            connectionKeychainId: connection.keychainId
        )
    }

    private func setupNotificationObservation() {
        // Listen for database service changes and repost them with self as object
        connectedDatabaseObserver = NotificationCenter.default.addObserver(
            forName: .connectedDatabaseChanged,
            object: databaseService,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            NotificationCenter.default.post(name: .connectedDatabaseChanged, object: self)
        }
    }

    deinit {
        if let connectedDatabaseObserver {
            NotificationCenter.default.removeObserver(connectedDatabaseObserver)
        }
    }
    
    func connect(targetDatabaseName: String? = nil) async throws {
        guard connectionStatus != .connected, !isConnectionAttemptActive else { return }

        let attemptID = UUID()
        let startTime = ContinuousClock.now
        let databaseType = connection.databaseType
        connectionAttemptID = attemptID
        isConnectionAttemptActive = true
        defer {
            if isCurrentConnectionAttempt(attemptID) {
                isConnectionAttemptActive = false
            }
        }

        connectionStatus = .connecting
        connectionVersion = nil
        lastError = nil
        AnalyticsService.shared.trackConnectionAttemptStarted(
            databaseType: databaseType,
            source: "saved_connection",
            isReconnect: false
        )

        do {
            try await databaseService.setActiveConnection(
                connection,
                targetDatabase: targetDatabaseName
            )
            guard shouldContinueConnectionAttempt(attemptID) else {
                await finishCancelledConnectionAttemptIfNeeded(attemptID)
                return
            }

            do {
                let buildInfo = try await databaseService.getBuildInfo()
                guard shouldContinueConnectionAttempt(attemptID) else {
                    await finishCancelledConnectionAttemptIfNeeded(attemptID)
                    return
                }
                connectionVersion = buildInfo?.version
            } catch {
            }

            await loadDatabases(source: "initial_connection")
            guard shouldContinueConnectionAttempt(attemptID) else {
                await finishCancelledConnectionAttemptIfNeeded(attemptID)
                return
            }
            connectionStatus = .connected
            connectionGeneration += 1

            // Persist fetched deployments back to keychain so they're cached for next connect
            if connection.databaseType == .convex,
               let updatedToken = await databaseService.buildUpdatedConvexEmbeddedToken() {
                connection.password = updatedToken
            }

            lastError = nil
            AnalyticsService.shared.trackConnectionAttemptSucceeded(
                databaseType: databaseType,
                source: "saved_connection",
                isReconnect: false,
                durationMs: AnalyticsService.durationMilliseconds(since: startTime)
            )
        } catch is CancellationError {
            await finishCancelledConnectionAttemptIfNeeded(attemptID)
        } catch {
            guard isCurrentConnectionAttempt(attemptID) else { return }

            await databaseService.disconnect()
            lastError = error
            connectionStatus = .error
            let errorType = AnalyticsService.categorizeError(error)
            AnalyticsService.shared.trackConnectionAttemptFailed(
                databaseType: databaseType,
                source: "saved_connection",
                isReconnect: false,
                durationMs: AnalyticsService.durationMilliseconds(since: startTime),
                errorCategory: errorType
            )
            AnalyticsService.shared.trackConnectionFailed(
                databaseType: databaseType,
                errorType: errorType
            )
            throw error
        }
    }

    func reconnect() async throws {
        guard !isConnectionAttemptActive else { return }

        let attemptID = UUID()
        let startTime = ContinuousClock.now
        let databaseType = connection.databaseType
        connectionAttemptID = attemptID
        isConnectionAttemptActive = true
        defer {
            if isCurrentConnectionAttempt(attemptID) {
                isConnectionAttemptActive = false
            }
        }

        connectionStatus = .connecting
        connectionVersion = nil
        lastError = nil
        AnalyticsService.shared.trackConnectionAttemptStarted(
            databaseType: databaseType,
            source: "saved_connection",
            isReconnect: true
        )

        do {
            try await databaseService.reconnect()

            try await Task.sleep(for: .milliseconds(500))
            guard shouldContinueConnectionAttempt(attemptID) else {
                await finishCancelledConnectionAttemptIfNeeded(attemptID)
                return
            }
            connectionStatus = .connected
            connectionGeneration += 1
            lastError = nil
            AnalyticsService.shared.trackConnectionAttemptSucceeded(
                databaseType: databaseType,
                source: "saved_connection",
                isReconnect: true,
                durationMs: AnalyticsService.durationMilliseconds(since: startTime)
            )
        } catch is CancellationError {
            await finishCancelledConnectionAttemptIfNeeded(attemptID)
        } catch {
            guard isCurrentConnectionAttempt(attemptID) else { return }
            lastError = error
            connectionStatus = .error
            let errorCategory = AnalyticsService.categorizeError(error)
            AnalyticsService.shared.trackConnectionAttemptFailed(
                databaseType: databaseType,
                source: "saved_connection",
                isReconnect: true,
                durationMs: AnalyticsService.durationMilliseconds(since: startTime),
                errorCategory: errorCategory
            )
            throw error
        }
    }

    func prepareForDisconnect() {
        connectionAttemptID = UUID()
        isConnectionAttemptActive = false
        connectionStatus = .disconnected
        connectionVersion = nil
        lastError = nil
        connectionGeneration += 1
    }

    func disconnect() async {
        prepareForDisconnect()
        await databaseService.disconnect()
    }

    func loadDatabases(source: String = "manual_refresh") async {
        do {
            let databaseList = try await databaseService.listDatabases()
            guard connectionStatus != .disconnected, !Task.isCancelled else { return }
            self.databases = databaseList
            AnalyticsService.shared.trackDatabaseDiscoverySucceeded(
                databaseType: connection.databaseType,
                source: source,
                databaseCount: databaseList.count
            )

            // Notify that databases have been updated
            NotificationCenter.default.post(name: .databasesUpdated, object: self)
        } catch is CancellationError {
        } catch {
            guard connectionStatus != .disconnected, !Task.isCancelled else { return }
            lastError = error
            AnalyticsService.shared.trackDatabaseDiscoveryFailed(
                databaseType: connection.databaseType,
                source: source,
                errorCategory: AnalyticsService.categorizeError(error)
            )
            debugLog("Failed to load databases \(error)")
        }
    }

    private func isCurrentConnectionAttempt(_ attemptID: UUID) -> Bool {
        connectionAttemptID == attemptID
    }

    private func shouldContinueConnectionAttempt(_ attemptID: UUID) -> Bool {
        isCurrentConnectionAttempt(attemptID) && !Task.isCancelled
    }

    private func finishCancelledConnectionAttemptIfNeeded(_ attemptID: UUID) async {
        guard isCurrentConnectionAttempt(attemptID) else { return }
        isConnectionAttemptActive = false
        await databaseService.disconnect()
        connectionStatus = .disconnected
        connectionVersion = nil
        lastError = nil
    }
    
    func loadCollectionsForCurrentDatabase(schema: String?) async throws {
        guard let database = connectedDatabase, !database.name.isEmpty else {
            throw DatabaseError.databaseNotSelected
        }

        let databaseName = database.name
        isLoadingCollections = true
        defer { isLoadingCollections = false }

        // Restore cached collections instantly so the sidebar appears immediately.
        if collections[databaseName] == nil || collections[databaseName]?.isEmpty == true {
            let cached = loadCachedCollections(databaseName: databaseName, schema: schema)
            if !cached.isEmpty {
                collections[databaseName] = cached
            }
        }

        // Fetch fresh list in background and reconcile
        do {
            let freshCollections = try await databaseService.listCollections(schema: schema)
            try Task.checkCancellation()
            collections[databaseName] = freshCollections
            saveCachedCollections(
                freshCollections.map {
                    CachedCollectionWrapper(name: $0.name, type: $0.type, schema: $0.schema ?? schema)
                },
                databaseName: databaseName,
                schema: schema
            )
        } catch is CancellationError {
            return
        } catch {
            if collections[databaseName]?.isEmpty != false {
                collections[databaseName] = []
            }
            throw error
        }
    }

    private var collectionCacheKey: String {
        "cachedCollections_\(connection.keychainId)"
    }

    private func collectionCacheKeyFor(databaseName: String, schema: String?) -> String {
        "\(collectionCacheKey)_\(databaseName)_\(schema ?? "_default")"
    }

    private func loadCachedCollections(databaseName: String, schema: String?) -> [CachedCollectionWrapper] {
        let cacheKey = collectionCacheKeyFor(databaseName: databaseName, schema: schema)

        if let data = UserDefaults.standard.data(forKey: cacheKey),
           let cachedCollections = try? Foundation.JSONDecoder().decode([CachedCollectionWrapper].self, from: data) {
            return cachedCollections
        }

        let legacyNames = UserDefaults.standard.stringArray(forKey: cacheKey) ?? []
        return legacyNames.map {
            CachedCollectionWrapper(name: $0, type: "table", schema: schema)
        }
    }

    private func saveCachedCollections(_ collections: [CachedCollectionWrapper], databaseName: String, schema: String?) {
        let cacheKey = collectionCacheKeyFor(databaseName: databaseName, schema: schema)
        if let encodedCollections = try? Foundation.JSONEncoder().encode(collections) {
            UserDefaults.standard.set(encodedCollections, forKey: cacheKey)
        }
    }

    // Legacy MongoDB methods - these will be gradually refactored
    func findQueryBuilder(from collectionName: String) throws -> FindQueryBuilder {
        guard connection.databaseType == .mongodb,
              let collection = database?[collectionName] else {
            throw MongoError.collectionNotFound
        }
        
        return collection.find()
    }
    
    func findQueryBuilder(from collectionName: String, filter: Document = [:]) throws -> FindQueryBuilder {
        guard connection.databaseType == .mongodb,
              let collection = database?[collectionName] else {
            throw MongoError.collectionNotFound
        }
        
        return collection.find(filter)
    }
    
    func renameCollection(databaseSchema: String?, from oldName: String, to newName: String) async throws {
        guard let driver = _databaseDriver else {
            throw DatabaseError.operationFailed("No active database connection")
        }

        try await driver.renameCollection(databaseSchema: databaseSchema, from: oldName, to: newName)
        updateTabName(from: oldName, to: newName)
    }

    func createCollection(withName: String) async throws {
        guard let driver = _databaseDriver else {
            throw DatabaseError.operationFailed("No active database connection")
        }

        try await driver.createCollection(named: withName)
    }
    
    // MARK: - Tab Management
    func createNewTab(name: String, filterColumn: String? = nil, filterValue: String? = nil, databaseSchema: String? = nil) {
        // Remove quotes from name if present for consistent tab naming
        var cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanName.hasPrefix("\"") && cleanName.hasSuffix("\"") && cleanName.count > 1 {
            cleanName = String(cleanName.dropFirst().dropLast())
        }

        // Check for existing tab with same table name
        if let existingTab = tabs.first(where: { $0.name == cleanName && $0.databaseSchema == databaseSchema }) {
            // Check if filter parameters have actually changed
            let hasFilterChanged = existingTab.filterColumn != filterColumn ||
                                   existingTab.filterValue != filterValue

            // Update the existing tab's filter
            existingTab.filterColumn = filterColumn
            existingTab.filterValue = filterValue

            // Only force refresh if filter criteria changed
            existingTab.forceFetch = hasFilterChanged

            selectedTab = existingTab
            recordRecentTable(name: cleanName, schema: databaseSchema ?? existingTab.databaseSchema)
            return
        }

        // Create new tab if none exists for this table
        let newTab = DatabaseTab(
            name: cleanName,
            type: .browse,
            queryState: .idle,
            filterColumn: filterColumn,
            filterValue: filterValue,
            databaseSchema: databaseSchema
        )
        tabs.append(newTab)

        selectedTab = newTab
        prewarmTableDataController(for: newTab)
        recordRecentTable(name: cleanName, schema: databaseSchema)
    }

    /// Eagerly creates a `TableDataController` and kicks off the document
    /// fetch the moment a tab is appended, in parallel with the lazy UI mount
    /// in `LazyTableTabContainer`. Saves ~150–200 ms of perceived blank-content
    /// time on first table open. Only applies to databases that use the
    /// AppKit-native `TableContentViewController` path.
    private func prewarmTableDataController(for tab: DatabaseTab) {
        let dbType = connection.databaseType
        guard [.postgres, .sqlite, .mysql, .convex].contains(dbType) else { return }
        guard tableDataControllers[tab.id] == nil else { return }
        let controller = TableDataController(instance: self, tab: tab)
        tableDataControllers[tab.id] = controller
        // Use the non-MainActor prewarm path: DB queries run on the driver's
        // own actor, in parallel with the tab UI mount that's about to block
        // Main with TabBarView setup. Saves ~17–21ms on first table open.
        controller.prewarmFetch()
    }

    func createSQLEditorTab(withQuery query: String? = nil, autoRun: Bool = false, schema: String? = nil) {
        let newTab = DatabaseTab(
            name: "Query Editor",
            type: .sqlEditor,
            queryState: .idle,
            databaseSchema: schema
        )
        newTab.initialQuery = query
        newTab.autoRunInitialQuery = autoRun && query != nil
        tabs.append(newTab)

        selectedTab = newTab
    }

    /// Opens the command surface appropriate for this connection type.
    /// Redis does not use SQL-editor tabs, so generic new-tab entry points must
    /// route to its command workspace instead of creating a dead document tab.
    func createEditorTab() {
        if connection.databaseType == .redis {
            createRedisCommandTab()
        } else {
            createSQLEditorTab()
        }
    }

    func createRedisKeyTab(keyData: Data, displayName: String) {
        if let existingTab = tabs.first(where: {
            $0.type == .redisKey && $0.redisKeyData == keyData
        }) {
            selectedTab = existingTab
            return
        }

        let newTab = DatabaseTab(
            name: displayName,
            type: .redisKey,
            queryState: .idle
        )
        newTab.redisKeyData = keyData
        tabs.append(newTab)
        selectedTab = newTab
    }

    func createRedisCommandTab(withCommand command: String? = nil) {
        if command == nil, let existingTab = tabs.first(where: { $0.type == .redisCommand }) {
            selectedTab = existingTab
            return
        }

        let newTab = DatabaseTab(
            name: "Command Editor",
            type: .redisCommand,
            queryState: .idle
        )
        newTab.initialQuery = command
        tabs.append(newTab)
        selectedTab = newTab
    }

    private func recordRecentTable(name: String, schema: String?) {
        guard let dbName = connectedDatabase?.name, !dbName.isEmpty else { return }
        let tableType = collections[dbName]?.first {
            $0.name == name && $0.schema == schema
        }?.type ?? collections[dbName]?.first { $0.name == name }?.type ?? "table"
        Task { @MainActor [recentTablesService] in
            recentTablesService?.recordTableOpened(
                tableName: name,
                databaseName: dbName,
                schemaName: schema,
                tableType: tableType
            )
        }
    }

    func createFunctionEditorTab(name: String, definition: String, oid: String, schema: String?) {
        if let existingTab = tabs.first(where: { $0.type == .functionEditor && $0.functionOid == oid }) {
            selectedTab = existingTab
            return
        }

        let newTab = DatabaseTab(
            name: name,
            type: .functionEditor,
            queryState: .idle,
            databaseSchema: schema
        )
        newTab.initialQuery = definition
        newTab.functionOid = oid
        newTab.functionSchema = schema
        newTab.originalFunctionDefinition = definition
        tabs.append(newTab)
        selectedTab = newTab
    }

    func createCanvasTab() {
        if let existingTab = tabs.first(where: { $0.type == .canvas }) {
            selectedTab = existingTab
            return
        }

        let newTab = DatabaseTab(
            name: "Schema Visualizer",
            type: .canvas,
            queryState: .idle
        )
        tabs.append(newTab)
        selectedTab = newTab
    }
    
    func removeTab(_ tab: DatabaseTab) {
        guard !tabs.isEmpty else { return }

        if let index = tabs.firstIndex(where: { $0.id == tab.id }) {
            let wasSelected = selectedTab?.id == tab.id
            tableDataControllers.removeValue(forKey: tab.id)?.cancel()
            tabs.remove(at: index)

            // Only change selection if we removed the selected tab
            if wasSelected {
                if !tabs.isEmpty {
                    // Select the tab at the same index, or the previous one if we removed the last tab
                    let newSelectedIndex = min(index, tabs.count - 1)
                    selectedTab = tabs[newSelectedIndex]
                } else {
                    selectedTab = nil
                }
            }
            // If the removed tab wasn't selected, keep the current selection
        }
    }
    
    func updateTabName(from oldName: String, to newName: String) {
        if let tabIndex = tabs.firstIndex(where: { $0.name == oldName }) {
            tabs[tabIndex].name = newName
            
            if selectedTab?.name == oldName {
                selectedTab = tabs[tabIndex]
            }
        }
    }
    
    func selectTab(_ tab: DatabaseTab) {
        selectedTab = tab
    }
    
    func nextTab(_ currentTab: DatabaseTab) {
        if let currentIndex = tabs.firstIndex(where: { $0.id == currentTab.id }),
           currentIndex < tabs.count - 1 {
            selectedTab = tabs[currentIndex + 1]
        }
    }
    
    func previousTab(_ currentTab: DatabaseTab) {
        if let currentIndex = tabs.firstIndex(where: { $0.id == currentTab.id }),
           currentIndex > 0 {
            selectedTab = tabs[currentIndex - 1]
        }
    }
    
    func selectTabByIndex(_ index: Int) {
        guard index >= 0 && index < tabs.count else { return }
        selectedTab = tabs[index]
    }

    func moveTab(fromIndex: Int, toIndex: Int) {
        guard fromIndex != toIndex,
              fromIndex >= 0, fromIndex < tabs.count,
              toIndex >= 0, toIndex <= tabs.count else {
            return
        }

        var newTabs = tabs
        let tab = newTabs.remove(at: fromIndex)
        let adjustedIndex = toIndex > fromIndex ? toIndex - 1 : toIndex
        newTabs.insert(tab, at: adjustedIndex)
        tabs = newTabs
    }
    
}

enum ConnectionStatus: String {
    case connected = "Connected"
    case connecting = "Connecting"
    case disconnected = "Disconnected"
    case error = "Error"
}

enum ConnectionReadiness: Equatable {
    case disconnected
    case connecting
    case errored
    case needsDatabaseSelection
    case ready(database: String)
}

extension ConnectionInstance {
    var readiness: ConnectionReadiness {
        switch connectionStatus {
        case .disconnected: return .disconnected
        case .connecting: return .connecting
        case .error: return .errored
        case .connected:
            if let dbName = connectedDatabase?.name, !dbName.isEmpty {
                return .ready(database: dbName)
            }
            return .needsDatabaseSelection
        }
    }

    var isReady: Bool {
        if case .ready = readiness { return true }
        return false
    }
}
