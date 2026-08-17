import AppKit
import SwiftUI

final class TabBarView: NSView {
    private let instance: ConnectionInstance
    private let appViewModel: AppViewModel

    private var prevButton: HoverNavButton!
    private var nextButton: HoverNavButton!
    private var scrollView: NSScrollView!
    private let scrollFadeMask = CAGradientLayer()
    private var tabsContainer: NSView!
    private var newTabButton: HoverNavButton!
    private var sidebarToggleButton: HoverNavButton!

    private var tabViews: [UUID: DraggableTabNSView] = [:]
    private var draggedIndex: Int?
    private var dropInsertionIndex: Int?
    private var isScrollable = false
    private var isDragActive = false

    private var newTabInlineConstraint: NSLayoutConstraint!
    private var newTabFixedConstraint: NSLayoutConstraint!
    private var scrollViewLeadingConstraint: NSLayoutConstraint!
    private var scrollViewTrailingConstraint: NSLayoutConstraint!

    private var leadingConstraint: NSLayoutConstraint!
    private var isSidebarVisible = true
    nonisolated(unsafe) private var sidebarObserver: NSObjectProtocol?

    nonisolated(unsafe) private var eventMonitor: Any?
    private var isLayoutingTabs = false

    private let tabWidth: CGFloat = 182
    private let tabHeight: CGFloat = 38
    private let selectedTabHeight: CGFloat = 40
    private let tabSpacing: CGFloat = 4
    /// Lifts the tabs off the bottom edge of the bar so they sit slightly
    /// higher within the tab bar chrome.
    private let tabBottomInset: CGFloat = 3
    private let newTabButtonWidth: CGFloat = 36
    /// Leading inset for the tab bar content when the left sidebar is
    /// collapsed — shifts the chevrons/tabs right to clear the window traffic
    /// lights and the sidebar-reveal toolbar button.
    private let sidebarCollapsedLeadingInset: CGFloat = 150
    private var newTabButtonGap: CGFloat {
        if #available(macOS 26, *) { 4 } else { 6 }
    }
    private var newTabButtonLeadingGap: CGFloat {
        if #available(macOS 26, *) { newTabButtonGap + 2 } else { newTabButtonGap }
    }
    private var navButtonSize: CGFloat {
        if #available(macOS 26, *) { 28 } else { 26 }
    }
    private var scrollViewBottomOffset: CGFloat {
        if #available(macOS 26, *) { 3 } else { 0 }
    }
    private var newTabButtonBottomInset: CGFloat {
        if #available(macOS 26, *) { 7 } else { 7 }
    }
    private var tabContentLeadingPadding: CGFloat {
        if #available(macOS 26, *) { 15 } else { 10 }
    }
    private var tabScrollLeadingOffset: CGFloat {
        6 - tabContentLeadingPadding
    }
    private var scrollableTabScrollLeadingOffset: CGFloat {
        6
    }
    private var scrollableTabScrollTrailingOffset: CGFloat {
        6
    }
    private let selectedTabRevealPadding: CGFloat = 12
    private var scrollableTabReservedWidth: CGFloat {
        isScrollable ? newTabButtonGap + scrollableTabScrollTrailingOffset : 0
    }

    init(instance: ConnectionInstance, appViewModel: AppViewModel) {
        self.instance = instance
        self.appViewModel = appViewModel
        super.init(frame: .zero)
        wantsLayer = true
        setupLayout()
        startObserving()
        setupKeyboardShortcuts()
        syncTabs()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let observer = sidebarObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            syncInitialSidebarState()
            refreshNavigationHoverStates()
        }
    }

    // MARK: - Layout

    private func setupLayout() {
        prevButton = makeNavButton(symbolName: "chevron.left")
        prevButton.target = self
        prevButton.action = #selector(prevTabAction)
        prevButton.installCustomTooltip("Previous Tab", shortcut: .init(modifiers: [.command, .option], key: "←"))
        addSubview(prevButton)

        nextButton = makeNavButton(symbolName: "chevron.right")
        nextButton.target = self
        nextButton.action = #selector(nextTabAction)
        nextButton.installCustomTooltip("Next Tab", shortcut: .init(modifiers: [.command, .option], key: "→"))
        addSubview(nextButton)

        scrollView = NonDraggingScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.contentView = NonDraggingClipView()
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        // The tab bar lives in the `.fullSizeContentView` titlebar region.
        // Left automatic, NSScrollView injects a titlebar-height top inset that
        // shifts the tabs down the moment the content becomes scrollable.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero

        tabsContainer = NonDraggingView()
        tabsContainer.wantsLayer = true
        tabsContainer.autoresizingMask = [.height]
        scrollView.documentView = tabsContainer

        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .none
        scrollView.wantsLayer = true
        addSubview(scrollView)
        setupScrollFadeMask()

        newTabButton = makeNavButton(symbolName: "plus", fontSize: 12)
        newTabButton.target = self
        newTabButton.action = #selector(newTabAction)
        newTabButton.installCustomTooltip("New Tab", shortcut: .init(modifiers: [.command], key: "T"))
        newTabButton.isHidden = true
        addSubview(newTabButton)

        sidebarToggleButton = makeNavButton(symbolName: "sidebar.right")
        sidebarToggleButton.target = self
        sidebarToggleButton.action = #selector(toggleSidebarAction)
        sidebarToggleButton.installCustomTooltip("Toggle Row Details", shortcut: .init(modifiers: [.command], key: "]"))
        addSubview(sidebarToggleButton)

        setupConstraints()
    }

    private func setupConstraints() {
        prevButton.translatesAutoresizingMaskIntoConstraints = false
        nextButton.translatesAutoresizingMaskIntoConstraints = false
        newTabButton.translatesAutoresizingMaskIntoConstraints = false
        sidebarToggleButton.translatesAutoresizingMaskIntoConstraints = false

        let leadingConstraint = prevButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8)
        self.leadingConstraint = leadingConstraint
        scrollViewLeadingConstraint = scrollView.leadingAnchor.constraint(equalTo: nextButton.trailingAnchor, constant: tabScrollLeadingOffset + 1)
        scrollViewTrailingConstraint = scrollView.trailingAnchor.constraint(equalTo: sidebarToggleButton.leadingAnchor, constant: -4)

        newTabInlineConstraint = newTabButton.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 0)
        newTabFixedConstraint = newTabButton.trailingAnchor.constraint(equalTo: sidebarToggleButton.leadingAnchor, constant: -4)

        let constraints: [NSLayoutConstraint] = [
            leadingConstraint,
            prevButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            prevButton.widthAnchor.constraint(equalToConstant: navButtonSize),
            prevButton.heightAnchor.constraint(equalToConstant: navButtonSize),

            nextButton.leadingAnchor.constraint(equalTo: prevButton.trailingAnchor),
            nextButton.centerYAnchor.constraint(equalTo: prevButton.centerYAnchor),
            nextButton.widthAnchor.constraint(equalToConstant: navButtonSize),
            nextButton.heightAnchor.constraint(equalToConstant: navButtonSize),

            scrollViewLeadingConstraint,
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: scrollViewBottomOffset),
            scrollViewTrailingConstraint,

            sidebarToggleButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            sidebarToggleButton.centerYAnchor.constraint(equalTo: prevButton.centerYAnchor),
            sidebarToggleButton.widthAnchor.constraint(equalToConstant: 34),
            sidebarToggleButton.heightAnchor.constraint(equalToConstant: navButtonSize),

            newTabButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -newTabButtonBottomInset),
            newTabButton.widthAnchor.constraint(equalToConstant: newTabButtonWidth),
            newTabButton.heightAnchor.constraint(equalToConstant: navButtonSize),
        ]

        NSLayoutConstraint.activate(constraints)

        newTabInlineConstraint.isActive = true
    }

    // MARK: - Factory Methods

    private var navButtonCornerRadius: CGFloat {
        if #available(macOS 26, *) { 10 } else { 6 }
    }

    private func makeNavButton(symbolName: String, fontSize: CGFloat = 14) -> HoverNavButton {
        let button = HoverNavButton(cornerRadius: navButtonCornerRadius)
        button.bezelStyle = .inline
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        button.imagePosition = .imageOnly
        button.symbolConfiguration = .init(pointSize: fontSize, weight: .regular)
        button.contentTintColor = .secondaryLabelColor
        return button
    }

    // MARK: - Tab Syncing

    func syncTabs() {
        if isDragActive { return }
        draggedIndex = nil
        dropInsertionIndex = nil
        newTabButton.resetHover()
        let currentTabs = instance.tabs
        let currentIds = Set(currentTabs.map(\.id))
        let existingIds = Set(tabViews.keys)

        for id in existingIds where !currentIds.contains(id) {
            if let view = tabViews.removeValue(forKey: id) {
                view.removeFromSuperview()
            }
        }

        for (index, tab) in currentTabs.enumerated() {
            if let existingView = tabViews[tab.id] {
                existingView.tabIndex = index
                if let tabButton = existingView.hostedView as? TabButtonView {
                    tabButton.update(
                        tab: tab,
                        isSelected: instance.selectedTab?.id == tab.id,
                        databaseType: instance.connection.databaseType
                    )
                }
            } else {
                let draggable = makeDraggableTab(for: tab, at: index)
                tabsContainer.addSubview(draggable)
                tabViews[tab.id] = draggable
            }
        }

        layoutTabs(animated: false)
        updateScrollability()
        updateNavigationButtons()
        updateSidebarToggleAppearance()
        scrollToSelectedTab(animated: true)
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.scrollToSelectedTab(animated: false)
        }
    }

    private func makeDraggableTab(for tab: DatabaseTab, at index: Int) -> DraggableTabNSView {
        let draggable = DraggableTabNSView()
        draggable.tabIndex = index
        draggable.snapshotTitle = tab.name
        draggable.snapshotIcon = getTabIconName(for: tab, databaseType: instance.connection.databaseType)
        draggable.onReorder = { [weak self] from, to in
            guard let self else { return }
            if from < self.instance.tabs.count {
                let movingTab = self.instance.tabs[from]
                self.tabViews[movingTab.id]?.alphaValue = 0
            }
            self.instance.moveTab(fromIndex: from, toIndex: to)
            self.isDragActive = false
            self.syncTabs()
        }
        draggable.onDragBegin = { [weak self] in
            guard let self else { return }
            self.isDragActive = true
            for (id, draggableView) in self.tabViews {
                guard let tabButton = draggableView.hostedView as? TabButtonView else { continue }
                tabButton.isDragActive = true
                if let current = self.instance.tabs.first(where: { $0.id == id }) {
                    tabButton.update(tab: current, isSelected: current.id == tab.id, databaseType: self.instance.connection.databaseType)
                }
            }
            instance.selectTab(tab)
        }
        draggable.onDragPulledOut = { [weak self] dragIndex, insertionIndex in
            guard let self else { return }
            self.draggedIndex = dragIndex
            self.dropInsertionIndex = insertionIndex
            self.layoutTabs(animated: true)
        }
        draggable.onInsertionIndexChanged = { [weak self] insertionIndex in
            self?.dropInsertionIndex = insertionIndex
            self?.layoutTabs(animated: true)
        }
        draggable.onDragEnded = { [weak self] willReorder in
            guard let self else { return }
            for draggableView in self.tabViews.values {
                (draggableView.hostedView as? TabButtonView)?.isDragActive = false
            }
            if !willReorder {
                self.draggedIndex = nil
                self.isDragActive = false
            }
            self.dropInsertionIndex = nil
            self.layoutTabs(animated: false)
        }
        draggable.onSelect = { [weak self] in
            self?.instance.selectTab(tab)
        }

        draggable.wantsLayer = true
        draggable.layer?.backgroundColor = .clear
        draggable.layer?.masksToBounds = false

        let tabButton = TabButtonView(
            tab: tab,
            isSelected: instance.selectedTab?.id == tab.id,
            databaseType: instance.connection.databaseType,
            onClose: { [weak self] in
                self?.instance.removeTab(tab)
                self?.syncTabs()
            }
        )
        tabButton.frame = NSRect(x: 0, y: 0, width: tabWidth, height: tabHeight)
        tabButton.autoresizingMask = []
        draggable.addSubview(tabButton)
        draggable.hostedView = tabButton

        draggable.registerForDraggedTypes([.string])
        return draggable
    }

    // MARK: - Tab Layout

    func layoutTabs(animated: Bool) {
        let tabs = instance.tabs
        guard !tabs.isEmpty else {
            tabsContainer.setFrameSize(NSSize(width: 0, height: scrollView.bounds.height))
            return
        }

        let containerHeight = scrollView.bounds.height
        var xOffset: CGFloat = tabContentLeadingPadding

        for (index, tab) in tabs.enumerated() {
            guard let draggable = tabViews[tab.id] else { continue }

            let isCollapsed = shouldCollapseTab(at: index)
            let isLastTab = index == tabs.count - 1
            let isDragged = draggedIndex == index

            // Insert gap before this tab if needed
            xOffset += gapBefore(tabIndex: index)

            if isCollapsed {
                draggable.alphaValue = 0
            } else {
                let trailingSpace: CGFloat = isLastTab ? 0 : tabSpacing
                let targetHeight = tabHeight(for: tab)
                let targetFrame = NSRect(x: xOffset, y: tabBottomInset, width: tabWidth, height: targetHeight)
                let targetAlpha: CGFloat = isDragged ? 0 : 1

                draggable.hostedView?.frame = NSRect(x: 0, y: 0, width: tabWidth, height: tabHeight)

                if animated && !isDragged {
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.25
                        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                        draggable.animator().frame = targetFrame
                        draggable.animator().alphaValue = targetAlpha
                    }
                } else {
                    draggable.frame = targetFrame
                    draggable.alphaValue = targetAlpha
                }

                xOffset += tabWidth + trailingSpace
            }

            // Insert gap after this tab if needed
            xOffset += gapAfter(tabIndex: index)
        }

        // Always keep inline constraint constant up to date
        newTabInlineConstraint?.constant = xOffset + newTabButtonLeadingGap
        if !isScrollable {
            xOffset += newTabButtonLeadingGap + newTabButtonWidth + newTabButtonGap
        }

        xOffset += selectedTabRevealPadding + scrollableTabReservedWidth // Trailing padding

        let containerWidth = max(xOffset, scrollView.bounds.width)
        let newSize = NSSize(width: containerWidth, height: containerHeight)
        if tabsContainer.frame.size != newSize {
            tabsContainer.setFrameSize(newSize)
        }
    }

    private func tabHeight(for tab: DatabaseTab) -> CGFloat {
        tab.id == instance.selectedTab?.id ? selectedTabHeight : tabHeight
    }

    private func gapWidth(forDraggedIndex dragged: Int) -> CGFloat {
        let isDraggedTabLast = dragged == instance.tabs.count - 1
        return isDraggedTabLast ? tabWidth : tabWidth + tabSpacing
    }

    private func isDraggingToOriginalPosition(insertion: Int, dragged: Int) -> Bool {
        insertion == dragged || insertion == dragged + 1
    }

    private func gapBefore(tabIndex: Int) -> CGFloat {
        guard !shouldCollapseTab(at: tabIndex),
              let insertion = dropInsertionIndex,
              let dragged = draggedIndex,
              !isDraggingToOriginalPosition(insertion: insertion, dragged: dragged),
              insertion == tabIndex else {
            return 0
        }
        return gapWidth(forDraggedIndex: dragged)
    }

    private func gapAfter(tabIndex: Int) -> CGFloat {
        guard !shouldCollapseTab(at: tabIndex),
              let insertion = dropInsertionIndex,
              let dragged = draggedIndex,
              !isDraggingToOriginalPosition(insertion: insertion, dragged: dragged),
              tabIndex == instance.tabs.count - 1,
              insertion == instance.tabs.count else {
            return 0
        }
        return gapWidth(forDraggedIndex: dragged)
    }

    private func shouldCollapseTab(at index: Int) -> Bool {
        guard let dragged = draggedIndex,
              let insertion = dropInsertionIndex,
              index == dragged else {
            return false
        }
        return !isDraggingToOriginalPosition(insertion: insertion, dragged: dragged)
    }

    // MARK: - Scrollability

    private func updateScrollability() {
        let viewWidth = scrollView.bounds.width
        guard viewWidth > 0 else { return }

        let contentWidth = tabsContainer.frame.width
        let wasScrollable = isScrollable
        isScrollable = contentWidth > viewWidth

        newTabButton.isHidden = false
        updateScrollEdgeSpacing()
        scrollViewTrailingConstraint.constant = isScrollable
            ? -(newTabButtonWidth + newTabButtonGap + scrollableTabScrollTrailingOffset)
            : -4

        if isScrollable {
            guard !newTabFixedConstraint.isActive else { return }
            newTabInlineConstraint.isActive = false
            newTabFixedConstraint.isActive = true
        } else {
            guard !newTabInlineConstraint.isActive else { return }
            newTabFixedConstraint.isActive = false
            newTabInlineConstraint.isActive = true
        }

        if wasScrollable != isScrollable {
            layoutTabs(animated: false)
        }

        updateScrollFadeMask()
        needsLayout = true
    }

    private func updateScrollEdgeSpacing() {
        let isScrolledFromLeadingEdge = scrollView.contentView.bounds.minX > 0.5
        scrollViewLeadingConstraint.constant = isScrollable && isScrolledFromLeadingEdge
            ? scrollableTabScrollLeadingOffset
            : tabScrollLeadingOffset
    }

    private func scrollToSelectedTab(animated: Bool) {
        guard let selectedTab = instance.selectedTab,
              let draggable = tabViews[selectedTab.id] else { return }

        layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()

        let tabFrame = draggable.frame
        let visibleRect = scrollView.contentView.bounds
        let effectiveVisibleWidth = max(1, visibleRect.width - scrollableTabReservedWidth)
        let effectiveVisibleMaxX = visibleRect.minX + effectiveVisibleWidth
        let targetMinX = max(0, tabFrame.minX - selectedTabRevealPadding)
        let targetMaxX = tabFrame.maxX + selectedTabRevealPadding

        if targetMinX < visibleRect.minX || targetMaxX > effectiveVisibleMaxX {
            let targetX = if targetMaxX > effectiveVisibleMaxX {
                targetMaxX - effectiveVisibleWidth
            } else {
                targetMinX
            }
            let maxX = max(0, tabsContainer.frame.width - visibleRect.width)
            let clampedX = max(0, min(targetX, maxX))
            let targetPoint = NSPoint(x: clampedX, y: 0)

            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    scrollView.contentView.animator().setBoundsOrigin(targetPoint)
                }
            } else {
                scrollView.contentView.scroll(to: targetPoint)
            }
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    // MARK: - Navigation State

    private func updateNavigationButtons() {
        let tabs = instance.tabs
        prevButton.isEnabled = instance.selectedTab != tabs.first
        nextButton.isEnabled = instance.selectedTab != tabs.last
        prevButton.contentTintColor = prevButton.isEnabled ? .secondaryLabelColor : .tertiaryLabelColor
        nextButton.contentTintColor = nextButton.isEnabled ? .secondaryLabelColor : .tertiaryLabelColor
    }

    private func updateSidebarToggleAppearance() {
        let isActive = appViewModel.isRightSidebarVisible
        sidebarToggleButton.contentTintColor = isActive ? .labelColor : .secondaryLabelColor
    }

    // MARK: - Actions

    @objc private func prevTabAction() {
        guard let currentTab = instance.selectedTab ?? instance.tabs.first else { return }
        instance.previousTab(currentTab)
    }

    @objc private func nextTabAction() {
        guard let currentTab = instance.selectedTab ?? instance.tabs.first else { return }
        instance.nextTab(currentTab)
    }

    @objc private func newTabAction() {
        instance.createEditorTab()
    }

    @objc private func toggleSidebarAction() {
        NotificationCenter.default.post(name: .toggleRightSidebar, object: nil)
    }

    // MARK: - Observation

    private func startObserving() {
        observeTabs()
        observeDatabaseType()
        observeSidebarToggle()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppearanceChange),
            name: .appAppearanceDidChange,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScrollBoundsChange),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        // `queue: nil` runs the block synchronously on the posting thread;
        // `.sidebarAnimationWillStart` is always posted from the main thread
        // (`SidebarSplitViewController.setSidebar`). Updating the leading
        // inset synchronously — rather than via `Task`/`queue: .main`, which
        // defer to a later runloop pass — keeps the tab bar in lockstep with
        // the instant sidebar collapse instead of shifting a frame later.
        sidebarObserver = NotificationCenter.default.addObserver(
            forName: .sidebarAnimationWillStart,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            let isCollapsing = notification.userInfo?["isCollapsing"] as? Bool ?? false
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isSidebarVisible = !isCollapsing
                self.leadingConstraint.constant = isCollapsing ? self.sidebarCollapsedLeadingInset : 8
            }
        }
    }

    @objc private func handleScrollBoundsChange() {
        updateScrollEdgeSpacing()
        updateScrollFadeMask()
    }

    private func observeTabs() {
        withObservationTracking {
            _ = self.instance.tabs
            _ = self.instance.tabs.map(\.id)
            _ = self.instance.tabs.map(\.name)
            _ = self.instance.tabs.map(\.hasSchemaDeviation)
            _ = self.instance.selectedTab
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.syncTabs()
                self.observeTabs()
            }
        }
    }

    private func observeDatabaseType() {
        withObservationTracking {
            _ = self.instance.databaseType
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.layoutTabs(animated: false)
                self.updateScrollability()
                self.observeDatabaseType()
            }
        }
    }

    private func observeSidebarToggle() {
        withObservationTracking {
            _ = self.appViewModel.isRightSidebarVisible
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateSidebarToggleAppearance()
                self.observeSidebarToggle()
            }
        }
    }

    private func syncInitialSidebarState() {
        var current: NSView? = superview
        while let view = current {
            if let splitView = view as? HoverDividerSplitView {
                isSidebarVisible = !splitView.isSidebarCollapsed
                leadingConstraint.constant = isSidebarVisible ? 8 : sidebarCollapsedLeadingInset
                return
            }
            current = view.superview
        }
    }

    // MARK: - Keyboard Shortcuts

    private func setupKeyboardShortcuts() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true else { return event }

            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            let key = event.charactersIgnoringModifiers

            if flags == .command {
                switch key {
                case "w":
                    guard let selectedTab = instance.selectedTab else { return event }
                    instance.removeTab(selectedTab)
                    self.syncTabs()
                    return nil
                case "t":
                    instance.createEditorTab()
                    return nil
                default:
                    if let char = key, let digit = Int(char), (1...9).contains(digit) {
                        instance.selectTabByIndex(digit - 1)
                        return nil
                    }
                }
            }

            if flags == [.command, .option] {
                switch event.keyCode {
                case 123:
                    self.prevTabAction()
                    return nil
                case 124:
                    self.nextTabAction()
                    return nil
                default:
                    break
                }
            }

            if flags == [.command, .shift] {
                switch key {
                case "[":
                    self.prevTabAction()
                    return nil
                case "]":
                    self.nextTabAction()
                    return nil
                default:
                    break
                }
            }

            return event
        }
    }

    // MARK: - Appearance

    @objc private func handleAppearanceChange() {
        refreshAppearance()
    }

    private func refreshAppearance() {
        for draggable in tabViews.values {
            if let tabButton = draggable.hostedView as? TabButtonView {
                tabButton.updateAppearance()
            }
        }
        refreshNavigationHoverStates()
        updateSidebarToggleAppearance()
    }

    func hitTarget(atWindowPoint locationInWindow: NSPoint) -> NSView? {
        for button in [prevButton, nextButton, newTabButton, sidebarToggleButton] {
            guard let button, !button.isHidden, button.alphaValue > 0 else { continue }
            let localPoint = button.convert(locationInWindow, from: nil)
            if button.bounds.contains(localPoint) {
                return button
            }
        }
        return nil
    }

    func refreshNavigationHoverStates() {
        prevButton?.refreshHoverState()
        nextButton?.refreshHoverState()
        newTabButton?.refreshHoverState()
        sidebarToggleButton?.refreshHoverState()
    }

    private func setupScrollFadeMask() {
        scrollFadeMask.startPoint = CGPoint(x: 0, y: 0.5)
        scrollFadeMask.endPoint = CGPoint(x: 1, y: 0.5)
        scrollFadeMask.colors = [
            NSColor.clear.cgColor,
            NSColor.black.cgColor,
            NSColor.black.cgColor,
            NSColor.clear.cgColor,
        ]
        scrollFadeMask.locations = [0, 0.08, 0.92, 1]
    }

    private func updateScrollFadeMask() {
        guard isScrollable else {
            scrollView.layer?.mask = nil
            return
        }

        scrollFadeMask.frame = scrollView.bounds
        let visibleRect = scrollView.contentView.bounds
        let fadeWidth: CGFloat = 10
        let width = max(scrollView.bounds.width, 1)
        let fadeStop = min(0.5, fadeWidth / width)
        let leadingStop: CGFloat = visibleRect.minX <= 0.5 ? 0 : fadeStop
        let trailingStart: CGFloat = visibleRect.maxX >= tabsContainer.frame.width - 0.5 ? 1 : 1 - fadeStop
        scrollFadeMask.locations = [
            0,
            NSNumber(value: leadingStop),
            NSNumber(value: trailingStart),
            1,
        ]
        scrollView.layer?.mask = scrollFadeMask
    }

    override func layout() {
        super.layout()
        guard bounds.height > 0, !isLayoutingTabs else { return }
        isLayoutingTabs = true
        layoutTabs(animated: false)
        updateScrollability()
        refreshNavigationHoverStates()
        updateScrollFadeMask()
        isLayoutingTabs = false
    }
}

// MARK: - Hover Nav Button

private final class HoverNavButton: NSButton {
    private let hoverLayer = CALayer()
    private var trackingArea: NSTrackingArea?
    private var isPointerInside = false

    var keepsHoverVisible = false {
        didSet {
            updateHover()
        }
    }
    init(cornerRadius: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        hoverLayer.cornerRadius = cornerRadius
        hoverLayer.opacity = 0
        layer?.addSublayer(hoverLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func layout() {
        super.layout()
        hoverLayer.frame = bounds
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTrackingAreas()
        refreshHoverState()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
        refreshHoverState()
    }

    func refreshHoverState() {
        guard let window, !isHidden, bounds.width > 0, bounds.height > 0 else {
            if isPointerInside {
                isPointerInside = false
                updateHover()
            }
            return
        }

        let localPoint = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let isInside = bounds.contains(localPoint)
        guard isInside != isPointerInside else {
            updateHover()
            return
        }
        isPointerInside = isInside
        updateHover()
    }

    func resetHover() {
        isPointerInside = false
        updateHover()
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        updateHover()
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        updateHover()
    }

    private func updateHover() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        if isPointerInside || keepsHoverVisible {
            NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
                let isDark = NSAppearance.currentDrawing().isDarkMode
                hoverLayer.backgroundColor = isDark
                    ? NSColor.white.withAlphaComponent(0.12).cgColor
                    : NSColor.controlColor.withAlphaComponent(0.8).cgColor
                hoverLayer.opacity = 1
            }
        } else {
            hoverLayer.opacity = 0
        }
    }
}

// MARK: - TabButtonView

final class TabButtonView: NSView {

    private var tab: DatabaseTab
    private var isSelected: Bool
    private var databaseType: DatabaseType
    private var onClose: () -> Void

    private var tabShapeLayer: CAShapeLayer!
    private var hoverBackgroundLayer: CALayer!

    private var iconView: NSImageView!
    private var titleLabel: NSTextField!
    private var deviationLabel: NSTextField!
    private var closeButton: NSButton!

    private var isHovering = false
    private var trackingArea: NSTrackingArea?
    private let selectedShapeExtraHeight: CGFloat = 1.5
    private var tabCornerRadius: CGFloat {
        if #available(macOS 26, *) { 12 } else { 10 }
    }

    init(tab: DatabaseTab, isSelected: Bool, databaseType: DatabaseType, onClose: @escaping () -> Void) {
        self.tab = tab
        self.isSelected = isSelected
        self.databaseType = databaseType
        self.onClose = onClose
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        setupSubviews()
        updateVisuals()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if !closeButton.isHidden {
            let closeLocal = closeButton.convert(point, from: superview)
            if closeButton.bounds.contains(closeLocal) {
                return closeButton
            }
        }
        if bounds.contains(local) {
            return self
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        superview?.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        superview?.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        superview?.mouseUp(with: event)
    }

    func update(tab: DatabaseTab, isSelected: Bool, databaseType: DatabaseType) {
        let needsVisualUpdate = self.isSelected != isSelected
            || self.tab.name != tab.name
            || self.tab.hasSchemaDeviation != tab.hasSchemaDeviation

        self.tab = tab
        self.isSelected = isSelected
        self.databaseType = databaseType

        if needsVisualUpdate {
            updateVisuals()
        }
    }

    func updateAppearance() {
        updateVisuals()
    }

    // MARK: - Setup

    private func setupSubviews() {
        tabShapeLayer = CAShapeLayer()
        tabShapeLayer.masksToBounds = false
        layer?.addSublayer(tabShapeLayer)

        hoverBackgroundLayer = CALayer()
        hoverBackgroundLayer.cornerRadius = tabCornerRadius
        hoverBackgroundLayer.opacity = 0
        hoverBackgroundLayer.shadowColor = NSColor.black.cgColor
        hoverBackgroundLayer.shadowOpacity = 0.10
        hoverBackgroundLayer.shadowRadius = 1
        hoverBackgroundLayer.shadowOffset = .zero
        layer?.addSublayer(hoverBackgroundLayer)

        iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = .secondaryLabelColor
        iconView.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        addSubview(iconView)

        titleLabel = NSTextField(labelWithString: "")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.maximumNumberOfLines = 1
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        titleLabel.cell?.truncatesLastVisibleLine = true
        addSubview(titleLabel)

        deviationLabel = NSTextField(labelWithString: "*")
        deviationLabel.translatesAutoresizingMaskIntoConstraints = false
        deviationLabel.font = .systemFont(ofSize: 14, weight: .bold)
        deviationLabel.isHidden = true
        addSubview(deviationLabel)

        closeButton = NSButton(frame: .zero)
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")
        closeButton.imagePosition = .imageOnly
        closeButton.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        closeButton.target = self
        closeButton.action = #selector(closeAction)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.isHidden = true
        closeButton.wantsLayer = true
        closeButton.layer?.cornerRadius = 6
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -2),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -4),

            deviationLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 1),
            deviationLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            closeButton.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 22),
            closeButton.heightAnchor.constraint(equalToConstant: 18),
        ])
    }

    // MARK: - Visuals

    private func updateVisuals() {
        let iconName = getTabIconName(for: tab, databaseType: databaseType)
        iconView.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
        titleLabel.stringValue = tab.name
        deviationLabel.isHidden = !tab.hasSchemaDeviation

        updateColors()
        needsLayout = true
    }

    private func updateColors() {
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            let isDark = NSAppearance.currentDrawing().isDarkMode

            if isSelected {
                tabShapeLayer.fillColor = isDark
                    ? NSColor.black.withAlphaComponent(0.30).cgColor
                    : NSColor.controlBackgroundColor.withAlphaComponent(0.86).cgColor
                if isDark {
                    tabShapeLayer.shadowOpacity = 0
                } else {
                    tabShapeLayer.shadowColor = NSColor(white: 0, alpha: 1).cgColor
                    tabShapeLayer.shadowOpacity = 0.10
                    tabShapeLayer.shadowRadius = 1
                    tabShapeLayer.shadowOffset = .zero
                }
            } else {
                tabShapeLayer.fillColor = NSColor.clear.cgColor
                tabShapeLayer.shadowOpacity = 0
            }

            hoverBackgroundLayer.backgroundColor = isDark
                ? NSColor.white.withAlphaComponent(0.12).cgColor
                : NSColor.controlColor.withAlphaComponent(0.8).cgColor
            hoverBackgroundLayer.opacity = (isHovering && !isSelected) ? 1 : 0
        }
    }

    override func layout() {
        super.layout()

        let rect = selectedShapeRect
        tabShapeLayer.frame = rect
        if isSelected {
            tabShapeLayer.path = makeTabShapePath(in: tabShapeLayer.bounds)

            let shadowPadding: CGFloat = 10
            let maskLayer = CAShapeLayer()
            maskLayer.path = CGPath(rect: CGRect(
                x: -shadowPadding,
                y: 0,
                width: rect.width + shadowPadding * 2,
                height: rect.height + shadowPadding
            ), transform: nil)
            layer?.mask = maskLayer
        } else {
            tabShapeLayer.path = nil
            layer?.mask = nil
        }

        hoverBackgroundLayer.frame = NSRect(
            x: 0,
            y: 4,
            width: rect.width,
            height: rect.height - 4
        )
    }

    private var selectedShapeRect: CGRect {
        CGRect(
            x: 0,
            y: 0,
            width: bounds.width,
            height: bounds.height + (isSelected ? selectedShapeExtraHeight : 0)
        )
    }

    private func makeTabShapePath(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let radius = tabCornerRadius
        let curveRadius = if #available(macOS 26, *) { tabCornerRadius + 3 } else { tabCornerRadius }
        let flare = curveRadius
        let handle = flare * 0.55
        let h = rect.height

        path.move(to: CGPoint(x: -flare, y: 0))
        path.addCurve(
            to: CGPoint(x: 0, y: flare),
            control1: CGPoint(x: -flare * 0.35, y: 0),
            control2: CGPoint(x: 0, y: flare - handle)
        )
        path.addLine(to: CGPoint(x: 0, y: h - radius))
        path.addQuadCurve(to: CGPoint(x: radius, y: h), control: CGPoint(x: 0, y: h))
        path.addLine(to: CGPoint(x: rect.width - radius, y: h))
        path.addQuadCurve(to: CGPoint(x: rect.width, y: h - radius), control: CGPoint(x: rect.width, y: h))
        path.addLine(to: CGPoint(x: rect.width, y: flare))
        path.addCurve(
            to: CGPoint(x: rect.width + flare, y: 0),
            control1: CGPoint(x: rect.width, y: flare - handle),
            control2: CGPoint(x: rect.width + flare * 0.35, y: 0)
        )
        path.addLine(to: CGPoint(x: -flare, y: 0))

        return path
    }

    // MARK: - Hover Tracking

    private var isCloseButtonHovering = false

    var isDragActive = false {
        didSet {
            if isDragActive {
                isHovering = false
                isCloseButtonHovering = false
                closeButton.isHidden = true
                closeButton.layer?.backgroundColor = NSColor.clear.cgColor
                hoverBackgroundLayer.opacity = 0
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp],
            owner: self,
            userInfo: nil
        )
        if let trackingArea {
            addTrackingArea(trackingArea)
        }

        if let window, isHovering {
            let mouseInWindow = window.mouseLocationOutsideOfEventStream
            let localPoint = convert(mouseInWindow, from: nil)
            if !bounds.contains(localPoint) {
                isHovering = false
                closeButton.isHidden = true
                closeButton.layer?.backgroundColor = NSColor.clear.cgColor
                hoverBackgroundLayer.opacity = 0
            }
        }
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard !isDragActive else { return }
        isHovering = true
        closeButton.isHidden = false

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            if !isSelected {
                hoverBackgroundLayer.opacity = 1
            }
        }

        updateCloseButtonHover(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard !isDragActive else { return }
        updateCloseButtonHover(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovering = false
        isCloseButtonHovering = false
        closeButton.isHidden = true
        closeButton.layer?.backgroundColor = NSColor.clear.cgColor

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            hoverBackgroundLayer.opacity = 0
        }
    }

    private func updateCloseButtonHover(with event: NSEvent) {
        let locationInSelf = convert(event.locationInWindow, from: nil)
        let locationInClose = closeButton.convert(locationInSelf, from: self)
        let isOver = closeButton.bounds.contains(locationInClose) && !closeButton.isHidden

        guard isOver != isCloseButtonHovering else { return }
        isCloseButtonHovering = isOver

        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            let isDark = NSAppearance.currentDrawing().isDarkMode
            closeButton.layer?.backgroundColor = isOver
                ? (isDark ? NSColor.white.withAlphaComponent(0.3).cgColor : NSColor.secondarySystemFill.cgColor)
                : NSColor.clear.cgColor
        }
    }

    @objc private func closeAction() {
        onClose()
    }
}

// MARK: - Non-Dragging Scroll View

private class NonDraggingScrollView: NSScrollView {
    override var mouseDownCanMoveWindow: Bool { false }

    override func scrollWheel(with event: NSEvent) {
        guard let cgEvent = event.cgEvent?.copy() else { return }
        cgEvent.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: 0)
        if event.hasPreciseScrollingDeltas {
            cgEvent.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0)
        }
        guard let cleaned = NSEvent(cgEvent: cgEvent) else { return }
        super.scrollWheel(with: cleaned)
    }
}

private class NonDraggingClipView: NSClipView {
    override var mouseDownCanMoveWindow: Bool { false }
}

private class NonDraggingView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
}
