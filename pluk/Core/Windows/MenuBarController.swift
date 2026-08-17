import AppKit
import SwiftData

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private enum DefaultsKey {
        static let showInMenuBar = "showInMenuBar"
    }

    private let modelContext: ModelContext
    private let statusMenu = NSMenu()
    private var statusItem: NSStatusItem?

    init(modelContainer: ModelContainer) {
        self.modelContext = ModelContext(modelContainer)
        super.init()
        configureMenu()
        observePreferenceChanges()
        applyMenuBarVisibility()
    }

    deinit {
        NotificationCenter.default.removeObserver(
            self,
            name: UserDefaults.didChangeNotification,
            object: nil
        )
    }

    private func makeStatusImage() -> NSImage? {
        if let assetImage = NSImage(named: "menu-bar-extra") {
            return assetImage
        }

        if let assetImage = NSImage(named: "sparkle") {
            return assetImage
        }

        return NSImage(
            systemSymbolName: "sparkles",
            accessibilityDescription: "Pluk"
        )?.withSymbolConfiguration(.init(pointSize: 15, weight: .semibold))
    }

    private var showInMenuBar: Bool {
        UserDefaults.standard.object(forKey: DefaultsKey.showInMenuBar) as? Bool ?? true
    }

    private func observePreferenceChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(userDefaultsDidChange),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
    }

    @objc nonisolated
    private func userDefaultsDidChange(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.applyMenuBarVisibility()
        }
    }

    private func applyMenuBarVisibility() {
        if showInMenuBar {
            ensureStatusItem()
        } else {
            removeStatusItem()
        }
    }

    private func ensureStatusItem() {
        guard statusItem == nil else { return }

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.statusItem = statusItem
        configureStatusItem(statusItem)
    }

    private func removeStatusItem() {
        guard let statusItem else { return }

        statusItem.menu = nil
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
    }

    private func configureStatusItem(_ statusItem: NSStatusItem) {
        guard let button = statusItem.button else { return }

        let image = makeStatusImage()
        image?.isTemplate = true
        image?.size = NSSize(width: 18, height: 18)

        button.image = image
        button.imagePosition = .imageOnly
        button.toolTip = "Pluk"
        statusItem.menu = statusMenu
    }

    private func configureMenu() {
        statusMenu.delegate = self
        statusMenu.autoenablesItems = false
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func rebuildMenu() {
        statusMenu.removeAllItems()

        let openItems = fetchOpenWorkspaceItems()
        let openConnectionIdentities = Set(
            openItems.compactMap(\.connectionRecencyIdentity)
        )
        let recentConnections = fetchRecentConnections()
            .filter { !openConnectionIdentities.contains(MenuBarWorkspaceItem.connectionIdentity(for: $0.keychainId)) }

        if !openItems.isEmpty {
            statusMenu.addItem(makeSectionHeaderItem("Workspaces"))
            for item in openItems {
                statusMenu.addItem(makeWorkspaceMenuItem(for: item))
            }
            statusMenu.addItem(.separator())
        }

        statusMenu.addItem(makeRecentConnectionsItem(with: recentConnections))
        statusMenu.addItem(.separator())
        statusMenu.addItem(makeActionItem(title: "New Notebook", action: #selector(createNotebook)))
        statusMenu.addItem(.separator())
        statusMenu.addItem(makeActionItem(title: "Open Pluk", action: #selector(openPluk)))
        statusMenu.addItem(makeActionItem(title: "Quit Pluk", action: #selector(quitPluk), keyEquivalent: "q"))
    }

    private func makeSectionHeaderItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        return item
    }

    private func makeActionItem(
        title: String,
        action: Selector,
        keyEquivalent: String = ""
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    private func makeWorkspaceMenuItem(for item: MenuBarWorkspaceItem) -> NSMenuItem {
        let menuItem = NSMenuItem(title: item.title, action: #selector(openRecentItem(_:)), keyEquivalent: "")
        menuItem.target = self
        menuItem.representedObject = item
        menuItem.attributedTitle = item.attributedTitle
        return menuItem
    }

    private func makeRecentConnectionsItem(with connections: [Connection]) -> NSMenuItem {
        let recentConnectionsItem = NSMenuItem(title: "Recent Connections", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Recent Connections")

        if connections.isEmpty {
            let emptyItem = NSMenuItem(title: "No recent connections", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            submenu.addItem(emptyItem)
        } else {
            for connection in connections {
                submenu.addItem(makeWorkspaceMenuItem(for: .recentConnection(connection)))
            }
        }

        recentConnectionsItem.submenu = submenu
        return recentConnectionsItem
    }

    private func fetchRecentConnections() -> [Connection] {
        var connectionDescriptor = FetchDescriptor<Connection>(
            sortBy: [SortDescriptor(\.lastOpenedAt, order: .reverse)]
        )
        connectionDescriptor.fetchLimit = 8

        return (try? modelContext.fetch(connectionDescriptor)) ?? []
    }

    private func fetchOpenWorkspaceItems() -> [MenuBarWorkspaceItem] {
        let activeTabType = WindowController.getCurrentActiveTabType()

        var windowTabs: [(offset: Int, tabType: TabType)] = []
        for (offset, window) in NSApp.windows.enumerated() {
            guard let controller = WindowController.getController(for: window) else { continue }
            windowTabs.append((offset, controller.tabType))
        }

        let notebookIds = windowTabs.compactMap { _, tabType -> UUID? in
            if case .notebook(let id) = tabType { return id }
            return nil
        }
        let notebookMap = fetchNotebooks(ids: notebookIds)

        var items: [(offset: Int, item: MenuBarWorkspaceItem)] = []
        var seen = Set<String>()

        for (offset, tabType) in windowTabs {
            let item: MenuBarWorkspaceItem? = switch tabType {
            case .home:
                nil
            case .connection(let instanceId):
                ConnectionService.shared.getInstance(instanceId).map(MenuBarWorkspaceItem.openConnection)
            case .notebook(let notebookId):
                notebookMap[notebookId].map(MenuBarWorkspaceItem.notebook)
            }

            guard let item, seen.insert(item.openIdentity).inserted else { continue }
            items.append((offset: offset, item: item))
        }

        return items
            .sorted { lhs, rhs in
                let lhsIsActive = lhs.item.matches(tabType: activeTabType)
                let rhsIsActive = rhs.item.matches(tabType: activeTabType)

                if lhsIsActive != rhsIsActive {
                    return lhsIsActive
                }

                return lhs.offset < rhs.offset
            }
            .map(\.item)
    }

    private func fetchNotebooks(ids: [UUID]) -> [UUID: Notebook] {
        guard !ids.isEmpty else { return [:] }
        let descriptor = FetchDescriptor<Notebook>(
            predicate: #Predicate<Notebook> { notebook in
                ids.contains(notebook.id)
            }
        )
        let notebooks = (try? modelContext.fetch(descriptor)) ?? []
        return Dictionary(uniqueKeysWithValues: notebooks.map { ($0.id, $0) })
    }

    @objc
    private func openRecentItem(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? MenuBarWorkspaceItem else { return }

        switch item {
        case .openConnection(let connectionInstance):
            openConnection(connectionInstance)
        case .recentConnection(let connection):
            openConnection(connection)
        case .notebook(let notebook):
            openNotebook(notebook)
        }
    }

    @objc
    private func createNotebook() {
        let notebook = Notebook()
        modelContext.insert(notebook)
        try? modelContext.save()
        SidebarItemRegistry.shared.addNotebook(id: notebook.id, title: notebook.title)
        WindowController.switchToTab(.notebook(notebook.id))
        AnalyticsService.shared.trackNotebookCreated(source: "menu_bar")
    }

    @objc
    private func openPluk() {
        _ = WindowController.showHome()
    }

    @objc
    private func quitPluk() {
        NSApp.terminate(nil)
    }

    private func openConnection(_ connectionInstance: ConnectionInstance) {
        connectionInstance.connection.lastOpenedAt = Date()
        ConnectionService.shared.activeConnectionInstanceId = connectionInstance.id
        WindowController.switchToTab(.connection(connectionInstance.id))
        AnalyticsService.shared.trackConnectionOpened(
            databaseType: connectionInstance.connection.databaseType,
            isFirstConnection: false
        )
    }

    private func openConnection(_ connection: Connection) {
        connection.lastOpenedAt = Date()

        if let existingInstance = ConnectionService.shared.getExistingInstance(for: connection) {
            openConnection(existingInstance)
            return
        }

        let isFirstConnection = fetchConnectionCount() == 1
            && ConnectionService.shared.connectionInstances.isEmpty
        let instanceId = ConnectionService.shared.createNewConnectionInstance(for: connection)

        if let connectionInstance = ConnectionService.shared.getInstance(instanceId) {
            WindowController.newTab(
                tabType: .connection(instanceId),
                connectionInstance: connectionInstance
            )
            AnalyticsService.shared.trackConnectionOpened(
                databaseType: connection.databaseType,
                isFirstConnection: isFirstConnection
            )
        }
    }

    private func openNotebook(_ notebook: Notebook) {
        notebook.updatedAt = Date()
        SidebarItemRegistry.shared.addNotebook(id: notebook.id, title: notebook.title)
        WindowController.switchToTab(.notebook(notebook.id))
    }

    private func fetchConnectionCount() -> Int {
        (try? modelContext.fetchCount(FetchDescriptor<Connection>())) ?? 0
    }
}

@MainActor
private enum MenuBarWorkspaceItem {
    private enum Layout {
        static let maxLineWidth: CGFloat = 200
    }

    case openConnection(ConnectionInstance)
    case recentConnection(Connection)
    case notebook(Notebook)

    var title: String {
        switch self {
        case .openConnection(let connectionInstance):
            connectionInstance.connection.name
        case .recentConnection(let connection):
            connection.name
        case .notebook(let notebook):
            notebook.title
        }
    }

    var subtitle: String {
        switch self {
        case .openConnection(let connectionInstance):
            return connectionSubtitle(for: connectionInstance.connection)
        case .recentConnection(let connection):
            return connectionSubtitle(for: connection)
        case .notebook(let notebook):
            return "Notebook · \(notebook.status.rawValue)"
        }
    }

    var openIdentity: String {
        switch self {
        case .openConnection(let connectionInstance):
            "oc-\(connectionInstance.id.uuidString)"
        case .recentConnection(let connection):
            "rc-\(connection.keychainId)"
        case .notebook(let notebook):
            "n-\(notebook.id.uuidString)"
        }
    }

    static func connectionIdentity(for keychainId: String) -> String {
        "c-\(keychainId)"
    }

    var connectionRecencyIdentity: String? {
        switch self {
        case .openConnection(let connectionInstance):
            Self.connectionIdentity(for: connectionInstance.connection.keychainId)
        case .recentConnection(let connection):
            Self.connectionIdentity(for: connection.keychainId)
        case .notebook:
            nil
        }
    }

    func matches(tabType: TabType?) -> Bool {
        guard let tabType else { return false }

        switch (self, tabType) {
        case (.openConnection(let connectionInstance), .connection(let instanceId)):
            return connectionInstance.id == instanceId
        case (.recentConnection, _):
            return false
        case (.notebook(let notebook), .notebook(let notebookId)):
            return notebook.id == notebookId
        default:
            return false
        }
    }

    private func connectionSubtitle(for connection: Connection) -> String {
        if connection.databaseType == .convex,
           let hostname = connection.hostname, !hostname.isEmpty {
            return "ID: \(hostname)"
        }

        if let displayUrl = connection.displayUrl, !displayUrl.isEmpty {
            return displayUrl
        }

        return connection.environment?.rawValue ?? connection.databaseType.displayName
    }

    var attributedTitle: NSAttributedString {
        let titleFont = NSFont.menuFont(ofSize: 0)
        let subtitleFont = NSFont.systemFont(ofSize: 11)
        let subtitleAttributes: [NSAttributedString.Key: Any] = [
            .font: subtitleFont,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]

        let text = NSMutableAttributedString(string:
            title.truncatedToFit(
                maxWidth: Layout.maxLineWidth,
                font: titleFont
            )
        )
        text.append(
            NSAttributedString(
                string: "\n\(subtitle.truncatedToFit(maxWidth: Layout.maxLineWidth, font: subtitleFont))",
                attributes: subtitleAttributes
            )
        )
        return text
    }
}

private extension String {
    func truncatedToFit(maxWidth: CGFloat, font: NSFont) -> String {
        guard width(using: font) > maxWidth, count > 1 else { return self }

        let ellipsis = "\u{2026}"
        var leadingCount = count / 2
        var trailingCount = count - leadingCount

        while leadingCount > 0 && trailingCount > 0 {
            let candidate = String(prefix(leadingCount)) + ellipsis + String(suffix(trailingCount))
            if candidate.width(using: font) <= maxWidth {
                return candidate
            }

            if leadingCount >= trailingCount {
                leadingCount -= 1
            } else {
                trailingCount -= 1
            }
        }

        return ellipsis
    }

    func width(using font: NSFont) -> CGFloat {
        (self as NSString).size(withAttributes: [.font: font]).width
    }
}
