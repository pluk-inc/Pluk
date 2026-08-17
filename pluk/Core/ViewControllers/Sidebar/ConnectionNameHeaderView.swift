import AppKit
import Observation
import SwiftUI

/// AppKit replacement for the SwiftUI `ConnectionNameHeader`. Renders the
/// top-of-sidebar row: database icon, connection name, live status badge,
/// and the Search / New-Table action buttons. Tapping the row opens the
/// connection-details popover; the Edit flow there routes back to this view
/// to present the edit sheet.
@MainActor
final class ConnectionNameHeaderView: NSView, NSPopoverDelegate {

    // MARK: - Dependencies

    private let instance: ConnectionInstance
    private let viewModel: SidebarViewModel

    // MARK: - Subviews

    private let hoverBackground = NSView()
    private let iconContainer = NSView()
    private let iconImageView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let statusIconView = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let searchButton = SidebarChromeButton()
    private let plusButton = SidebarChromeButton()

    // MARK: - State

    private var trackingArea: NSTrackingArea?
    private var isHovering = false
    private var connectionDetailsPopover: NSPopover?
    private var createTablePopover: NSPopover?
    private var editSheetController: NSWindowController?

    // MARK: - Init

    init(instance: ConnectionInstance, viewModel: SidebarViewModel) {
        self.instance = instance
        self.viewModel = viewModel
        super.init(frame: .zero)
        setupView()
        refreshAll()
        startObserving()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Setup

    private func setupView() {
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        hoverBackground.wantsLayer = true
        hoverBackground.layer?.cornerRadius = 12
        hoverBackground.alphaValue = 0
        hoverBackground.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hoverBackground)
        applyAppearanceColors()

        iconContainer.wantsLayer = true
        iconContainer.layer?.cornerRadius = 8
        iconContainer.translatesAutoresizingMaskIntoConstraints = false

        iconImageView.imageScaling = .scaleProportionallyUpOrDown
        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.addSubview(iconImageView)

        nameLabel.font = NSFont.preferredFont(forTextStyle: .body)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        statusIconView.imageScaling = .scaleProportionallyUpOrDown
        statusIconView.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = NSFont.preferredFont(forTextStyle: .caption1)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 1
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let statusStack = NSStackView(views: [statusIconView, statusLabel])
        statusStack.orientation = .horizontal
        statusStack.spacing = 3
        statusStack.alignment = .centerY
        statusStack.translatesAutoresizingMaskIntoConstraints = false

        let nameStack = NSStackView(views: [nameLabel, statusStack])
        nameStack.orientation = .vertical
        nameStack.alignment = .leading
        nameStack.spacing = 2
        nameStack.translatesAutoresizingMaskIntoConstraints = false

        configureActionButton(
            searchButton,
            symbolName: "magnifyingglass",
            action: #selector(searchButtonTapped),
            keyEquivalent: "f"
        )
        searchButton.toolTip = "Find Tables (⇧⌘F)"

        configureActionButton(
            plusButton,
            symbolName: "plus.circle",
            action: #selector(plusButtonTapped),
            keyEquivalent: "n"
        )

        let actionStack = NSStackView(views: [searchButton, plusButton])
        actionStack.orientation = .horizontal
        actionStack.spacing = 0
        actionStack.alignment = .centerY
        actionStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconContainer)
        addSubview(nameStack)
        addSubview(actionStack)

        NSLayoutConstraint.activate([
            hoverBackground.leadingAnchor.constraint(equalTo: leadingAnchor),
            hoverBackground.trailingAnchor.constraint(equalTo: trailingAnchor),
            hoverBackground.topAnchor.constraint(equalTo: topAnchor),
            hoverBackground.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            iconContainer.widthAnchor.constraint(equalToConstant: 28),
            iconContainer.heightAnchor.constraint(equalToConstant: 28),
            iconContainer.leadingAnchor.constraint(equalTo: hoverBackground.leadingAnchor, constant: 8),
            iconContainer.centerYAnchor.constraint(equalTo: hoverBackground.centerYAnchor),

            iconImageView.widthAnchor.constraint(equalToConstant: 18),
            iconImageView.heightAnchor.constraint(equalToConstant: 18),
            iconImageView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            iconImageView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),

            nameStack.leadingAnchor.constraint(equalTo: iconContainer.trailingAnchor, constant: 8),
            nameStack.centerYAnchor.constraint(equalTo: hoverBackground.centerYAnchor),
            nameStack.trailingAnchor.constraint(lessThanOrEqualTo: actionStack.leadingAnchor, constant: -8),

            actionStack.trailingAnchor.constraint(equalTo: hoverBackground.trailingAnchor, constant: -6),
            actionStack.centerYAnchor.constraint(equalTo: hoverBackground.centerYAnchor),

            heightAnchor.constraint(greaterThanOrEqualToConstant: 56),
        ])
    }

    private func configureActionButton(
        _ button: SidebarChromeButton,
        symbolName: String,
        action: Selector,
        keyEquivalent: String
    ) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.target = self
        button.action = action
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        button.keyEquivalent = keyEquivalent
        button.keyEquivalentModifierMask = [.command, .shift]
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
    }

    // MARK: - Hover + Click

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
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
        guard let window,
              let mouse = window.mouseLocationOutsideOfEventStream as NSPoint? else {
            setHovering(false)
            return
        }
        let point = convert(mouse, from: nil)
        setHovering(bounds.contains(point))
    }

    override func mouseEntered(with event: NSEvent) { setHovering(true) }
    override func mouseExited(with event: NSEvent) { setHovering(false) }

    private func setHovering(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering
        updateHoverBackground()
    }

    private var isAnyPopoverShown: Bool {
        (connectionDetailsPopover?.isShown ?? false) || (createTablePopover?.isShown ?? false)
    }

    private func updateHoverBackground() {
        hoverBackground.alphaValue = (isHovering || isAnyPopoverShown) ? 0.3 : 0
    }

    override func mouseDown(with event: NSEvent) {
        showConnectionDetailsPopover()
    }

    // MARK: - Data refresh

    private func refreshAll() {
        refreshIcon()
        refreshName()
        refreshStatus()
        refreshCapabilities()
    }

    private func refreshIcon() {
        let type = instance.connection.databaseType
        iconContainer.layer?.backgroundColor = NSColor(type.backgroundColor).cgColor
        iconImageView.image = NSImage(named: type.homeIcon)
    }

    private func refreshName() {
        nameLabel.stringValue = instance.connection.name
    }

    private func refreshCapabilities() {
        let databaseType = instance.connection.databaseType
        searchButton.toolTip = databaseType.supportsKeyValueBrowser
            ? "Find Keys (⇧⌘F)"
            : "Find Tables (⇧⌘F)"
        plusButton.isHidden = !databaseType.supportsTableBrowser
        plusButton.isEnabled = databaseType.supportsTableBrowser
    }

    private func refreshStatus() {
        let status = instance.connectionStatus
        statusLabel.stringValue = status.rawValue
        statusLabel.textColor = statusColor(for: status)

        let config = NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold)
        let image = NSImage(systemSymbolName: statusIconName(for: status), accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        statusIconView.image = image
        statusIconView.contentTintColor = statusColor(for: status)

        statusIconView.removeAllSymbolEffects()
        if status == .connecting {
            statusIconView.addSymbolEffect(
                .rotate.clockwise.byLayer,
                options: .repeat(.continuous)
            )
        }
    }

    private func statusColor(for status: ConnectionStatus) -> NSColor {
        switch status {
        case .connected: return .systemGreen
        case .connecting: return .systemOrange
        case .disconnected, .error: return .secondaryLabelColor
        }
    }

    private func statusIconName(for status: ConnectionStatus) -> String {
        switch status {
        case .connected: return "server.rack"
        case .connecting: return "arrow.2.circlepath"
        case .disconnected, .error: return "network.slash"
        }
    }

    // MARK: - Observation

    private func startObserving() {
        observeConnectionFields()
    }

    private func observeConnectionFields() {
        withObservationTracking {
            _ = self.instance.connection.name
            _ = self.instance.connectionStatus
            _ = self.instance.connection.databaseType
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refreshAll()
                self.observeConnectionFields()
            }
        }
    }

    // MARK: - Actions

    @objc private func searchButtonTapped() {
        viewModel.isSearchVisible.toggle()
        if !viewModel.isSearchVisible {
            viewModel.searchText = ""
        }
    }

    @objc private func plusButtonTapped() {
        showCreateTablePopover()
    }

    private func showCreateTablePopover() {
        if let existing = createTablePopover, existing.isShown {
            existing.close()
            createTablePopover = nil
            return
        }

        let form = CreateTableForm(onCreated: { [weak self] name in
            self?.handleCollectionCreated(name)
        })
        .environment(instance)

        let hostingController = NSHostingController(rootView: form)
        hostingController.sizingOptions = [.preferredContentSize]

        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = hostingController
        // An unsized NSHostingController makes AppKit anchor the popover from a
        // zero-height frame, so the bubble ends up detached from the button once
        // SwiftUI lays out. Resolve the SwiftUI size first, then show below the
        // button (`.minY` — the plus button is unflipped, so `.maxY` means above).
        popover.contentSize = hostingController.view.fittingSize
        popover.show(relativeTo: plusButton.bounds, of: plusButton, preferredEdge: .minY)
        createTablePopover = popover
        updateHoverBackground()
    }

    private func showConnectionDetailsPopover() {
        if let existing = connectionDetailsPopover, existing.isShown {
            existing.close()
            connectionDetailsPopover = nil
            return
        }

        let connection = instance.connection
        let popoverContent = ConnectionDetailsPopover(
            connection: connection,
            databaseType: connection.databaseType,
            environment: connection.environment,
            version: instance.connectionVersion,
            connectedDatabase: instance.connectedDatabase?.name,
            onDisconnect: { [weak self] in
                guard let self else { return }
                self.connectionDetailsPopover?.close()
                self.connectionDetailsPopover = nil
                await self.viewModel.disconnectConnectionInstance(self.instance.id)
            },
            onReconnect: { [weak self] in
                guard let self else { return }
                self.connectionDetailsPopover?.close()
                self.connectionDetailsPopover = nil
                do {
                    try await self.instance.reconnect()
                } catch {
                    debugLog("Reconnect failed: \(error)")
                }
            },
            onEdit: { [weak self] in
                guard let self else { return }
                self.connectionDetailsPopover?.close()
                self.connectionDetailsPopover = nil
                self.handleEditRequested()
            }
        )
        .environment(instance)

        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: popoverContent)
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxX)
        connectionDetailsPopover = popover
        updateHoverBackground()
    }

    private func handleCollectionCreated(_ createdName: String) {
        createTablePopover?.close()
        createTablePopover = nil

        Task { @MainActor in
            let currentSchema = instance.databaseService.currentSchema
            instance.createNewTab(name: createdName, databaseSchema: currentSchema)
            do {
                try await instance.loadCollectionsForCurrentDatabase(schema: currentSchema)
            } catch {
                debugLog("Failed to refresh collections after create: \(error)")
            }
        }
    }

    // MARK: - Edit flow

    private func handleEditRequested() {
        if instance.connectionStatus == .connected {
            presentEditConfirmationAlert()
        } else {
            presentEditSheet()
        }
    }

    private func presentEditConfirmationAlert() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Edit Connection"
        alert.informativeText = "Are you sure you want to edit this active connection?"
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn {
                self?.presentEditSheet()
            }
        }
    }

    private func presentEditSheet() {
        guard let parentWindow = window else { return }

        var sheetWindow: NSWindow?
        let editForm = CreateConnectionForm(
            connection: instance.connection,
            onDisconnect: { [weak self] in
                guard let self else { return }
                await self.viewModel.disconnectConnectionInstance(self.instance.id)
            },
            onSavedConnection: { [weak self] connection, _ in
                guard let self else { return }
                self.openSavedConnection(connection)
            },
            onClose: { [weak parentWindow] in
                guard let sheetWindow else { return }
                parentWindow?.endSheet(sheetWindow)
            }
        )
        .frame(width: 480, height: 640)

        let hostingController = NSHostingController(rootView: editForm)
        let window = NSWindow(contentViewController: hostingController)
        sheetWindow = window
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.setContentSize(NSSize(width: 480, height: 640))
        window.isReleasedWhenClosed = false
        let controller = NSWindowController(window: window)
        editSheetController = controller

        parentWindow.beginSheet(window) { [weak self] _ in
            self?.editSheetController = nil
        }
    }

    // MARK: - NSPopoverDelegate

    func popoverWillClose(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover else { return }
        if popover === connectionDetailsPopover {
            connectionDetailsPopover = nil
        } else if popover === createTablePopover {
            createTablePopover = nil
        }
        refreshHoverState()
        updateHoverBackground()
    }

    // MARK: - Teardown

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            connectionDetailsPopover?.close()
            createTablePopover?.close()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearanceColors()
    }

    private func applyAppearanceColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            hoverBackground.layer?.backgroundColor = NSColor.separatorColor.cgColor
        }
    }

    private func openSavedConnection(_ connection: Connection) {
        let instanceId = viewModel.createNewConnectionInstance(for: connection)
        guard let connectionInstance = ConnectionService.shared.getInstance(instanceId) else { return }

        WindowController.newTab(
            tabType: .connection(instanceId),
            connectionInstance: connectionInstance
        )

        AnalyticsService.shared.trackConnectionOpened(
            databaseType: connection.databaseType,
            isFirstConnection: false
        )
    }
}
