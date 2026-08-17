//
//  DatabaseHeader.swift
//  Collection
//
//  Created by Fauzaan on 3/23/25.
//

import AppKit
import SwiftUI
import MongoKitten

// MARK: - Database List
struct DatabaseHeader: View {
    @Environment(ConnectionInstance.self) private var instance
    var viewModel: SidebarViewModel
    var isSidebarHovered: Bool
    var isLoadingCollections: Bool
    let collectionLoader: SidebarCollectionLoadCoordinator
    @State private var isSchemaHovering = false
    @State private var availableSchemas: [String] = []
    @State private var selectedSchema: String = ""
    @State private var selectedDatabase: String = ""
    @State private var showCreateSchemaPopover = false
    @State private var showCreateDatabaseSheet = false
    @State private var refreshError: Error?
    @State private var shortcutMenuAnchor: NSView?
    @State private var shortcutMenuActionHandler: DatabaseShortcutMenuActionHandler?

    private var supportsCreateDatabase: Bool {
        guard let databaseType = instance.databaseType else { return false }
        switch databaseType {
        case .postgres, .mysql, .mongodb, .supabase:
            return true
        case .sqlite, .convex, .redis:
            return false
        }
    }

    var body: some View {
        VStack {
            HStack {
                HStack(spacing: 0) {
                    if instance.databaseType == .redis {
                        RedisDatabaseHeaderView(
                            databaseIndex: instance.connectedDatabase?.name
                                ?? instance.connection.defaultDatabase
                                ?? "0"
                        )
                    } else if instance.databaseType == .convex {
                        ConvexHeaderView(
                            availableSchemas: availableSchemas,
                            selectedSchema: $selectedSchema,
                            onSchemaChange: handleSchemaSelection
                        )
                    } else {
                        TraditionalDatabaseHeaderView(
                            instance: instance,
                            availableSchemas: availableSchemas,
                            selectedDatabase: $selectedDatabase,
                            selectedSchema: $selectedSchema,
                            isSchemaHovering: $isSchemaHovering,
                            showCreateDatabasePopover: $showCreateDatabaseSheet,
                            showCreateSchemaPopover: $showCreateSchemaPopover,
                            onSchemaChange: handleSchemaSelection,
                            onDatabaseChange: handleDatabaseSelection,
                            onSchemaCreated: handleSchemaCreated,
                            truncatedText: truncatedText
                        )
                    }
                }
                
                Spacer()
                
                HStack(spacing: 2) {
                    let shouldShowRefreshButton = isSidebarHovered || isLoadingCollections

                    Button {
                        if instance.databaseType == .redis {
                            NotificationCenter.default.post(name: .redisKeysRefreshRequested, object: instance)
                        } else if isLoadingCollections {
                            collectionLoader.cancel()
                        } else {
                            refreshSidebarItems()
                        }
                    } label: {
                        SidebarRefreshIcon(isLoading: isLoadingCollections)
                            .contentShape(.rect)
                    }
                    .buttonStyle(SidebarHeaderIconButtonStyle(isActive: isLoadingCollections))
                    .customHelp(isLoadingCollections ? "Stop Refresh" : (instance.databaseType == .redis ? "Refresh Keys" : "Refresh Tables"))
                    .disabled(!isLoadingCollections && instance.connectionStatus != .connected)
                    .opacity(shouldShowRefreshButton ? 1 : 0)
                    .allowsHitTesting(shouldShowRefreshButton)
                    .animation(.easeOut(duration: 0.12), value: shouldShowRefreshButton)

                    if instance.connection.databaseType.supportsCanvas {
                        Button {
                            instance.createCanvasTab()
                        } label: {
                            Image(systemName: "rectangle.connected.to.line.below")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .frame(width: 24, height: 20)
                                .contentShape(.rect)
                        }
                        .buttonStyle(SidebarHeaderIconButtonStyle())
                        .customHelp("Schema Visualizer")
                    } else if instance.connection.databaseType.supportsCommandWorkspace {
                        Button {
                            instance.createRedisCommandTab()
                        } label: {
                            Image(systemName: "terminal")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .frame(width: 24, height: 20)
                                .contentShape(.rect)
                        }
                        .buttonStyle(SidebarHeaderIconButtonStyle())
                        .customHelp("Open Command Editor")
                    }
                }
            }
        }
        .background(DatabaseShortcutAnchor { anchor in
            if shortcutMenuAnchor !== anchor {
                shortcutMenuAnchor = anchor
            }
        })
        .onAppear {
            selectedDatabase = instance.connectedDatabase?.name ?? ""
            if instance.databaseType != .redis {
                loadAvailableSchemas()
            }
        }
        .onChange(of: instance.readiness) { _, _ in
            selectedDatabase = instance.connectedDatabase?.name ?? ""
            if instance.databaseType != .redis {
                loadAvailableSchemas()
            }
        }
        .onChange(of: instance.databaseService.currentSchema) { oldSchema, newSchema in
            // The first `nil → default-schema` transition fires right after
            // `reloadAvailableSchemas` auto-picks the driver default. The
            // initial `loadCollectionsForCurrentDatabase(schema: nil)` already
            // fetched that schema's tables (the driver normalizes `nil`
            // internally), so reloading here would just re-fetch the same data
            // — wasting an API round-trip and flashing the empty state.
            // User-initiated schema switches always go default → other.
            guard instance.databaseType != .redis else { return }
            guard oldSchema != nil else { return }
            collectionLoader.start {
                await loadCollectionsForSchemaChange(newSchema)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .switchDatabaseShortcut)) { notification in
            guard let sourceWindow = notification.object as? NSWindow,
                  let shortcutMenuAnchor,
                  sourceWindow === shortcutMenuAnchor.window else { return }
            showShortcutDatabaseMenu(anchor: shortcutMenuAnchor)
        }
        .alert(
            "Refresh Error",
            isPresented: Binding(
                get: { refreshError != nil },
                set: { newValue in
                    if !newValue {
                        refreshError = nil
                    }
                }
            ),
            presenting: refreshError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { error in
            Text(error.localizedDescription)
        }
    }
    
    private func loadAvailableSchemas() {
        guard instance.isReady else {
            availableSchemas = []
            selectedSchema = ""
            return
        }

        Task {
            do {
                try await reloadAvailableSchemas()
            } catch {
                debugLog("Failed to load schemas: \(error)")
            }
        }
    }

    @MainActor
    private func reloadAvailableSchemas() async throws {
        let schemas = try await fetchSchemas()
        availableSchemas = schemas
        if selectedSchema.isEmpty || !schemas.contains(selectedSchema) {
            if instance.databaseType == .convex {
                selectedSchema = schemas.contains("app") ? "app" : (schemas.first ?? "")
            } else {
                selectedSchema = schemas.contains("public") ? "public" : (schemas.first ?? "")
            }
        }
        if !selectedSchema.isEmpty {
            instance.databaseService.setCurrentSchema(selectedSchema)
        }
    }

    private func refreshSidebarItems() {
        collectionLoader.start {
            await performSidebarRefresh()
        }
    }

    @MainActor
    private func performSidebarRefresh() async {
        guard instance.isReady else { return }

        refreshError = nil

        do {
            await instance.loadDatabases()
            try Task.checkCancellation()
            try await reloadAvailableSchemas()
            try Task.checkCancellation()
            try await instance.loadCollectionsForCurrentDatabase(
                schema: instance.databaseService.currentSchema
            )
            try Task.checkCancellation()
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            refreshError = error
            debugLog("Failed to refresh sidebar items: \(error)")
        }
    }

    @MainActor
    private func loadCollectionsForSchemaChange(_ schema: String?) async {
        guard instance.isReady else { return }

        refreshError = nil

        // Mark loading BEFORE clearing the cached list, otherwise the
        // sidebar observes an empty `collections[dbName]` while
        // `isLoadingCollections` is still false and flashes "No tables".
        // `loadCollectionsForCurrentDatabase` itself flips this back to
        // false via `defer` on every exit path.
        instance.isLoadingCollections = true
        if let databaseName = instance.connectedDatabase?.name {
            instance.collections[databaseName] = []
        }

        do {
            try await instance.loadCollectionsForCurrentDatabase(schema: schema)
            try Task.checkCancellation()
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            refreshError = error
            debugLog("Failed to load collections for schema change: \(error)")
        }
    }

    private func fetchSchemas() async throws -> [String] {
        guard let databaseType = instance.databaseType else {
            return []
        }

        switch databaseType {
        case .postgres, .supabase, .convex, .mysql:
            let schemas = try await instance.databaseService.getInformationSchema()
            return schemas.map { $0.name }
        default:
            return []
        }
    }
    
    private func truncatedText(_ text: String, maxWidth: CGFloat) -> some View {
        let approximateCharWidth: CGFloat = 7.0 // Approximate character width for system font
        let maxChars = Int(maxWidth / approximateCharWidth)
        let truncatedString = text.count > maxChars ? String(text.prefix(maxChars - 3)) + "..." : text
        
        return Text("\(truncatedString)    ").tag(text)
    }
    
    private func handleSchemaSelection(_ schema: String) {
        instance.databaseService.setCurrentSchema(schema)
    }

    private func handleDatabaseSelection(_ databaseName: String) {
        // Don't do anything if selecting the already-connected database
        guard databaseName != instance.connectedDatabase?.name else { return }

        // First-time selection (no database yet) — switch the current
        // instance in-place. Once a database is already bound to this tab,
        // switching opens the target database in its own tab instead.
        if instance.connectedDatabase == nil {
            Task { @MainActor in
                guard let database = instance.databases.first(where: { $0.name == databaseName }) else { return }
                do {
                    try await instance.databaseService.switchActiveDatabase(to: database)
                    try await instance.loadCollectionsForCurrentDatabase(
                        schema: instance.databaseService.currentSchema
                    )
                } catch {
                    debugLog("Failed to switch to \(databaseName): \(error)")
                }
            }
            return
        }

        Task {
            if let instanceId = await ConnectionService.shared.openEnvironmentInNewTab(
                from: instance,
                databaseName: databaseName
            ) {
                await MainActor.run {
                    WindowController.switchToTab(.connection(instanceId))
                }
            }
        }
    }

    private func handleSchemaCreated(_ schemaName: String) {
        loadAvailableSchemas()
        selectedSchema = schemaName
        instance.databaseService.setCurrentSchema(schemaName)
    }

    private func showShortcutDatabaseMenu(anchor: NSView) {
        let menu = NSMenu(title: "Switch Database")
        menu.autoenablesItems = false

        let actionHandler = DatabaseShortcutMenuActionHandler(
            onSelect: handleDatabaseSelection,
            onCreateDatabase: {
                showCreateDatabaseSheet = true
            }
        )
        shortcutMenuActionHandler = actionHandler

        if instance.databases.isEmpty {
            let emptyItem = NSMenuItem(title: "No databases available", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            for database in instance.databases.sorted(by: {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }) {
                let item = NSMenuItem(
                    title: database.name,
                    action: #selector(DatabaseShortcutMenuActionHandler.selectDatabase(_:)),
                    keyEquivalent: ""
                )
                item.target = actionHandler
                item.representedObject = database.name
                item.state = database.name == instance.connectedDatabase?.name ? .on : .off
                menu.addItem(item)
            }
        }

        if supportsCreateDatabase {
            menu.addItem(.separator())
            let createItem = NSMenuItem(
                title: "New Database...",
                action: #selector(DatabaseShortcutMenuActionHandler.createDatabase(_:)),
                keyEquivalent: ""
            )
            createItem.target = actionHandler
            menu.addItem(createItem)
        }

        menu.popUp(positioning: nil, at: .zero, in: anchor)
    }
}

private struct RedisDatabaseHeaderView: View {
    let databaseIndex: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "externaldrive.connected.to.line.below")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("DB \(databaseIndex)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

@MainActor
private final class DatabaseShortcutMenuActionHandler: NSObject {
    private let onSelect: (String) -> Void
    private let onCreateDatabase: () -> Void

    init(onSelect: @escaping (String) -> Void, onCreateDatabase: @escaping () -> Void) {
        self.onSelect = onSelect
        self.onCreateDatabase = onCreateDatabase
    }

    @objc func selectDatabase(_ sender: NSMenuItem) {
        guard let databaseName = sender.representedObject as? String else { return }
        onSelect(databaseName)
    }

    @objc func createDatabase(_ sender: NSMenuItem) {
        onCreateDatabase()
    }
}

private struct DatabaseShortcutAnchor: NSViewRepresentable {
    let onResolve: (NSView?) -> Void

    func makeNSView(context: Context) -> ReportingView {
        let view = ReportingView()
        view.onResolve = onResolve
        return view
    }

    func updateNSView(_ nsView: ReportingView, context: Context) {
        nsView.onResolve = onResolve
    }

    final class ReportingView: NSView {
        var onResolve: ((NSView?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onResolve?(self)
        }
    }
}

private struct SidebarRefreshIcon: View {
    let isLoading: Bool

    var body: some View {
        Image(systemName: isLoading ? "xmark" : "arrow.clockwise")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(width: 24, height: 20)
    }
}

struct SidebarHeaderIconButtonStyle: ButtonStyle {
    @State private var isHovering = false
    var isActive: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.separatorColor).opacity((isHovering || isActive) ? 0.5 : 0))
            )
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.05)) {
                    isHovering = hovering
                }
            }
    }
}

// MARK: - DatabaseSchemaItem
struct DatabaseSchemaItem: View {
    let text: String
    let showChevronRight: Bool
    let isHovering: Bool
    let onTap: () -> Void
    @Environment(\.colorScheme) var colorScheme
    
    init(text: String, showChevronRight: Bool, isHovering: Bool = false, onTap: @escaping () -> Void) {
        self.text = text
        self.showChevronRight = showChevronRight
        self.isHovering = isHovering
        self.onTap = onTap
    }
    
    var body: some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            
            if showChevronRight {
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if isHovering {
                Image(systemName: "chevron.compact.up.chevron.compact.down")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .opacity(0.7)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(
                    isHovering && !showChevronRight
                    ? (colorScheme == .dark ? Color.black : Color.white).opacity(0.2)
                    : Color.clear
                )
        )
    }
}

// MARK: - SearchInput
struct SearchInput: View {
    var viewModel: SidebarViewModel
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search", text: Binding(
                get: { viewModel.searchText },
                set: { viewModel.searchText = $0 }
            ))
            .focused($isSearchFocused)
            .textFieldStyle(.plain)
            .onExitCommand {
                if viewModel.searchText.isEmpty {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.isSearchVisible = false
                    }
                } else {
                    viewModel.searchText = ""
                }
            }

            if !viewModel.searchText.isEmpty {
                Button(action: { viewModel.searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
                .transition(.opacity)
            }

        }
        .padding(.horizontal, ToolbarIslandMetrics.controlHorizontalPadding)
        .padding(.vertical, ToolbarIslandMetrics.controlVerticalPadding)
        .toolbarIsland()
        .onTapGesture {
            isSearchFocused = true
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.searchText)
        .onAppear {
            Task {
                try? await Task.sleep(for: .milliseconds(100))
                isSearchFocused = true
            }
        }
        .onChange(of: viewModel.isSearchVisible) { _, isVisible in
            if isVisible {
                Task {
                    try? await Task.sleep(for: .milliseconds(100))
                    isSearchFocused = true
                }
            }
        }
    }
}

// MARK: - ConvexHeaderView
struct ConvexHeaderView: View {
    let availableSchemas: [String]
    @Binding var selectedSchema: String
    let onSchemaChange: (String) -> Void

    var body: some View {
        CustomComponentPicker(
            items: availableSchemas,
            selectedItem: $selectedSchema,
            onSelectionChange: onSchemaChange
        )
    }
}

// MARK: - Custom AppKit Component Picker
struct CustomComponentPicker: NSViewRepresentable {
    let items: [String]
    @Binding var selectedItem: String
    let onSelectionChange: (String) -> Void

    func makeNSView(context: Context) -> NSView {
        let popUpButton = NSPopUpButton()
        popUpButton.translatesAutoresizingMaskIntoConstraints = false
        popUpButton.pullsDown = false
        popUpButton.bezelStyle = .accessoryBar
        popUpButton.isBordered = true
        popUpButton.showsBorderOnlyWhileMouseInside = true

        // Set target and action
        popUpButton.target = context.coordinator
        popUpButton.action = #selector(Coordinator.selectionChanged(_:))

        Task { @MainActor in
            self.replaceDropdownArrow(in: popUpButton)
        }

        // Store reference for coordinator
        context.coordinator.popUpButton = popUpButton

        return popUpButton
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let popUpButton = context.coordinator.popUpButton else { return }

        // Update items
        popUpButton.removeAllItems()
        popUpButton.addItems(withTitles: items)
        
        // Resize button based on selected text
        resizeButtonForSelectedText(popUpButton, selectedText: selectedItem)

        // Update selection
        if let index = items.firstIndex(of: selectedItem) {
            popUpButton.selectItem(at: index)
        } else {
            // Add default value and item
            popUpButton.addItems(withTitles: ["app"])
            popUpButton.selectItem(at: 0)
        }

        // Store references in coordinator
        context.coordinator.onSelectionChange = onSelectionChange
        context.coordinator.selectedItemBinding = $selectedItem
    }

    private func resizeButtonForSelectedText(_ button: NSPopUpButton, selectedText: String) {
        // Measure the text directly
        let font = button.font ?? NSFont.systemFont(ofSize: 13)
        let textSize = (selectedText as NSString).size(withAttributes: [.font: font])

        // Add padding for button chrome and dropdown arrow
        let padding: CGFloat = 36 // Space for borders and dropdown arrow
        let minWidth: CGFloat = 60
        let calculatedWidth = max(minWidth, textSize.width + padding)

        // Update width constraint
        if let existingConstraint = button.constraints.first(where: { $0.firstAttribute == .width }) {
            existingConstraint.constant = calculatedWidth
        } else {
            button.widthAnchor.constraint(equalToConstant: calculatedWidth).isActive = true
        }
    }

    private func replaceDropdownArrow(in popUpButton: NSPopUpButton) {
        // Recursively search for NSImageView containing the dropdown arrow
        findAndReplaceArrowImage(in: popUpButton)
    }

    private func findAndReplaceArrowImage(in view: NSView) {
        for subview in view.subviews {
            let className = NSStringFromClass(type(of: subview))

            if className == "NSPopUpIndicatorView" {
                // Hide the original indicator
                subview.isHidden = true

                // Add our custom arrow
                addCustomArrow(to: view)
                return
            }

            // Continue searching in subviews
            findAndReplaceArrowImage(in: subview)
        }
    }

    private func addCustomArrow(to popUpButton: NSView) {
        // Create custom arrow image at 10pt
        guard let customArrow = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil) else { return }

        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
        guard let scaledArrow = customArrow.withSymbolConfiguration(config) else { return }
        scaledArrow.isTemplate = true

        // Create image view for our custom arrow
        let customImageView = NSImageView(image: scaledArrow)
        customImageView.translatesAutoresizingMaskIntoConstraints = false
        customImageView.wantsLayer = true

        // Add to the popup button
        popUpButton.addSubview(customImageView)

        // Position it on the right side like the original indicator
        NSLayoutConstraint.activate([
            customImageView.trailingAnchor.constraint(equalTo: popUpButton.trailingAnchor, constant: -2),
            customImageView.centerYAnchor.constraint(equalTo: popUpButton.centerYAnchor, constant: 1),
            customImageView.widthAnchor.constraint(equalToConstant: 12),
            customImageView.heightAnchor.constraint(equalToConstant: 12)
        ])
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    class Coordinator: NSObject {
        var onSelectionChange: ((String) -> Void)?
        var selectedItemBinding: Binding<String>?
        weak var popUpButton: NSPopUpButton?

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            guard let selectedTitle = sender.selectedItem?.title else { return }

            // Update the SwiftUI binding
            selectedItemBinding?.wrappedValue = selectedTitle

            // Also call the callback
            onSelectionChange?(selectedTitle)
        }
    }
}

// MARK: - TraditionalDatabaseHeaderView
struct TraditionalDatabaseHeaderView<TruncatedTextView: View>: View {
    let instance: ConnectionInstance
    let availableSchemas: [String]
    @Binding var selectedDatabase: String
    @Binding var selectedSchema: String
    @Binding var isSchemaHovering: Bool
    @Binding var showCreateDatabasePopover: Bool
    @Binding var showCreateSchemaPopover: Bool
    let onSchemaChange: (String) -> Void
    let onDatabaseChange: (String) -> Void
    let onSchemaCreated: (String) -> Void
    let truncatedText: (String, CGFloat) -> TruncatedTextView

    private var supportsCreateDatabase: Bool {
        guard let databaseType = instance.databaseType else { return false }
        switch databaseType {
        case .postgres, .mysql, .mongodb, .supabase:
            return true
        case .sqlite, .convex, .redis:
            return false
        }
    }

    @ViewBuilder
    private var selectDatabaseDropdown: some View {
        MinimalDropdown(selectedValue: "Select database", chevron: "chevron.down") {
            ForEach(instance.databases, id: \.name) { db in
                Button(db.name) { onDatabaseChange(db.name) }
            }

            if supportsCreateDatabase {
                Divider()

                Button("New Database...") {
                    showCreateDatabasePopover = true
                }
            }
        }
        .popover(isPresented: $showCreateDatabasePopover) {
            CreateDatabaseForm()
                .environment(instance)
        }
    }

    var body: some View {
        if !availableSchemas.isEmpty {
            if let database = instance.connectedDatabase?.name {
                MinimalDropdown(selectedValue: database, chevron: "chevron.right") {
                    Picker("", selection: Binding(
                        get: { database },
                        set: { newValue in
                            if newValue != database {
                                onDatabaseChange(newValue)
                            }
                        }
                    )) {
                        ForEach(instance.databases, id: \.name) { db in
                            Text(db.name).tag(db.name)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()

                    if supportsCreateDatabase {
                        Divider()

                        Button("New Database...") {
                            showCreateDatabasePopover = true
                        }
                    }
                }
                .popover(isPresented: $showCreateDatabasePopover) {
                    CreateDatabaseForm()
                        .environment(instance)
                }
            } else {
                selectDatabaseDropdown
            }

            MinimalDropdown(selectedValue: selectedSchema, chevron: nil) {
                Picker("", selection: Binding(
                    get: { selectedSchema },
                    set: { newValue in
                        selectedSchema = newValue
                        onSchemaChange(newValue)
                    }
                )) {
                    ForEach(availableSchemas, id: \.self) { schema in
                        Text(schema).tag(schema)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()

                Divider()

                Button("New Schema...") {
                    showCreateSchemaPopover = true
                }
            }
            .popover(isPresented: $showCreateSchemaPopover) {
                CreateSchemaForm(onCreated: onSchemaCreated)
                    .environment(instance)
            }
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.05)) {
                    isSchemaHovering = hovering
                }
            }
        } else {
            if let database = instance.connectedDatabase?.name {
                MinimalDropdown(selectedValue: database) {
                    Picker("", selection: Binding(
                        get: { database },
                        set: { newValue in
                            if newValue != database {
                                onDatabaseChange(newValue)
                            }
                        }
                    )) {
                        ForEach(instance.databases, id: \.name) { db in
                            Text(db.name).tag(db.name)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()

                    if supportsCreateDatabase {
                        Divider()

                        Button("New Database...") {
                            showCreateDatabasePopover = true
                        }
                    }
                }
                .popover(isPresented: $showCreateDatabasePopover) {
                    CreateDatabaseForm()
                        .environment(instance)
                }
            } else {
                selectDatabaseDropdown
            }
        }
    }
}

// MARK: - MinimalDropdown
struct MinimalDropdown<MenuContent: View>: View {
    let selectedValue: String
    var chevron: String? = "chevron.down"
    @ViewBuilder let menuContent: () -> MenuContent
    @State private var isHovered = false

    var body: some View {
        Menu {
            menuContent()
        } label: {
            HStack(spacing: 3) {
                Text(selectedValue)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let chevron {
                    Image(systemName: chevron)
                        .padding(.top, 1)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.primary)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color(.separatorColor).opacity(0.5) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
