import AppKit
import Observation

/// Cursor-based Redis key browser. It intentionally never materializes or
/// sorts the full keyspace: pages are appended as the user scrolls and a
/// refresh invalidates any in-flight generation.
@MainActor
final class RedisKeyListViewController: NSViewController {
    private static let maximumLoadedKeyCount = 25_000

    private let instance: ConnectionInstance
    private let viewModel: SidebarViewModel

    private let typePicker = NSPopUpButton()
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let progressIndicator = NSProgressIndicator()
    private lazy var continueScanningButton = NSButton(
        title: "Continue Scanning",
        target: self,
        action: #selector(continueScanning)
    )

    private var keys: [RedisKey] = []
    private var seenKeys: Set<Data> = []
    private var cursor: UInt64 = 0
    private var isComplete = false
    private var isLoading = false
    private var reachedDisplayLimit = false
    private var generation = UUID()
    private var loadTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var selectedType: RedisKeyType?
    private var emptyPageBudget = 3
    private weak var observedClipView: NSClipView?

    var onScrolledFromTopChanged: ((Bool) -> Void)?
    private var isScrolledFromTop = false

    init(instance: ConnectionInstance, viewModel: SidebarViewModel) {
        self.instance = instance
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        configureTypePicker()
        configureTable()

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.alignment = .center
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 3

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.isHidden = true

        continueScanningButton.translatesAutoresizingMaskIntoConstraints = false
        continueScanningButton.bezelStyle = .rounded
        continueScanningButton.controlSize = .small
        continueScanningButton.isHidden = true

        let filterLabel = NSTextField(labelWithString: "Type")
        filterLabel.font = .systemFont(ofSize: 11, weight: .medium)
        filterLabel.textColor = .secondaryLabelColor
        filterLabel.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(filterLabel)
        root.addSubview(typePicker)
        root.addSubview(scrollView)
        root.addSubview(statusLabel)
        root.addSubview(progressIndicator)
        root.addSubview(continueScanningButton)

        NSLayoutConstraint.activate([
            filterLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 3),
            filterLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            filterLabel.centerYAnchor.constraint(equalTo: typePicker.centerYAnchor),

            typePicker.topAnchor.constraint(equalTo: root.topAnchor),
            typePicker.leadingAnchor.constraint(equalTo: filterLabel.trailingAnchor, constant: 6),
            typePicker.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -8),
            typePicker.heightAnchor.constraint(equalToConstant: 26),

            scrollView.topAnchor.constraint(equalTo: typePicker.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            statusLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.trailingAnchor, constant: -12),

            progressIndicator.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            progressIndicator.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),

            continueScanningButton.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            continueScanningButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 10),
        ])

        view = root
        observeSearchText()
        observeRefreshRequests()
        resetAndLoad()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        loadTask?.cancel()
        searchTask?.cancel()
    }

    func setBottomContentInset(_ inset: CGFloat) {
        var contentInsets = scrollView.contentInsets
        contentInsets.bottom = inset
        scrollView.contentInsets = contentInsets
    }

    func setSidebarHovered(_ hovered: Bool) {
        _ = hovered
    }

    func connectionDidBecomeReady() {
        resetAndLoad()
    }

    private func configureTypePicker() {
        typePicker.translatesAutoresizingMaskIntoConstraints = false
        typePicker.controlSize = .small
        typePicker.addItems(withTitles: [
            "All", "String", "Hash", "List", "Set", "Sorted Set", "Stream", "JSON"
        ])
        typePicker.target = self
        typePicker.action = #selector(typeSelectionChanged)
    }

    private func configureTable() {
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 12, right: 4)
        scrollView.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: -6)

        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.rowHeight = 34
        tableView.intercellSpacing = .zero
        tableView.selectionHighlightStyle = .regular
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.focusRingType = .none
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(openSelectedKey)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("redisKey"))
        column.resizingMask = .autoresizingMask
        column.minWidth = 80
        tableView.addTableColumn(column)
        scrollView.documentView = tableView

        let clipView = scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        observedClipView = clipView
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollBoundsChanged),
            name: NSView.boundsDidChangeNotification,
            object: clipView
        )
    }

    private func observeRefreshRequests() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(redisKeysRefreshRequested),
            name: .redisKeysRefreshRequested,
            object: instance
        )
    }

    @objc private func redisKeysRefreshRequested() {
        resetAndLoad()
    }

    private func observeSearchText() {
        withObservationTracking {
            _ = viewModel.searchText
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.searchTask?.cancel()
                self.searchTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                    self?.resetAndLoad()
                }
                self.observeSearchText()
            }
        }
    }

    @objc private func typeSelectionChanged() {
        selectedType = switch typePicker.indexOfSelectedItem {
        case 1: .string
        case 2: .hash
        case 3: .list
        case 4: .set
        case 5: .sortedSet
        case 6: .stream
        case 7: .json
        default: nil
        }
        resetAndLoad()
    }

    @objc private func openSelectedKey() {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard row >= 0, row < keys.count else { return }
        let key = keys[row]
        instance.createRedisKeyTab(keyData: key.bytes, displayName: key.displayString)
    }

    @objc private func scrollBoundsChanged() {
        let visibleRect = scrollView.documentVisibleRect
        let scrolled = visibleRect.minY > 2
        if scrolled != isScrolledFromTop {
            isScrolledFromTop = scrolled
            onScrolledFromTopChanged?(scrolled)
        }

        let remaining = tableView.bounds.height - visibleRect.maxY
        if remaining < 300 {
            loadNextPage()
        }
    }

    @objc private func continueScanning() {
        emptyPageBudget = 3
        continueScanningButton.isHidden = true
        updateStatus(message: "Scanning the next keyspace segment…", isLoading: true)
        loadNextPage()
    }

    private func resetAndLoad() {
        generation = UUID()
        loadTask?.cancel()
        loadTask = nil
        keys = []
        seenKeys = []
        cursor = 0
        isComplete = false
        isLoading = false
        reachedDisplayLimit = false
        emptyPageBudget = 3
        continueScanningButton.isHidden = true
        tableView.reloadData()
        statusLabel.stringValue = "Loading keys…"
        statusLabel.isHidden = false
        progressIndicator.isHidden = false
        progressIndicator.startAnimation(nil)
        loadNextPage()
    }

    private func loadNextPage() {
        guard !isLoading, !isComplete, instance.connectionStatus == .connected else {
            if instance.connectionStatus != .connected {
                updateStatus(message: "Connect to Redis to browse keys.", isLoading: false)
            }
            return
        }

        isLoading = true
        let requestGeneration = generation
        let requestCursor = cursor
        let pattern = redisMatchPattern(from: viewModel.searchText)
        let type = selectedType

        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let page = try await self.instance.databaseService.scanRedisKeys(
                    cursor: requestCursor,
                    pattern: pattern,
                    type: type,
                    count: 200
                )
                try Task.checkCancellation()
                guard self.generation == requestGeneration else { return }

                let additions = page.keys.filter { self.seenKeys.insert($0.bytes).inserted }
                let remainingCapacity = max(Self.maximumLoadedKeyCount - self.keys.count, 0)
                self.keys.append(contentsOf: additions.prefix(remainingCapacity))
                self.cursor = page.nextCursor
                self.isComplete = page.isComplete
                if !page.isComplete, self.keys.count >= Self.maximumLoadedKeyCount {
                    self.reachedDisplayLimit = true
                    self.isComplete = true
                }
                self.isLoading = false
                self.tableView.reloadData()

                if self.keys.isEmpty, self.isComplete {
                    self.updateStatus(message: "No matching keys", isLoading: false)
                } else {
                    self.updateStatus(message: "", isLoading: false)
                    // SCAN may return an empty or very sparse page with a
                    // nonzero cursor. Advance a small bounded burst while the
                    // result cannot fill the viewport, then require an explicit
                    // continuation so selective filters cannot hammer through a
                    // huge keyspace unattended or leave the user unable to
                    // trigger the scroll-based pagination path.
                    let visibleHeight = self.scrollView.documentVisibleRect.height
                    let contentHeight = CGFloat(self.keys.count) * self.tableView.rowHeight
                    let cannotScrollYet = visibleHeight <= 0 || contentHeight <= visibleHeight
                    if !self.isComplete, additions.isEmpty || cannotScrollYet {
                        if self.emptyPageBudget > 0 {
                            self.emptyPageBudget -= 1
                            self.loadNextPage()
                        } else {
                            self.updateStatus(
                                message: additions.isEmpty
                                    ? "No matches in this keyspace segment."
                                    : "\(self.keys.count) matching \(self.keys.count == 1 ? "key" : "keys") loaded. More keyspace remains.",
                                isLoading: false
                            )
                            self.continueScanningButton.isHidden = false
                        }
                    } else if !additions.isEmpty {
                        self.emptyPageBudget = 3
                        self.continueScanningButton.isHidden = true
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                guard self.generation == requestGeneration else { return }
                self.isLoading = false
                self.updateStatus(message: error.localizedDescription, isLoading: false)
            }
        }
    }

    private func redisMatchPattern(from searchText: String) -> String? {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("*") || trimmed.contains("?") || trimmed.contains("[") {
            return trimmed
        }
        return "*\(trimmed)*"
    }

    private func updateStatus(message: String, isLoading: Bool) {
        statusLabel.stringValue = message
        statusLabel.isHidden = message.isEmpty
        if isLoading {
            continueScanningButton.isHidden = true
        }
        progressIndicator.isHidden = !isLoading
        if isLoading {
            progressIndicator.startAnimation(nil)
        } else {
            progressIndicator.stopAnimation(nil)
        }
    }
}

extension RedisKeyListViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        keys.count + (reachedDisplayLimit ? 1 : 0)
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        if reachedDisplayLimit, row == keys.count {
            let identifier = NSUserInterfaceItemIdentifier("RedisKeyCell")
            let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView)
                ?? makeKeyCell(identifier: identifier)
            cell.textField?.stringValue = "25,000-key display limit — narrow the search to continue"
            cell.textField?.toolTip = "Use a key pattern or type filter to keep browsing without loading the full keyspace."
            cell.imageView?.image = NSImage(
                systemSymbolName: "line.3.horizontal.decrease.circle",
                accessibilityDescription: nil
            )
            return cell
        }
        guard row >= 0, row < keys.count else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("RedisKeyCell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView)
            ?? makeKeyCell(identifier: identifier)
        let key = keys[row]
        cell.imageView?.image = NSImage(systemSymbolName: "key.horizontal", accessibilityDescription: nil)
        cell.textField?.stringValue = key.displayString
        cell.textField?.toolTip = key.displayString
        return cell
    }

    private func makeKeyCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier

        let icon = NSImageView(image: NSImage(systemSymbolName: "key.horizontal", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        cell.imageView = icon
        cell.textField = label
        cell.addSubview(icon)
        cell.addSubview(label)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
