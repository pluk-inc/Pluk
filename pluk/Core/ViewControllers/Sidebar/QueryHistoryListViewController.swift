import AppKit
import Observation

private let sanitizedRedisHistoryHelp =
    "Credentials were redacted. Copy the command and re-enter them before running it."

/// AppKit replacement for the SwiftUI `QueryHistorySidebarList`. Renders
/// query history grouped by date (Today / Yesterday / This Week / Last Week
/// / Older) in an NSTableView, scoped to the connection's currently-selected
/// database.
@MainActor
final class QueryHistoryListViewController: NSViewController {

    private enum Row: Hashable {
        case header(title: String)
        case entry(id: String)
    }

    // MARK: - Dependencies

    private let instance: ConnectionInstance

    // MARK: - Views

    private let scrollView = NSScrollView()
    private let tableView = HoverTrackingHistoryTableView()
    private let emptyStateLabel = NSTextField(labelWithString: "No queries yet")

    // MARK: - State

    private var rows: [Row] = []
    private var entriesById: [String: QueryHistoryEntryViewModel] = [:]
    private var observedClipView: NSClipView?

    // MARK: - Init

    init(instance: ConnectionInstance) {
        self.instance = instance
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 12, right: 4)
        scrollView.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: -6)

        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.rowHeight = 44
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.selectionHighlightStyle = .none
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.focusRingType = .none
        tableView.style = .plain
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.gridStyleMask = []
        tableView.usesAlternatingRowBackgroundColors = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        column.isEditable = false
        column.minWidth = 0
        column.width = 100
        column.maxWidth = .greatestFiniteMagnitude
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.contextMenuProvider = { [weak self] rowIndex in
            self?.makeContextMenu(for: rowIndex)
        }

        scrollView.documentView = tableView

        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyStateLabel.alignment = .center
        emptyStateLabel.font = NSFont.preferredFont(forTextStyle: .body)
        emptyStateLabel.textColor = .tertiaryLabelColor
        emptyStateLabel.lineBreakMode = .byTruncatingTail
        emptyStateLabel.isHidden = true

        let container = NSView()
        container.addSubview(scrollView)
        container.addSubview(emptyStateLabel)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            emptyStateLabel.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 16),
            emptyStateLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),
            emptyStateLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            emptyStateLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
        ])
        self.view = container

        reload()
        startObserving()
    }

    /// Applied by the sidebar shell when the pro-promo card appears so the
    /// last entry doesn't hide behind it.
    func setBottomContentInset(_ inset: CGFloat) {
        guard scrollView.contentInsets.bottom != inset else { return }
        var insets = scrollView.contentInsets
        insets.bottom = inset
        scrollView.contentInsets = insets
    }

    // MARK: - Data

    private func reload() {
        guard let service = instance.queryHistoryService else {
            rows = []
            entriesById = [:]
            tableView.reloadData()
            updateEmptyState()
            return
        }

        let entries = service.fetchHistory(
            limit: 500,
            databaseName: instance.connectedDatabase?.name
        )

        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
        let startOfThisWeek = calendar.date(
            from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        ) ?? startOfToday
        let startOfLastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: startOfThisWeek)
            ?? startOfThisWeek

        var lookup: [String: QueryHistoryEntryViewModel] = [:]
        var bucketed: [String: [QueryHistoryEntryViewModel]] = [:]
        for entry in entries {
            lookup[entry.id] = entry
            let key: String
            if entry.executedAt >= startOfToday {
                key = "Today"
            } else if entry.executedAt >= startOfYesterday {
                key = "Yesterday"
            } else if entry.executedAt >= startOfThisWeek {
                key = "This Week"
            } else if entry.executedAt >= startOfLastWeek {
                key = "Last Week"
            } else {
                key = "Older"
            }
            bucketed[key, default: []].append(entry)
        }
        entriesById = lookup

        let order = ["Today", "Yesterday", "This Week", "Last Week", "Older"]
        var newRows: [Row] = []
        for key in order {
            guard let bucket = bucketed[key], !bucket.isEmpty else { continue }
            newRows.append(.header(title: key))
            for entry in bucket {
                newRows.append(.entry(id: entry.id))
            }
        }

        rows = newRows
        tableView.reloadData()
        updateEmptyState()
    }

    private func updateEmptyState() {
        emptyStateLabel.isHidden = !entriesById.isEmpty
    }

    // MARK: - Actions

    @objc private func rowClicked() {
        let clickedRow = tableView.clickedRow
        guard clickedRow >= 0, clickedRow < rows.count else { return }
        if case .entry(let id) = rows[clickedRow], let entry = entriesById[id] {
            loadInEditor(entry)
        }
    }

    // MARK: - Context Menu

    private func makeContextMenu(for rowIndex: Int) -> NSMenu? {
        guard rowIndex >= 0, rowIndex < rows.count,
              case .entry(let id) = rows[rowIndex],
              let entry = entriesById[id] else { return nil }

        let menu = NSMenu()
        menu.autoenablesItems = false

        addItem(
            to: menu,
            title: "Copy Query",
            symbol: "doc.on.doc",
            action: #selector(contextCopyQuery(_:)),
            entryId: id
        )
        let loadItem = addItem(
            to: menu,
            title: "Load in Editor",
            symbol: "arrow.up.forward.square",
            action: #selector(contextLoadInEditor(_:)),
            entryId: id
        )
        if !entry.isReplayable {
            loadItem.title = "Load in Editor (Credentials Redacted)"
            loadItem.toolTip = sanitizedRedisHistoryHelp
            loadItem.isEnabled = false
        }

        if let tableName = entry.tableName, !tableName.isEmpty {
            menu.addItem(.separator())
            let item = addItem(
                to: menu,
                title: "Open Table: \(tableName)",
                symbol: "table",
                action: #selector(contextOpenTable(_:)),
                entryId: id
            )
            item.toolTip = tableName
        }

        menu.addItem(.separator())
        addItem(
            to: menu,
            title: "Delete",
            symbol: "trash",
            action: #selector(contextDeleteEntry(_:)),
            entryId: id
        )
        return menu
    }

    @discardableResult
    private func addItem(
        to menu: NSMenu,
        title: String,
        symbol: String,
        action: Selector,
        entryId: String
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = entryId
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        menu.addItem(item)
        return item
    }

    @objc private func contextCopyQuery(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let entry = entriesById[id] else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.query, forType: .string)
    }

    @objc private func contextLoadInEditor(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let entry = entriesById[id] else { return }
        loadInEditor(entry)
    }

    private func loadInEditor(_ entry: QueryHistoryEntryViewModel) {
        guard entry.isReplayable else { return }
        if instance.connection.databaseType == .redis {
            instance.createRedisCommandTab(withCommand: entry.query)
        } else {
            instance.createSQLEditorTab(withQuery: entry.query)
        }
    }

    @objc private func contextOpenTable(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let entry = entriesById[id],
              let tableName = entry.tableName else { return }
        instance.createNewTab(name: tableName, databaseSchema: entry.schemaName)
    }

    @objc private func contextDeleteEntry(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        instance.queryHistoryService?.deleteEntry(id)
        reload()
    }

    // MARK: - Observation

    private func startObserving() {
        observeInstance()
    }

    private func observeInstance() {
        withObservationTracking {
            _ = self.instance.connectedDatabase?.name
            _ = self.instance.connectionGeneration
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.reload()
                self?.observeInstance()
            }
        }
    }
}

// MARK: - Table View DataSource

extension QueryHistoryListViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
}

// MARK: - Table View Delegate

extension QueryHistoryListViewController: NSTableViewDelegate {
    // NOTE: Intentionally do NOT implement `tableView(_:isGroupRow:)`. Group
    // rows get automatic separator/background treatment from NSTableView that
    // visually reads as a divider line between the date header and the
    // entries below it. We render the header as a plain row and just mark it
    // non-selectable via `shouldSelectRow`.

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard row >= 0, row < rows.count else { return false }
        if case .header = rows[row] { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row >= 0, row < rows.count else { return 44 }
        switch rows[row] {
        case .header: return 28
        case .entry: return 44
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < rows.count else { return nil }
        switch rows[row] {
        case .header(let title):
            return HistoryHeaderCell(title: title)
        case .entry(let id):
            guard let entry = entriesById[id] else { return nil }
            return HistoryRowCell(entry: entry)
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = HistoryRowView()
        if row >= 0, row < rows.count, case .header = rows[row] {
            view.isSelectable = false
        }
        return view
    }

    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
        guard let hoverTracking = tableView as? HoverTrackingHistoryTableView,
              let sidebarRow = rowView as? HistoryRowView else { return }
        hoverTracking.applyHoverStateIfNeeded(to: sidebarRow, row: row)
    }
}

// MARK: - Hover-aware Table View

@MainActor
private final class HoverTrackingHistoryTableView: NSTableView {
    var contextMenuProvider: ((Int) -> NSMenu?)?

    private var trackingArea: NSTrackingArea?
    private var hoveredRow: Int = -1
    private weak var observedClipView: NSClipView?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let rowIndex = row(at: point)
        guard rowIndex >= 0 else { return nil }
        return contextMenuProvider?(rowIndex)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let previous = observedClipView {
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: previous)
            observedClipView = nil
        }
        guard window != nil, let clipView = enclosingScrollView?.contentView else { return }
        clipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipBoundsDidChange),
            name: NSView.boundsDidChangeNotification,
            object: clipView
        )
        observedClipView = clipView
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func clipBoundsDidChange() { refreshHoverFromMouse() }

    override func mouseMoved(with event: NSEvent) {
        setHoveredRow(rowIndex(for: event.locationInWindow))
    }

    override func mouseEntered(with event: NSEvent) {
        setHoveredRow(rowIndex(for: event.locationInWindow))
    }

    override func mouseExited(with event: NSEvent) { setHoveredRow(-1) }

    func applyHoverStateIfNeeded(to rowView: HistoryRowView, row: Int) {
        rowView.isRowHovered = (row == hoveredRow) && rowView.isSelectable
    }

    private func refreshHoverFromMouse() {
        guard let window else { setHoveredRow(-1); return }
        setHoveredRow(rowIndex(for: window.mouseLocationOutsideOfEventStream))
    }

    private func rowIndex(for windowPoint: NSPoint) -> Int {
        let p = convert(windowPoint, from: nil)
        guard visibleRect.contains(p) else { return -1 }
        return self.row(at: p)
    }

    private func setHoveredRow(_ row: Int) {
        guard row != hoveredRow else { return }
        let previous = hoveredRow
        hoveredRow = row
        if previous >= 0, let v = rowView(atRow: previous, makeIfNecessary: false) as? HistoryRowView {
            v.isRowHovered = false
        }
        if row >= 0, let v = rowView(atRow: row, makeIfNecessary: false) as? HistoryRowView {
            v.isRowHovered = v.isSelectable
        }
    }
}

// MARK: - Row View

@MainActor
private final class HistoryRowView: NSTableRowView {
    var isSelectable = true
    var isRowHovered = false { didSet { updateHighlight() } }

    private let highlightLayer = CALayer()

    override var isSelected: Bool { didSet { updateHighlight() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Match the DatabaseList row's rounded pill exactly so the hover
        // and selection treatment feels continuous across both sidebar
        // modes.
        highlightLayer.cornerRadius = 10
        highlightLayer.opacity = 0
        layer?.addSublayer(highlightLayer)
        applyAppearanceColor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlightLayer.frame = bounds.insetBy(dx: 2, dy: 1)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearanceColor()
    }

    private func applyAppearanceColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            highlightLayer.backgroundColor = NSColor.separatorColor.cgColor
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        isRowHovered = false
        isSelectable = true
    }

    private func updateHighlight() {
        let target: Float = (isSelected || isRowHovered) ? 0.5 : 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlightLayer.opacity = target
        CATransaction.commit()
    }

    override func drawSelection(in dirtyRect: NSRect) {}
}

// MARK: - Header Cell

@MainActor
private final class HistoryHeaderCell: NSView {
    init(title: String) {
        super.init(frame: .zero)
        autoresizingMask = [.width, .height]

        let label = NSTextField(labelWithString: title)
        label.font = NSFont.preferredFont(forTextStyle: .subheadline)
        label.textColor = .tertiaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Entry Cell

@MainActor
private final class HistoryRowCell: NSView {
    init(entry: QueryHistoryEntryViewModel) {
        super.init(frame: .zero)
        autoresizingMask = [.width, .height]

        let previewLabel = NSTextField(labelWithString: entry.queryPreview)
        previewLabel.font = NSFont.preferredFont(forTextStyle: .callout)
        // Failed queries tint the preview text red — subtle, reads as
        // "error" without competing icons or dots.
        previewLabel.textColor = entry.wasSuccessful ? .labelColor : .systemRed
        previewLabel.lineBreakMode = .byTruncatingTail
        previewLabel.maximumNumberOfLines = 1
        previewLabel.translatesAutoresizingMaskIntoConstraints = false

        let metaText: String
        if let duration = entry.formattedDuration {
            metaText = "\(entry.formattedDate) · \(duration)"
        } else {
            metaText = entry.formattedDate
        }
        let metaLabel = NSTextField(labelWithString: metaText)
        metaLabel.font = NSFont.preferredFont(forTextStyle: .subheadline)
        metaLabel.textColor = .tertiaryLabelColor
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.maximumNumberOfLines = 1
        metaLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(previewLabel)
        addSubview(metaLabel)

        NSLayoutConstraint.activate([
            previewLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            previewLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            previewLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),

            metaLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            metaLabel.topAnchor.constraint(equalTo: previewLabel.bottomAnchor, constant: 3),
            metaLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
        ])

        let queryToolTip = entry.wasSuccessful
            ? entry.query
            : (entry.errorMessage.map { "\(entry.query)\n\n\($0)" } ?? entry.query)
        toolTip = entry.isReplayable
            ? queryToolTip
            : "\(queryToolTip)\n\n\(sanitizedRedisHistoryHelp)"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
