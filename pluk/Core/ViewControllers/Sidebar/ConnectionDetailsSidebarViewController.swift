import AppKit
import Observation
import SwiftData
import SwiftUI

/// AppKit-native replacement for the SwiftUI `ConnectionDetailsSidebar` shell.
/// Owns the vertical layout (connection header, database controls, scroll
/// content, pro promo overlay) as real NSViews so `DatabaseListViewController`
/// can embed its NSScrollView directly — no more representable sizing
/// feedback loops.
@MainActor
final class ConnectionDetailsSidebarViewController: NSViewController {

    // MARK: - Dependencies

    private let instance: ConnectionInstance
    private let viewModel: SidebarViewModel
    private let tabManager: TabManager
    private let appViewModel: AppViewModel
    private let modelContainer: ModelContainer

    private let collectionLoader = SidebarCollectionLoadCoordinator()

    // MARK: - Views

    private var nameHeaderView: ConnectionNameHeaderView!
    private var controlsRowHost: NSHostingView<AnyView>!
    private var searchInputHost: NSHostingView<AnyView>!
    private var softSeparatorHost: NSHostingView<AnyView>!
    private var contentContainer: NSView!
    private var promoCardHost: NSHostingView<AnyView>?
    private var currentContent: NSView?
    private var listViewController: DatabaseListViewController?
    private var redisListViewController: RedisKeyListViewController?
    private var historyViewController: QueryHistoryListViewController?

    // MARK: - State

    private var userDismissedDatabaseSelector = false
    private var isPresentingDatabaseSelector = false
    private var connectTaskStarted = false
    private var searchInputHeightConstraint: NSLayoutConstraint!
    private var isSidebarHovered = false

    // MARK: - Init

    init(
        instance: ConnectionInstance,
        viewModel: SidebarViewModel,
        tabManager: TabManager,
        appViewModel: AppViewModel,
        modelContainer: ModelContainer
    ) {
        self.instance = instance
        self.viewModel = viewModel
        self.tabManager = tabManager
        self.appViewModel = appViewModel
        self.modelContainer = modelContainer
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - View Lifecycle

    override func loadView() {
        let root = FlexibleContainerView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.setContentHuggingPriority(.defaultLow, for: .horizontal)
        root.setContentHuggingPriority(.defaultLow, for: .vertical)
        root.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        root.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        root.onHoverChanged = { [weak self] hovered in
            self?.setSidebarHovered(hovered)
        }

        nameHeaderView = ConnectionNameHeaderView(instance: instance, viewModel: viewModel)

        controlsRowHost = NSHostingView(rootView: AnyView(makeControlsRow()))
        controlsRowHost.translatesAutoresizingMaskIntoConstraints = false
        applyFlexibleSizing(to: controlsRowHost)

        searchInputHost = NSHostingView(rootView: AnyView(makeSearchInput()))
        searchInputHost.translatesAutoresizingMaskIntoConstraints = false
        applyFlexibleSizing(to: searchInputHost)

        softSeparatorHost = NSHostingView(rootView: AnyView(SoftSeparator()))
        softSeparatorHost.translatesAutoresizingMaskIntoConstraints = false
        softSeparatorHost.alphaValue = 0  // Fades in only when scrolled.
        applyFlexibleSizing(to: softSeparatorHost)

        contentContainer = NSView()
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.wantsLayer = true

        root.addSubview(nameHeaderView)
        root.addSubview(controlsRowHost)
        root.addSubview(searchInputHost)
        root.addSubview(softSeparatorHost)
        root.addSubview(contentContainer)

        searchInputHeightConstraint = searchInputHost.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            nameHeaderView.topAnchor.constraint(equalTo: root.topAnchor, constant: 4),
            nameHeaderView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            nameHeaderView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4),
            nameHeaderView.heightAnchor.constraint(equalToConstant: 56),

            controlsRowHost.topAnchor.constraint(equalTo: nameHeaderView.bottomAnchor),
            controlsRowHost.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            controlsRowHost.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4),

            searchInputHost.topAnchor.constraint(equalTo: controlsRowHost.bottomAnchor),
            searchInputHost.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            searchInputHost.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4),
            searchInputHeightConstraint,

            softSeparatorHost.topAnchor.constraint(equalTo: searchInputHost.bottomAnchor),
            softSeparatorHost.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            softSeparatorHost.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4),
            softSeparatorHost.heightAnchor.constraint(equalToConstant: 1),

            contentContainer.topAnchor.constraint(equalTo: softSeparatorHost.bottomAnchor, constant: 4),
            contentContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            // Extend the scroll area to the sidebar edge so the overlay
            // scroller can float in the extra 4pt gap. Row width is preserved
            // via `scrollView.contentInsets.right` in DatabaseListViewController.
            contentContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
        ])

        self.view = root

        refreshContent()
        refreshPromoCard()
        refreshSearchInput()
        startObserving()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        startConnectIfNeeded()
    }

    // MARK: - SwiftUI Content Factories

    private func makeControlsRow() -> some View {
        DatabaseControlsRow(
            viewModel: viewModel,
            collectionLoader: collectionLoader,
            isSidebarHovered: isSidebarHovered
        )
        .environment(instance)
        .environment(viewModel)
        .environment(\.currentDatabaseType, instance.connection.databaseType)
        .modelContainer(modelContainer)
    }

    private func setSidebarHovered(_ hovered: Bool) {
        guard hovered != isSidebarHovered else { return }
        isSidebarHovered = hovered
        // Re-render the hosted controls so DatabaseHeader's refresh button
        // can fade in / out with hover state.
        controlsRowHost.rootView = AnyView(makeControlsRow())
        listViewController?.setSidebarHovered(hovered)
        redisListViewController?.setSidebarHovered(hovered)
    }

    private func makeSearchInput() -> some View {
        SearchInput(viewModel: viewModel)
            .padding(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 2))
            .environment(viewModel)
            .modelContainer(modelContainer)
    }

    private func makePromoCard() -> some View {
        SidebarProPromoCardView(
            databaseType: instance.connection.databaseType,
            sidebarViewModeAnalyticsValue: viewModel.sidebarViewMode == .tables ? "tables" : "history",
            onDismissed: { [weak self] in
                self?.refreshPromoCard()
            }
        )
        .padding(.trailing, 2)
        .padding(.bottom, 8)
        .environment(instance)
    }

    // MARK: - Content Switching

    private func refreshContent() {
        currentContent?.removeFromSuperview()
        listViewController?.removeFromParent()
        listViewController = nil
        redisListViewController?.removeFromParent()
        redisListViewController = nil
        historyViewController?.removeFromParent()
        historyViewController = nil

        let newContent: NSView
        switch viewModel.sidebarViewMode {
        case .tables:
            if instance.connection.databaseType.supportsKeyValueBrowser {
                let listVC = RedisKeyListViewController(instance: instance, viewModel: viewModel)
                listVC.onScrolledFromTopChanged = { [weak self] scrolled in
                    self?.setSeparatorVisible(scrolled)
                }
                redisListViewController = listVC
                addChild(listVC)
                newContent = listVC.view
            } else {
                let listVC = DatabaseListViewController(instance: instance, viewModel: viewModel)
                listVC.onScrolledFromTopChanged = { [weak self] scrolled in
                    self?.setSeparatorVisible(scrolled)
                }
                listViewController = listVC
                addChild(listVC)
                newContent = listVC.view
            }
        case .history:
            // History mode doesn't have scroll-edge tracking wired up; keep
            // the separator hidden to match previous behaviour.
            setSeparatorVisible(false)
            let historyVC = QueryHistoryListViewController(instance: instance)
            historyViewController = historyVC
            addChild(historyVC)
            newContent = historyVC.view
        }

        // Apply the current promo-aware inset immediately so the first
        // render has rows clearing the card.
        Task { @MainActor [weak self] in
            self?.updateListBottomInset()
        }

        newContent.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(newContent)
        NSLayoutConstraint.activate([
            newContent.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            newContent.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            newContent.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            newContent.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
        currentContent = newContent
    }

    private func setSeparatorVisible(_ visible: Bool) {
        let target: CGFloat = visible ? 1 : 0
        guard softSeparatorHost.alphaValue != target else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            softSeparatorHost.animator().alphaValue = target
        }
    }

    private func refreshSearchInput() {
        let isVisible = viewModel.isSearchVisible && viewModel.sidebarViewMode == .tables
        searchInputHost.isHidden = !isVisible
        searchInputHeightConstraint.constant = isVisible ? 40 : 0
        // Rebuild hosted content so bindings pick up state changes.
        searchInputHost.rootView = AnyView(makeSearchInput())
    }

    private func refreshPromoCard() {
        let shouldShow = shouldShowProPromoNow()
        if shouldShow {
            if promoCardHost == nil {
                let host = NSHostingView(rootView: AnyView(makePromoCard()))
                host.translatesAutoresizingMaskIntoConstraints = false
                view.addSubview(host)
                NSLayoutConstraint.activate([
                    host.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
                    host.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
                    host.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
                ])
                promoCardHost = host
            } else {
                promoCardHost?.rootView = AnyView(makePromoCard())
            }
        } else {
            promoCardHost?.removeFromSuperview()
            promoCardHost = nil
        }
        updateListBottomInset()
    }

    /// Mirrors the SwiftUI original's `.padding(.bottom, shouldShowProPromo ?
    /// promoCardHeight + 16 : 12)` on the list content so the last rows never
    /// sit under the promo overlay.
    private func updateListBottomInset() {
        let inset: CGFloat
        if let host = promoCardHost {
            host.layoutSubtreeIfNeeded()
            inset = host.fittingSize.height + 16
        } else {
            inset = 12
        }
        listViewController?.setBottomContentInset(inset)
        redisListViewController?.setBottomContentInset(inset)
        historyViewController?.setBottomContentInset(inset)
    }

    private func shouldShowProPromoNow() -> Bool {
        let dismissedAt = UserDefaults.standard.double(forKey: "sidebarProPromoDismissedAt")
        if dismissedAt > 0 {
            let elapsed = Date().timeIntervalSince1970 - dismissedAt
            let cooldown: TimeInterval = 30 * 24 * 60 * 60
            if elapsed < cooldown { return false }
        }
        let auth = WorkOSAuthService.shared
        guard !auth.isPro else { return false }
        if auth.isAuthenticated {
            return auth.hasLoadedSubscriptionStatus
        }
        return true
    }

    // MARK: - Connect on Appear

    private func startConnectIfNeeded() {
        guard !connectTaskStarted else { return }
        connectTaskStarted = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.viewModel.activeConnection?.connect()
            } catch {
                // Connection errors surface through instance.lastError.
            }
        }
    }

    // MARK: - Observation

    private func startObserving() {
        observeSidebarViewMode()
        observeSearchVisibility()
        observePromoState()
        observeReadiness()
    }

    private func observeSidebarViewMode() {
        withObservationTracking {
            _ = self.viewModel.sidebarViewMode
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refreshContent()
                self?.refreshSearchInput()
                self?.observeSidebarViewMode()
            }
        }
    }

    private func observeSearchVisibility() {
        withObservationTracking {
            _ = self.viewModel.isSearchVisible
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refreshSearchInput()
                self?.observeSearchVisibility()
            }
        }
    }

    private func observePromoState() {
        let auth = WorkOSAuthService.shared
        withObservationTracking {
            _ = auth.isPro
            _ = auth.isAuthenticated
            _ = auth.hasLoadedSubscriptionStatus
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refreshPromoCard()
                self?.observePromoState()
            }
        }
    }

    private func observeReadiness() {
        withObservationTracking {
            _ = self.instance.readiness
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.handleReadinessChange()
                self.observeReadiness()
            }
        }
    }

    private func handleReadinessChange() {
        if case .ready = instance.readiness {
            redisListViewController?.connectionDidBecomeReady()
        }

        if case .needsDatabaseSelection = instance.readiness {
            if !isPresentingDatabaseSelector, !userDismissedDatabaseSelector {
                presentDatabaseSelector()
            }
        } else {
            // Leaving .needsDatabaseSelection — reset dismissal flag.
            userDismissedDatabaseSelector = false
            if isPresentingDatabaseSelector, let presented = presentedViewControllers?.first {
                dismiss(presented)
                isPresentingDatabaseSelector = false
            }
        }
    }

    // MARK: - Database Selector Sheet

    private func presentDatabaseSelector() {
        let modal = DatabaseSelectorModal(
            databaseService: instance.databaseService,
            databaseType: instance.databaseType,
            onSelection: { [weak self] database in
                guard let self else { return }
                self.collectionLoader.start {
                    await self.selectDatabase(database)
                }
            },
            onCreateNew: { [weak self] in
                self?.userDismissedDatabaseSelector = true
            },
            onCancel: { [weak self] in
                guard let self, let presented = self.presentedViewControllers?.first else { return }
                self.dismiss(presented)
            }
        )
        .environment(instance)

        let host = NSHostingController(rootView: AnyView(modal))
        host.view.frame = NSRect(x: 0, y: 0, width: 450, height: 560)
        isPresentingDatabaseSelector = true
        presentAsSheet(host)
    }

    override func dismiss(_ viewController: NSViewController) {
        super.dismiss(viewController)
        if isPresentingDatabaseSelector {
            isPresentingDatabaseSelector = false
            if case .needsDatabaseSelection = instance.readiness {
                userDismissedDatabaseSelector = true
            }
        }
    }

    @MainActor
    private func selectDatabase(_ database: any DatabaseWrapper) async {
        do {
            try await instance.databaseService.switchActiveDatabase(to: database)
            try await instance.loadCollectionsForCurrentDatabase(
                schema: instance.databaseService.currentSchema
            )
        } catch is CancellationError {
            return
        } catch {
            debugLog("Failed to select database: \(error)")
        }
    }
}

// MARK: - Controls Row (SwiftUI leaf)

/// Matches the original `HStack(spacing: 4) { DatabaseHeader + SidebarViewModeToggle }`
/// row. Stays SwiftUI because `DatabaseHeader` contains the existing
/// `MinimalDropdown` popover chain — porting that is a separate pass.
private struct DatabaseControlsRow: View {
    @Environment(ConnectionInstance.self) private var instance
    let viewModel: SidebarViewModel
    let collectionLoader: SidebarCollectionLoadCoordinator
    let isSidebarHovered: Bool

    var body: some View {
        HStack(spacing: 4) {
            DatabaseHeader(
                viewModel: viewModel,
                isSidebarHovered: isSidebarHovered,
                isLoadingCollections: collectionLoader.isLoading,
                collectionLoader: collectionLoader
            )

            SidebarViewModeToggle(
                viewMode: Binding(
                    get: { viewModel.sidebarViewMode },
                    set: { viewModel.sidebarViewMode = $0 }
                ),
                showAdvancedHistory: Binding(
                    get: { viewModel.isShowingAdvancedHistory },
                    set: { viewModel.isShowingAdvancedHistory = $0 }
                ),
                databaseType: instance.databaseType
            )
        }
        .padding(.leading, 4)
        .padding(.trailing, 2)
        .padding(.bottom, 4)
    }
}

// MARK: - Pro Promo Card Wrapper

private struct SidebarProPromoCardView: View {
    let databaseType: DatabaseType
    let sidebarViewModeAnalyticsValue: String
    let onDismissed: () -> Void

    var body: some View {
        SidebarProPromoCardBody(
            onUpgrade: {
                AnalyticsService.shared.trackSidebarProPromo(
                    action: "cta_clicked",
                    databaseType: databaseType,
                    sidebarViewMode: sidebarViewModeAnalyticsValue
                )
                Paywall.present(source: "sidebar_promo")
            },
            onDismiss: {
                AnalyticsService.shared.trackSidebarProPromo(
                    action: "dismissed",
                    databaseType: databaseType,
                    sidebarViewMode: sidebarViewModeAnalyticsValue
                )
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "sidebarProPromoDismissedAt")
                onDismissed()
            },
            onAppear: {
                AnalyticsService.shared.trackSidebarProPromo(
                    action: "viewed",
                    databaseType: databaseType,
                    sidebarViewMode: sidebarViewModeAnalyticsValue
                )
            }
        )
    }
}

private struct SidebarProPromoCardBody: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var isDismissHovering = false
    @State private var isCardHovering = false
    let onUpgrade: () -> Void
    let onDismiss: () -> Void
    let onAppear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Text("Try Pluk Pro for free")
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 4)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(isDismissHovering ? .primary : .secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(.rect)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color(.separatorColor).opacity(isDismissHovering ? 0.5 : 0))
                        )
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    withAnimation(.easeOut(duration: 0.08)) { isDismissHovering = hovering }
                }
            }

            Text("Unlimited connections, expanded AI, and priority support.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)

            HStack {
                Spacer(minLength: 0)
                Image(systemName: "arrow.right")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                    .offset(x: isCardHovering ? 2 : 0)
            }
            .padding(.top, 6)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .onTapGesture { onUpgrade() }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.controlBackgroundColor).opacity(0.98))
                .shadow(color: .black.opacity(0.10), radius: 1, y: 0.5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    colorScheme == .dark
                        ? Color.white.opacity(0.06)
                        : Color.black.opacity(0.08),
                    lineWidth: 0.5
                )
        )
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isCardHovering = hovering }
        }
        .onAppear(perform: onAppear)
    }
}

// MARK: - Flexible Container

/// Root NSView for the sidebar that reports no intrinsic or fitting size, so
/// NSSplitView can freely resize it as the user drags the divider. Without
/// this, the sum of SwiftUI-hosted children's intrinsic widths becomes the
/// split view's notion of "ideal sidebar width" and the divider snaps back
/// when the user tries to expand past it.
@MainActor
private final class FlexibleContainerView: NSView {
    var onHoverChanged: ((Bool) -> Void)?

    private var trackingArea: NSTrackingArea?

    override var fittingSize: NSSize { .zero }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

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
    }

    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }
}

@MainActor
private func applyFlexibleSizing(to view: NSView) {
    view.setContentHuggingPriority(.defaultLow, for: .horizontal)
    view.setContentHuggingPriority(.defaultLow, for: .vertical)
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
}
