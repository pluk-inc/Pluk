//
//  HomeView.swift
//  Collection
//
//  Created by Fauzaan on 1/17/25.
//

import AppKit
import SwiftData
import SwiftUI

struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    // Optional read: a non-optional @Environment traps fatally if any hosting
    // path (e.g. window restoration) presents HomeView without the injection.
    @Environment(SidebarViewModel.self) private var viewModel: SidebarViewModel?
    private var authService = WorkOSAuthService.shared
    @Query(sort: \Connection.lastOpenedAt, order: .reverse)
    private var connections: [Connection]
    @Query(sort: \Notebook.updatedAt, order: .reverse)
    private var notebooks: [Notebook]
    @State private var showCreateSheet = false
    @State private var showConnectionAlert = false
    @State private var pendingConnection: Connection?
    @State private var dockerCandidates: [DockerDatabaseCandidate] = []
    @State private var isLoadingDockerCandidates = false
    @State private var isDockerUnavailable = false
    @State private var dockerDiscoveryTask: Task<Void, Never>?
    @AppStorage("containerSyncEnabled") private var containerSyncEnabled = true

    private var allItems: [WorkspaceItem] {
        let items: [WorkspaceItem] =
            connections.map { .connection($0) } +
            notebooks.map { .notebook($0) }
        return items.sorted { $0.lastAccessedAt > $1.lastAccessedAt }
    }

    private var containerBackedConnectionIds: Set<String> {
        guard containerSyncEnabled else { return [] }
        var ids = Set(connections.filter(isContainerConnection).map(\.keychainId))
        ids.formUnion(linkedConnectionIds(for: dockerCandidates))
        return ids
    }

    private var stoppedContainerConnectionIds: Set<String> {
        guard containerSyncEnabled else { return [] }
        if isDockerUnavailable {
            return Set(connections.filter(isContainerConnection).map(\.keychainId))
        }
        return linkedConnectionIds(for: dockerCandidates.filter { !$0.isRunning })
    }

    private func isContainerConnection(_ connection: Connection) -> Bool {
        if let containerId = connection.containerId, !containerId.isEmpty {
            return true
        }
        if let containerName = connection.containerName, !containerName.isEmpty {
            return true
        }
        return false
    }

    private func linkedConnectionIds(for candidates: [DockerDatabaseCandidate]) -> Set<String> {
        return Set(
            candidates.flatMap { candidate in
                connectionsLinkedToContainer(for: candidate).map(\.keychainId)
            }
        )
    }

    private func connectionLinkedToContainer(for candidate: DockerDatabaseCandidate) -> Connection? {
        preferredConnection(from: connectionsLinkedToContainer(for: candidate), candidate: candidate)
    }

    private func connectionsLinkedToContainer(for candidate: DockerDatabaseCandidate) -> [Connection] {
        guard !candidate.containerName.isEmpty else { return [] }
        return connections.filter { connection in
            guard isContainerConnection(connection),
                  connection.databaseType == candidate.databaseType else {
                return false
            }

            if connection.containerId == candidate.id {
                return true
            }

            return connection.containerName == candidate.containerName
        }
    }

    private func preferredConnection(from connections: [Connection], candidate: DockerDatabaseCandidate) -> Connection? {
        connections.sorted { lhs, rhs in
            let lhsHasCurrentContainerId = lhs.containerId == candidate.id
            let rhsHasCurrentContainerId = rhs.containerId == candidate.id
            if lhsHasCurrentContainerId != rhsHasCurrentContainerId {
                return lhsHasCurrentContainerId
            }
            return lhs.lastOpenedAt > rhs.lastOpenedAt
        }
        .first
    }

    private var recentItems: [WorkspaceItem] {
        Array(allItems.prefix(8))
    }

    private var titleText: String {
        allItems.isEmpty ? "Welcome to Pluk" : "My Workspace"
    }

    private var subtitleText: String {
        allItems.isEmpty
            ? "Start by connecting your first database."
            : "Notebooks, connections, and everything in between."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading) {
                    Text(titleText)
                        .font(.title)
                        .fontWeight(.semibold)
                    Text(subtitleText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if !authService.isPro {
                    FreePlanBadge()
                        .padding(.top, 4)
                }
            }
            .padding(.top, 20)
            .padding(.horizontal, 28)
            .padding(.bottom, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if !recentItems.isEmpty {
                        RecentsSection(
                            items: recentItems,
                            containerBackedConnectionIds: containerBackedConnectionIds,
                            stoppedContainerConnectionIds: stoppedContainerConnectionIds,
                            onOpen: handleItemOpen
                        )
                    }

                    WorkspaceList(
                        items: allItems,
                        containerBackedConnectionIds: containerBackedConnectionIds,
                        stoppedContainerConnectionIds: stoppedContainerConnectionIds,
                        onOpenConnection: handleConnectionOpen,
                        onOpenNotebook: handleNotebookOpen,
                        onCreateConnection: { showCreateSheet = true },
                        onCreateNotebook: createAndOpenNotebook
                    )
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
            }
            .contentMargins(.trailing, 8, for: .scrollIndicators)
            .contentMargins(.bottom, 8, for: .scrollIndicators)
            .padding(.bottom, 8)
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .leading
        )
        .postHogScreenView("HomeView")
        .task {
            if containerSyncEnabled {
                await loadDockerCandidates()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            scheduleDockerCandidateLoad()
        }
        .onChange(of: containerSyncEnabled) { _, isEnabled in
            if isEnabled {
                scheduleDockerCandidateLoad()
            } else {
                stopContainerSync()
            }
        }
        .onDisappear {
            stopContainerSync()
        }
        .sheet(isPresented: $showCreateSheet) {
            CreateConnectionForm(onSavedConnection: { connection, isEditingExistingConnection in
                openSavedConnection(connection, isEditingExistingConnection: isEditingExistingConnection)
            })
                .frame(width: 480)
        }
        .alert("\"\(pendingConnection?.name ?? "")\" is already connected", isPresented: $showConnectionAlert) {
            Button("Continue Current Tab") {
                if let connection = pendingConnection,
                   let existingInstance = ConnectionService.shared.getExistingInstance(for: connection) {
                    connection.lastOpenedAt = Date()
                    viewModel?.changeActiveSidebarItem(.connection(existingInstance.id))
                    Task { @MainActor in
                        AnalyticsService.shared.trackConnectionOpened(
                            databaseType: connection.databaseType,
                            isFirstConnection: false
                        )
                    }
                }
                pendingConnection = nil
            }
            Button("Create New Tab") {
                if let connection = pendingConnection {
                    if ConnectionService.shared.presentPaywallIfAtOpenLimit() {
                        pendingConnection = nil
                        return
                    }
                    openNewConnectionTab(connection, isFirstConnection: false)
                }
                pendingConnection = nil
            }
            Button("Cancel", role: .cancel) {
                pendingConnection = nil
            }
        } message: {
            if let connection = pendingConnection {
                Text("You're already connected to \(connection.name) in another tab. Continuing will reuse the existing tab. Want to open a new one instead?")
            }
        }
    }

    // MARK: - Actions

    private func handleItemOpen(_ item: WorkspaceItem) {
        switch item {
        case .connection(let connection):
            handleConnectionOpen(connection)
        case .notebook(let notebook):
            handleNotebookOpen(notebook)
        }
    }

    private func scheduleDockerCandidateLoad() {
        guard containerSyncEnabled else {
            stopContainerSync()
            return
        }
        dockerDiscoveryTask?.cancel()
        dockerDiscoveryTask = Task {
            await loadDockerCandidates()
        }
    }

    private func loadDockerCandidates() async {
        guard containerSyncEnabled else {
            stopContainerSync()
            return
        }
        guard !isLoadingDockerCandidates else {
            debugLog("[HomeDocker] Discovery already running; skipping duplicate request")
            return
        }
        debugLog("[HomeDocker] Loading Docker candidates for Home")
        isLoadingDockerCandidates = true
        defer { isLoadingDockerCandidates = false }

        do {
            let discoveredCandidates = try await DockerContainerDiscoveryService().discoverDatabaseContainers()
            let readyCandidates = discoveredCandidates.filter(\.isReadyToConnect)
            isDockerUnavailable = false
            dockerCandidates = readyCandidates
            upsertDockerConnections(for: readyCandidates)
            pruneDockerConnections(discoveredCandidates: discoveredCandidates)

            let runningCount = readyCandidates.filter(\.isRunning).count
            let stoppedCount = readyCandidates.count - runningCount
            debugLog("[HomeDocker] Home workspace list updated: \(readyCandidates.count) ready candidate(s) (\(runningCount) running, \(stoppedCount) stopped); matched stopped connections=\(stoppedContainerConnectionIds.count)")
        } catch {
            if let discoveryError = error as? DockerContainerDiscoveryError {
                switch discoveryError {
                case .dockerUnavailable:
                    isDockerUnavailable = true
                    dockerCandidates = []
                case .sandboxPermissionDenied:
                    break
                }
            }
            debugLog("[HomeDocker] Docker discovery failed: \(error.localizedDescription)")
        }
    }

    private func stopContainerSync() {
        dockerDiscoveryTask?.cancel()
        dockerDiscoveryTask = nil
        dockerCandidates = []
        isDockerUnavailable = false
    }

    private func upsertDockerConnections(for candidates: [DockerDatabaseCandidate]) {
        var insertedCount = 0
        var updatedCount = 0
        for candidate in candidates {
            guard candidate.isReadyToConnect, !candidate.containerName.isEmpty else {
                continue
            }

            if let existingConnection = connectionLinkedToContainer(for: candidate) {
                update(existingConnection, from: candidate)
                updatedCount += 1
                continue
            }

            let connection = makeConnection(from: candidate)
            update(connection, from: candidate)
            connection.lastOpenedAt = candidate.startedAt ?? candidate.createdAt ?? .distantPast
            modelContext.insert(connection)

            insertedCount += 1
        }

        guard insertedCount > 0 || updatedCount > 0 else { return }
        do {
            try modelContext.save()
            debugLog("[HomeDocker] Auto-added \(insertedCount) Docker connection(s), updated \(updatedCount)")
        } catch {
            debugLog("[HomeDocker] Failed to save auto-added Docker connections: \(error.localizedDescription)")
        }
    }

    private func pruneDockerConnections(discoveredCandidates: [DockerDatabaseCandidate]) {
        let candidatesByKey = Dictionary(
            uniqueKeysWithValues: discoveredCandidates.map {
                (containerKey(name: $0.containerName, databaseType: $0.databaseType), $0)
            }
        )
        let containerConnectionsByKey = Dictionary(grouping: connections.filter { connection in
            guard isContainerConnection(connection),
                  let containerName = connection.containerName,
                  !containerName.isEmpty else {
                return false
            }
            return true
        }) { connection in
            containerKey(name: connection.containerName ?? "", databaseType: connection.databaseType)
        }

        var connectionsToDelete: [Connection] = []
        for (key, groupedConnections) in containerConnectionsByKey {
            guard let candidate = candidatesByKey[key] else {
                connectionsToDelete.append(contentsOf: groupedConnections)
                continue
            }

            guard groupedConnections.count > 1,
                  let connectionToKeep = preferredConnection(from: groupedConnections, candidate: candidate) else {
                continue
            }
            // Never auto-delete a connection that is currently open in a
            // window/tab — its ConnectionInstance still holds the model.
            connectionsToDelete.append(contentsOf: groupedConnections.filter {
                $0.keychainId != connectionToKeep.keychainId
                    && ConnectionService.shared.getExistingInstance(for: $0) == nil
            })
        }

        guard !connectionsToDelete.isEmpty else { return }

        for connection in connectionsToDelete {
            QueryHistoryService.deleteHistoryForConnection(
                modelContext: modelContext,
                connectionKeychainId: connection.keychainId
            )
            connection.cleanupKeychain()
            modelContext.delete(connection)
        }

        do {
            try modelContext.save()
            debugLog("[HomeDocker] Removed \(connectionsToDelete.count) stale Docker connection(s)")
        } catch {
            debugLog("[HomeDocker] Failed to remove stale Docker connections: \(error.localizedDescription)")
        }
    }

    private func containerKey(name: String, databaseType: DatabaseType) -> String {
        "\(databaseType.rawValue):\(name)"
    }

    private func update(_ connection: Connection, from candidate: DockerDatabaseCandidate) {
        connection.containerName = candidate.containerName
        connection.containerId = candidate.id
        connection.hostname = candidate.host
        connection.port = candidate.port
        connection.username = candidate.username
        connection.defaultDatabase = candidate.databaseName
        connection.updatedAt = Date()

        switch candidate.databaseType {
        case .postgres, .mysql, .redis:
            connection.url = nil
            connection.sslMode = "disable"
        case .mongodb:
            connection.url = candidate.connectionURI
            connection.sslMode = nil
        case .convex, .supabase, .sqlite:
            break
        }

        if let password = candidate.password, !password.isEmpty {
            connection.password = password
        }
    }

    private func makeConnection(from candidate: DockerDatabaseCandidate) -> Connection {
        switch candidate.databaseType {
        case .postgres, .mysql, .redis:
            return Connection(
                databaseType: candidate.databaseType,
                name: candidate.connectionName,
                color: .blue,
                environment: .local,
                hostname: candidate.host,
                port: candidate.port,
                username: candidate.username ?? "",
                database: candidate.databaseName,
                sslMode: "disable"
            )
        case .mongodb:
            if let username = candidate.username, !username.isEmpty {
                return Connection(
                    databaseType: candidate.databaseType,
                    name: candidate.connectionName,
                    color: .blue,
                    environment: .local,
                    hostname: candidate.host,
                    port: candidate.port,
                    username: username,
                    database: nil,
                    sslMode: nil
                )
            }
            return Connection(
                databaseType: candidate.databaseType,
                url: candidate.connectionURI,
                name: candidate.connectionName,
                color: .blue,
                environment: .local
            )
        case .convex, .supabase, .sqlite:
            return Connection(
                databaseType: candidate.databaseType,
                url: candidate.connectionURI,
                name: candidate.connectionName,
                color: .blue,
                environment: .local
            )
        }
    }

    private func createAndOpenNotebook() {
        if let recent = notebooks.first, recent.title == "Untitled Notebook", recent.descriptionText.isEmpty {
            let id = recent.id
            let blockDescriptor = FetchDescriptor<NotebookBlock>(
                predicate: #Predicate { $0.notebookId == id }
            )
            let blockCount = (try? modelContext.fetchCount(blockDescriptor)) ?? 0
            if blockCount == 0 {
                handleNotebookOpen(recent)
                return
            }
        }
        if ConnectionService.shared.presentPaywallIfAtOpenLimit() { return }
        let notebook = Notebook()
        modelContext.insert(notebook)
        handleNotebookOpen(notebook)
        AnalyticsService.shared.trackNotebookCreated(source: "home")
    }

    private func handleNotebookOpen(_ notebook: Notebook) {
        let alreadyOpen = SidebarItemRegistry.shared.items.contains { item in
            if case .notebook(let id, _) = item { return id == notebook.id }
            return false
        }
        if !alreadyOpen, ConnectionService.shared.presentPaywallIfAtOpenLimit() { return }
        notebook.updatedAt = Date()
        SidebarItemRegistry.shared.addNotebook(id: notebook.id, title: notebook.title)
        WindowController.newTab(tabType: .notebook(notebook.id))
    }

    private func handleConnectionOpen(_ connection: Connection) {
        let isFirstConnection = connections.count == 1 && ConnectionService.shared.connectionInstances.isEmpty

        if ConnectionService.shared.getExistingInstance(for: connection) != nil {
            pendingConnection = connection
            showConnectionAlert = true
        } else {
            if ConnectionService.shared.presentPaywallIfAtOpenLimit() { return }
            openNewConnectionTab(connection, isFirstConnection: isFirstConnection)
        }
    }

    private func openNewConnectionTab(_ connection: Connection, isFirstConnection: Bool) {
        connection.lastOpenedAt = Date()
        guard let viewModel else { return }
        let instanceId = viewModel.createNewConnectionInstance(for: connection)

        guard let connectionInstance = ConnectionService.shared.getInstance(instanceId) else { return }
        WindowController.newTab(
            tabType: .connection(instanceId),
            connectionInstance: connectionInstance
        )
        Task { @MainActor in
            AnalyticsService.shared.trackConnectionOpened(
                databaseType: connection.databaseType,
                isFirstConnection: isFirstConnection
            )
        }
    }

    private func openSavedConnection(_ connection: Connection, isEditingExistingConnection: Bool) {
        let totalConnections = (try? modelContext.fetchCount(FetchDescriptor<Connection>())) ?? 0
        openNewConnectionTab(
            connection,
            isFirstConnection: !isEditingExistingConnection && totalConnections == 1
        )
    }

}

struct DatabaseTypeIcon: View {
    let databaseType: DatabaseType

    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(databaseType.backgroundColor)
            .frame(width: 28, height: 28)
            .overlay(
                Image(databaseType.homeIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 18, height: 18)
            )
    }
}

private struct FreePlanBadge: View {
    var body: some View {
        Button {
            Paywall.present()
        } label: {
            HStack(spacing: 8) {
                Text("Free")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .overlay(
                        Capsule()
                            .strokeBorder(Color(.separatorColor), lineWidth: 1)
                    )

                Text("Upgrade")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.primaryButton)
            }
        }
        .buttonStyle(.plain)
        .customHelp("You're on the Free plan. Upgrade to Pluk Pro for unlimited connections and more.")
    }
}
