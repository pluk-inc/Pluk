import AppKit

final class EmptyStateViewController: NSViewController, NSTextFieldDelegate {

    private let instance: ConnectionInstance

    // Search bar
    private let searchField = NSTextField()
    private let searchIcon = NSImageView()
    private let clearButton = NSButton()
    private let searchContainer = NSView()

    // Recent files (plain, no bg/border)
    private let recentHeaderLabel = NSTextField(labelWithString: "Recent Files")
    private let recentHeaderStack = NSStackView()
    private let recentStackView = NSStackView()

    // Search dropdown (with bg + border container)
    private let dropdownContainer = NSView()
    private let resultsHeaderLabel = NSTextField(labelWithString: "Top matches")
    private let dropdownScrollView = NSScrollView()
    private let dropdownStackView = NSStackView()

    private var activeIndex = 0
    nonisolated(unsafe) private var eventMonitor: Any?
    nonisolated(unsafe) private var connectedDatabaseObserver: NSObjectProtocol?
    private var dropdownHeightConstraint: NSLayoutConstraint?
    private var appearanceObservation: NSKeyValueObservation?

    init(instance: ConnectionInstance) {
        self.instance = instance
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        self.view = root

        setupSearchBar()
        setupRecentArea()
        setupDropdownArea()
        setupLayout()
        setupEventMonitor()
        setupConnectedDatabaseObservation()
    }

    // MARK: - Search Bar

    private func setupSearchBar() {
        searchContainer.wantsLayer = true
        searchContainer.layer?.cornerRadius = 14
        searchContainer.layer?.borderWidth = 1
        searchContainer.translatesAutoresizingMaskIntoConstraints = false
        updateContainerAppearance(searchContainer)

        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        searchIcon.contentTintColor = .secondaryLabelColor
        searchIcon.translatesAutoresizingMaskIntoConstraints = false
        searchIcon.setContentHuggingPriority(.required, for: .horizontal)

        searchField.placeholderString = "Open Quickly"
        searchField.font = .systemFont(ofSize: 17)
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        clearButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Clear")
        clearButton.contentTintColor = .secondaryLabelColor
        clearButton.isBordered = false
        clearButton.target = self
        clearButton.action = #selector(clearSearch)
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        clearButton.isHidden = true

        searchContainer.addSubview(searchIcon)
        searchContainer.addSubview(searchField)
        searchContainer.addSubview(clearButton)

        NSLayoutConstraint.activate([
            searchIcon.leadingAnchor.constraint(equalTo: searchContainer.leadingAnchor, constant: 16),
            searchIcon.centerYAnchor.constraint(equalTo: searchContainer.centerYAnchor),
            searchIcon.widthAnchor.constraint(equalToConstant: 16),
            searchIcon.heightAnchor.constraint(equalToConstant: 16),

            searchField.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 8),
            searchField.centerYAnchor.constraint(equalTo: searchContainer.centerYAnchor),
            searchField.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -4),

            clearButton.trailingAnchor.constraint(equalTo: searchContainer.trailingAnchor, constant: -12),
            clearButton.centerYAnchor.constraint(equalTo: searchContainer.centerYAnchor),
            clearButton.widthAnchor.constraint(equalToConstant: 20),
            clearButton.heightAnchor.constraint(equalToConstant: 20),

            searchContainer.heightAnchor.constraint(equalToConstant: 48),
        ])
    }

    private func updateContainerAppearance(_ container: NSView) {
        let appearance = container.effectiveAppearance
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        var border: CGColor = NSColor.separatorColor.cgColor
        appearance.performAsCurrentDrawingAppearance {
            border = NSColor.separatorColor.cgColor
        }
        container.layer?.backgroundColor = isDark
            ? NSColor.white.withAlphaComponent(0.06).cgColor
            : NSColor.white.cgColor
        container.layer?.borderColor = border
    }

    // MARK: - Recent Files Area (plain, no container styling)

    private func setupRecentArea() {
        recentHeaderLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        recentHeaderLabel.textColor = .labelColor
        recentHeaderLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        recentHeaderLabel.translatesAutoresizingMaskIntoConstraints = false

        recentHeaderStack.orientation = .horizontal
        recentHeaderStack.distribution = .fill
        recentHeaderStack.addArrangedSubview(recentHeaderLabel)
        recentHeaderStack.translatesAutoresizingMaskIntoConstraints = false
        recentHeaderStack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 10, right: 16)

        recentStackView.orientation = .vertical
        recentStackView.spacing = 4
        recentStackView.translatesAutoresizingMaskIntoConstraints = false
    }

    // MARK: - Search Dropdown Area (with bg + border)

    private func setupDropdownArea() {
        dropdownContainer.wantsLayer = true
        dropdownContainer.layer?.cornerRadius = 14
        dropdownContainer.layer?.borderWidth = 0.5
        dropdownContainer.translatesAutoresizingMaskIntoConstraints = false
        updateContainerAppearance(dropdownContainer)

        resultsHeaderLabel.font = .preferredFont(forTextStyle: .callout)
        resultsHeaderLabel.textColor = .secondaryLabelColor
        resultsHeaderLabel.translatesAutoresizingMaskIntoConstraints = false

        dropdownStackView.orientation = .vertical
        dropdownStackView.spacing = 4
        dropdownStackView.translatesAutoresizingMaskIntoConstraints = false

        dropdownScrollView.contentView.drawsBackground = false
        dropdownScrollView.documentView = dropdownStackView
        dropdownScrollView.drawsBackground = false
        dropdownScrollView.hasVerticalScroller = true
        dropdownScrollView.autohidesScrollers = true
        dropdownScrollView.translatesAutoresizingMaskIntoConstraints = false

        dropdownContainer.addSubview(resultsHeaderLabel)
        dropdownContainer.addSubview(dropdownScrollView)
    }


    // MARK: - Layout

    private func setupLayout() {
        view.addSubview(searchContainer)
        view.addSubview(recentHeaderStack)
        view.addSubview(recentStackView)
        view.addSubview(dropdownContainer)

        NSLayoutConstraint.activate([
            searchContainer.topAnchor.constraint(equalTo: view.topAnchor),
            searchContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            searchContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            // Recent header (plain)
            recentHeaderStack.topAnchor.constraint(equalTo: searchContainer.bottomAnchor, constant: 8),
            recentHeaderStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            recentHeaderStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            // Recent list
            recentStackView.topAnchor.constraint(equalTo: recentHeaderStack.bottomAnchor),
            recentStackView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            recentStackView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            recentStackView.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor),

            // Dropdown container (with bg + border)
            dropdownContainer.topAnchor.constraint(equalTo: searchContainer.bottomAnchor, constant: 12),
            dropdownContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dropdownContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dropdownContainer.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor),

            // Results header inside dropdown
            resultsHeaderLabel.topAnchor.constraint(equalTo: dropdownContainer.topAnchor, constant: 18),
            resultsHeaderLabel.leadingAnchor.constraint(equalTo: dropdownContainer.leadingAnchor, constant: 16),

            // Scroll view inside dropdown
            dropdownScrollView.topAnchor.constraint(equalTo: resultsHeaderLabel.bottomAnchor, constant: 8),
            dropdownScrollView.leadingAnchor.constraint(equalTo: dropdownContainer.leadingAnchor, constant: 8),
            dropdownScrollView.trailingAnchor.constraint(equalTo: dropdownContainer.trailingAnchor, constant: -2),
            dropdownScrollView.bottomAnchor.constraint(equalTo: dropdownContainer.bottomAnchor, constant: -8),

            dropdownStackView.widthAnchor.constraint(equalTo: dropdownScrollView.widthAnchor, constant: -6),

        ])
    }

    // MARK: - Content

    private var currentSearchQuery: String {
        if let editorText = searchField.currentEditor()?.string {
            return editorText
        }
        return searchField.stringValue
    }

    private func filteredCollections(matching searchQuery: String) -> [any CollectionWrapper] {
        guard !searchQuery.isEmpty else { return [] }
        guard let collections = instance.collections[instance.connectedDatabase?.name ?? ""] else {
            return []
        }
        return collections.filter { $0.name.localizedStandardContains(searchQuery) }
    }

    private func normalizedSchemaName(_ schemaName: String?) -> String? {
        guard let schemaName, !schemaName.isEmpty else {
            switch instance.connection.databaseType {
            case .postgres, .supabase:
                return "public"
            case .convex:
                return "app"
            default:
                return nil
            }
        }
        return schemaName
    }

    private var currentRecentSchemaName: String? {
        switch instance.connection.databaseType {
        case .postgres, .supabase:
            return normalizedSchemaName(instance.databaseService.currentSchema)
        case .convex:
            return normalizedSchemaName(instance.databaseService.currentSchema)
        default:
            return nil
        }
    }

    private func recentEntryMatchesCurrentSelection(_ entry: RecentTableEntry) -> Bool {
        guard entry.databaseName == instance.connectedDatabase?.name else { return false }
        guard let currentRecentSchemaName else {
            return true
        }
        return normalizedSchemaName(entry.schemaName) == currentRecentSchemaName
    }

    private func clearRows(in stackView: NSStackView) {
        for row in stackView.arrangedSubviews {
            stackView.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
    }

    private func reloadContent() {
        clearRows(in: dropdownStackView)
        clearRows(in: recentStackView)

        let searchQuery = currentSearchQuery
        if !searchQuery.isEmpty {
            let collections = filteredCollections(matching: searchQuery)
            let hasResults = !collections.isEmpty

            recentHeaderStack.isHidden = true
            recentStackView.isHidden = true
            dropdownContainer.isHidden = !hasResults
            resultsHeaderLabel.isHidden = !hasResults
            dropdownScrollView.isHidden = !hasResults

            if activeIndex >= collections.count {
                activeIndex = 0
            }

            for (index, collection) in collections.enumerated() {
                let row = makeCollectionRow(
                    name: collection.name,
                    type: collection.type,
                    schema: collection.schema,
                    index: index,
                    isActive: index == activeIndex
                ) { [weak self] in
                    self?.openCollection(collection)
                }
                dropdownStackView.addArrangedSubview(row)
            }

            dropdownHeightConstraint?.isActive = false
            dropdownHeightConstraint = nil
            if hasResults {
                let maxHeight = min(CGFloat(collections.count) * 38 + CGFloat(collections.count - 1) * 4, 320)
                let constraint = dropdownScrollView.heightAnchor.constraint(equalToConstant: maxHeight)
                constraint.isActive = true
                dropdownHeightConstraint = constraint
            }

        } else {
            // Hide dropdown, show recent
            dropdownContainer.isHidden = true

            let currentDB = instance.connectedDatabase?.name
            let recentTables: [RecentTableEntry]
            if let currentDB, !currentDB.isEmpty {
                recentTables = Array(
                    (instance.recentTablesService?.fetchRecent(limit: 50, databaseName: currentDB) ?? [])
                        .filter(recentEntryMatchesCurrentSelection)
                        .prefix(6)
                )
            } else {
                recentTables = []
            }
            let hasRecent = !recentTables.isEmpty

            recentHeaderStack.isHidden = !hasRecent
            recentStackView.isHidden = !hasRecent

            for (index, entry) in recentTables.enumerated() {
                let row = makeCollectionRow(
                    name: entry.tableName,
                    type: entry.tableType,
                    schema: entry.schemaName,
                    index: index,
                    isActive: false
                ) { [weak self] in
                    self?.openRecentEntry(entry)
                }
                recentStackView.addArrangedSubview(row)
            }

        }

        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
    }

    // MARK: - Row Builder

    private func makeCollectionRow(
        name: String,
        type: String,
        schema: String?,
        index: Int,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> NSView {
        let row = ClickableRowView(action: action)
        row.wantsLayer = true
        row.layer?.cornerRadius = 10
        row.translatesAutoresizingMaskIntoConstraints = false

        row.isActive = isActive

        let icon = NSImageView()
        let symbolName = type == "view" ? "eye.fill" : "tablecells"
        icon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = .systemFont(ofSize: 13)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.maximumNumberOfLines = 1
        nameLabel.cell?.truncatesLastVisibleLine = true
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        let typeText = type.capitalized
        let typeFont = NSFont.systemFont(ofSize: 11)
        let typeBadgeWidth = max(35, ceil(NSAttributedString(string: typeText, attributes: [.font: typeFont]).size().width) + 16)
        let typeLabel = NSTextField(labelWithString: typeText)
        let cell = VerticallyCenteredTextFieldCell(textCell: typeText)
        cell.font = typeFont
        cell.alignment = .center
        typeLabel.cell = cell
        typeLabel.font = typeFont
        typeLabel.textColor = .secondaryLabelColor
        typeLabel.alignment = .center
        typeLabel.isBezeled = false
        typeLabel.isEditable = false
        typeLabel.drawsBackground = false
        typeLabel.wantsLayer = true
        typeLabel.layer?.borderWidth = 1
        typeLabel.layer?.cornerRadius = 6
        var typeBorder: CGColor = NSColor.separatorColor.cgColor
        (view.effectiveAppearance).performAsCurrentDrawingAppearance {
            typeBorder = NSColor.separatorColor.cgColor
        }
        typeLabel.layer?.borderColor = typeBorder
        typeLabel.translatesAutoresizingMaskIntoConstraints = false
        typeLabel.setContentHuggingPriority(.required, for: .horizontal)

        row.addSubview(icon)
        row.addSubview(nameLabel)
        row.addSubview(typeLabel)

        var constraints = [
            row.heightAnchor.constraint(equalToConstant: 38),

            icon.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 16),

            nameLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            nameLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),

            typeLabel.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12),
            typeLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            typeLabel.widthAnchor.constraint(equalToConstant: typeBadgeWidth),
            typeLabel.heightAnchor.constraint(equalToConstant: 22),
        ]

        if let schema, !schema.isEmpty {
            let schemaLabel = NSTextField(labelWithString: schema)
            schemaLabel.font = .systemFont(ofSize: 11)
            schemaLabel.textColor = .tertiaryLabelColor
            schemaLabel.lineBreakMode = .byTruncatingTail
            schemaLabel.maximumNumberOfLines = 1
            schemaLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            schemaLabel.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(schemaLabel)

            constraints.append(contentsOf: [
                schemaLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 6),
                schemaLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                schemaLabel.trailingAnchor.constraint(lessThanOrEqualTo: typeLabel.leadingAnchor, constant: -8),
            ])
        } else {
            constraints.append(
                nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: typeLabel.leadingAnchor, constant: -8)
            )
        }

        NSLayoutConstraint.activate(constraints)
        return row
    }

    // MARK: - Actions

    @objc private func clearSearch() {
        searchField.stringValue = ""
        activeIndex = 0
        clearButton.isHidden = true
        reloadContent()
    }


    private func openCollection(_ collection: any CollectionWrapper) {
        let isFunction = collection.type == "function" || collection.type == "procedure"
        if isFunction, let pgWrapper = collection as? PostgreSQLCollectionWrapper {
            openFunction(name: pgWrapper.name, oid: pgWrapper.oid, schema: pgWrapper.schema)
        } else {
            instance.createNewTab(name: collection.name, databaseSchema: collection.schema)
        }
        clearSearch()
    }

    private func openRecentEntry(_ entry: RecentTableEntry) {
        guard entry.databaseName == instance.connectedDatabase?.name else { return }

        let isFunction = entry.tableType == "function" || entry.tableType == "procedure"
        if isFunction {
            // Look up the collection to get the oid
            let dbName = instance.connectedDatabase?.name ?? ""
            if let collections = instance.collections[dbName],
               let pgWrapper = collections.first(where: { $0.name == entry.tableName && $0.schema == entry.schemaName }) as? PostgreSQLCollectionWrapper {
                openFunction(name: pgWrapper.name, oid: pgWrapper.oid, schema: pgWrapper.schema)
            }
        } else {
            instance.createNewTab(name: entry.tableName, databaseSchema: entry.schemaName)
        }
    }

    private func openFunction(name: String, oid: String, schema: String?) {
        Task {
            do {
                let definition = try await instance.databaseService.getFunctionDefinition(oid: oid)
                instance.createFunctionEditorTab(name: name, definition: definition, oid: oid, schema: schema)
            } catch {
                debugLog("Failed to open function: \(error)")
            }
        }
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        clearButton.isHidden = currentSearchQuery.isEmpty
        activeIndex = 0
        reloadContent()
        scrollToActiveRow()
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.scrollToActiveRow()
        }
    }

    // MARK: - Event Monitor

    private func setupEventMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.view.window?.isKeyWindow == true else { return event }

            if self.handleSwitchDatabaseShortcut(event) {
                return nil
            }

            switch event.keyCode {
            case 17 where event.modifierFlags.contains(.command):
                self.instance.createEditorTab()
                return nil
            default:
                break
            }

            let searchQuery = self.currentSearchQuery
            guard !searchQuery.isEmpty else { return event }
            let collections = self.filteredCollections(matching: searchQuery)
            guard !collections.isEmpty else { return event }

            switch event.keyCode {
            case 125: // Down arrow
                let newIndex = min(self.activeIndex + 1, collections.count - 1)
                if newIndex != self.activeIndex {
                    self.updateActiveIndex(from: self.activeIndex, to: newIndex)
                }
                return nil
            case 126: // Up arrow
                let newIndex = max(self.activeIndex - 1, 0)
                if newIndex != self.activeIndex {
                    self.updateActiveIndex(from: self.activeIndex, to: newIndex)
                }
                return nil
            case 36: // Enter/Return
                if collections.indices.contains(self.activeIndex) {
                    self.openCollection(collections[self.activeIndex])
                }
                return nil
            default:
                return event
            }
        }
    }

    private func handleSwitchDatabaseShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags == .command,
              event.charactersIgnoringModifiers?.lowercased() == "k",
              let window = view.window
        else {
            return false
        }

        NotificationCenter.default.post(name: .switchDatabaseShortcut, object: window)
        return true
    }

    private func setupConnectedDatabaseObservation() {
        connectedDatabaseObserver = NotificationCenter.default.addObserver(
            forName: .connectedDatabaseChanged,
            object: instance,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reloadContent()
            }
        }
    }

    private func updateActiveIndex(from oldIndex: Int, to newIndex: Int) {
        let views = dropdownStackView.arrangedSubviews
        if let oldRow = views[safe: oldIndex] as? ClickableRowView {
            oldRow.isActive = false
        }
        activeIndex = newIndex
        if let newRow = views[safe: newIndex] as? ClickableRowView {
            newRow.isActive = true
        }
        scrollToActiveRow()
    }

    private func scrollToActiveRow() {
        guard dropdownScrollView.isHidden == false else { return }
        guard activeIndex < dropdownStackView.arrangedSubviews.count else { return }
        view.layoutSubtreeIfNeeded()
        let row = dropdownStackView.arrangedSubviews[activeIndex]
        dropdownScrollView.contentView.scrollToVisible(row.frame)
        dropdownScrollView.reflectScrolledClipView(dropdownScrollView.contentView)
    }

    func tearDown() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        if let connectedDatabaseObserver {
            NotificationCenter.default.removeObserver(connectedDatabaseObserver)
            self.connectedDatabaseObserver = nil
        }
    }

    deinit {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let connectedDatabaseObserver {
            NotificationCenter.default.removeObserver(connectedDatabaseObserver)
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(searchField)
        reloadContent()

        // Service may not be initialized yet (set up async in ConnectionInstance.init)
        if instance.recentTablesService == nil {
            Task { @MainActor in
                await Task.yield()
                self.reloadContent()
            }
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        updateContainerAppearance(searchContainer)
        updateContainerAppearance(dropdownContainer)

        appearanceObservation = view.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateContainerAppearance(self.searchContainer)
                self.updateContainerAppearance(self.dropdownContainer)
                self.reloadContent()
            }
        }
    }
}

// MARK: - Clickable Row

private final class ClickableRowView: NSView {
    private let action: () -> Void
    private var trackingArea: NSTrackingArea?
    private var isHovering = false {
        didSet { if oldValue != isHovering { updateBackground() } }
    }
    var isActive = false {
        didSet { if oldValue != isActive { updateBackground() } }
    }

    init(action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
        refreshHoverState()
    }

    private func refreshHoverState() {
        guard let window else {
            isHovering = false
            return
        }
        let mouseLocation = window.mouseLocationOutsideOfEventStream
        let localPoint = convert(mouseLocation, from: nil)
        isHovering = bounds.contains(localPoint)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    override func updateLayer() {
        super.updateLayer()
        updateBackground()
    }

    private func updateBackground() {
        guard isHovering || isActive else {
            layer?.backgroundColor = nil
            return
        }
        var resolved: CGColor = NSColor.clear.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let separator = NSColor.separatorColor
            resolved = separator.withAlphaComponent(separator.alphaComponent * 0.5).cgColor
        }
        layer?.backgroundColor = resolved
    }

    override func mouseUp(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if bounds.contains(location) {
            action()
        }
    }
}

// MARK: - Vertically Centered Text Field Cell

private final class VerticallyCenteredTextFieldCell: NSTextFieldCell {
    override func titleRect(forBounds rect: NSRect) -> NSRect {
        var titleRect = super.titleRect(forBounds: rect)
        let textHeight = cellSize(forBounds: rect).height
        titleRect.origin.y = rect.origin.y + (rect.height - textHeight) / 2
        titleRect.size.height = textHeight
        return titleRect
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        super.drawInterior(withFrame: titleRect(forBounds: cellFrame), in: controlView)
    }
}
