import AppKit

@MainActor
func getTabIconName(for tab: DatabaseTab, databaseType: DatabaseType) -> String {
    guard tab.type != .functionEditor else { return "f.cursive" }
    guard tab.type != .sqlEditor else { return "terminal" }
    guard tab.type != .canvas else { return "rectangle.connected.to.line.below" }
    guard tab.type != .redisCommand else { return "terminal" }
    guard tab.type != .redisKey else { return "key.horizontal" }

    switch tab.viewMode {
    case .content:
        return databaseType == .mongodb ? "text.document" : "tablecells"
    case .schema:
        return "square.stack.3d.up"
    case .definition:
        return "ellipsis.curlybraces"
    }
}

extension Notification.Name {
    static let tabFramesNeedUpdate = Notification.Name("tabFramesNeedUpdate")
}

// MARK: - Draggable Tab NSView

class DraggableTabNSView: NSView, NSDraggingSource {
    var tabIndex: Int = 0
    var onReorder: ((Int, Int) -> Void)?
    var hostedView: NSView?
    var snapshotTitle: String = ""
    var snapshotIcon: String = "doc"
    var onDragBegin: (() -> Void)?
    var onDragPulledOut: ((Int, Int?) -> Void)?
    var onInsertionIndexChanged: ((Int?) -> Void)?
    var onDragEnded: ((Bool) -> Void)?
    var onSelect: (() -> Void)?
    private let dragThreshold: CGFloat = 3
    private var mouseDownLocation: NSPoint?
    private var trackingArea: NSTrackingArea?
    nonisolated(unsafe) private var frameUpdateObserver: NSObjectProtocol?

    private var isDragging = false
    private var hasBeenPulledOut = false
    private var initialDragScreenPosition: NSPoint = .zero
    private let pullOutThreshold: CGFloat = 12
    private var dragOffsetX: CGFloat = 0

    private static var dragWindow: NSPanel?
    private static var dragWindowYPosition: CGFloat = 0
    private static var currentInsertionIndex: Int?
    private static var currentDraggedIndex: Int?
    private static var tabFrames: [Int: NSRect] = [:]
    private static var scrollViewMinX: CGFloat = 0
    private static var scrollViewMaxX: CGFloat = CGFloat.greatestFiniteMagnitude
    private static var scrollView: NSScrollView?
    private static var autoScrollTimer: Timer?
    private static var autoScrollDirection: CGFloat = 0
    private static let autoScrollEdgeZone: CGFloat = 40
    private static let autoScrollSpeed: CGFloat = 8

    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: - Tracking Area

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        if let trackingArea {
            addTrackingArea(trackingArea)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        window?.isMovable = false
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        window?.isMovable = true
    }

    override func layout() {
        super.layout()
        updateStoredFrame()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateStoredFrame()

        if window != nil && frameUpdateObserver == nil {
            frameUpdateObserver = NotificationCenter.default.addObserver(
                forName: .tabFramesNeedUpdate,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { [weak self] in
                    self?.updateStoredFrame()
                }
            }
        } else if window == nil, let observer = frameUpdateObserver {
            NotificationCenter.default.removeObserver(observer)
            frameUpdateObserver = nil
        }
    }

    deinit {
        if let observer = frameUpdateObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func updateStoredFrame() {
        guard let window = window else { return }
        let frameInWindow = convert(bounds, to: nil)
        let screenFrame = window.convertToScreen(frameInWindow)
        Self.tabFrames[tabIndex] = screenFrame
    }

    private func findEnclosingScrollView() -> NSScrollView? {
        var current: NSView? = self
        while let view = current {
            if let scrollView = view as? NSScrollView {
                return scrollView
            }
            current = view.superview
        }
        return nil
    }

    private static func startAutoScroll(direction: CGFloat) {
        guard direction != 0, autoScrollDirection != direction else {
            return
        }
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
        autoScrollDirection = direction

        let timer = Timer(timeInterval: 0.016, repeats: true) { _ in
            MainActor.assumeIsolated {
                Self.handleAutoScrollTick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        autoScrollTimer = timer
    }

    @MainActor
    private static func handleAutoScrollTick() {
        guard let scrollView else {
            return
        }
        let clipView = scrollView.contentView
        var newOrigin = clipView.bounds.origin
        let oldX = newOrigin.x
        newOrigin.x += autoScrollSpeed * autoScrollDirection

        guard let documentView = scrollView.documentView else { return }
        let maxScrollX = max(0, documentView.frame.width - clipView.bounds.width)
        newOrigin.x = max(0, min(newOrigin.x, maxScrollX))

        guard abs(newOrigin.x - oldX) > 0.01 else { return }

        clipView.scroll(to: newOrigin)
        scrollView.reflectScrolledClipView(clipView)

        documentView.needsLayout = true
        documentView.layoutSubtreeIfNeeded()

        if let window = scrollView.window {
            let visibleRect = clipView.bounds
            let frameInWindow = clipView.convert(visibleRect, to: nil)
            let screenFrame = window.convertToScreen(frameInWindow)
            scrollViewMinX = screenFrame.minX
            scrollViewMaxX = screenFrame.maxX
        }

        NotificationCenter.default.post(name: .tabFramesNeedUpdate, object: nil)
    }

    private static func stopAutoScroll() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
        autoScrollDirection = 0
    }

    private static func updateAutoScroll(forScreenX screenX: CGFloat) {
        let leftEdge = scrollViewMinX + autoScrollEdgeZone
        let rightEdge = scrollViewMaxX - autoScrollEdgeZone

        if screenX < leftEdge {
            startAutoScroll(direction: -1)
        } else if screenX > rightEdge {
            startAutoScroll(direction: 1)
        } else {
            stopAutoScroll()
        }
    }

    private static func calculateInsertionIndex(forScreenX screenX: CGFloat) -> Int? {
        guard !tabFrames.isEmpty else { return nil }

        let sortedFrames = tabFrames.sorted { $0.value.minX < $1.value.minX }

        for (tabIndex, frame) in sortedFrames {
            let midX = frame.midX
            if screenX < midX {
                return tabIndex
            }
        }

        if let lastTab = sortedFrames.last {
            return lastTab.key + 1
        }

        return nil
    }

    // MARK: - Drag Source

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .move
    }

    func draggingSession(_ session: NSDraggingSession,
                         movedTo screenPoint: NSPoint) {
        let panelWidth: CGFloat = 182

        let desiredX = screenPoint.x - dragOffsetX
        let clampedX = max(Self.scrollViewMinX, min(desiredX, Self.scrollViewMaxX - panelWidth))

        Self.dragWindow?.setFrameOrigin(NSPoint(
            x: clampedX,
            y: Self.dragWindowYPosition
        ))

        Self.updateAutoScroll(forScreenX: screenPoint.x)

        if let insertionIndex = Self.calculateInsertionIndex(forScreenX: screenPoint.x) {
            if Self.currentInsertionIndex != insertionIndex {
                Self.currentInsertionIndex = insertionIndex
                onInsertionIndexChanged?(insertionIndex)
            }
        }
    }

    private func performHapticFeedback(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = event.locationInWindow
    }

    override func mouseUp(with event: NSEvent) {
        if !isDragging {
            onSelect?()
        }
        mouseDownLocation = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startLocation = mouseDownLocation else { return }

        let currentLocation = event.locationInWindow
        let distance = hypot(currentLocation.x - startLocation.x,
                            currentLocation.y - startLocation.y)

        if distance > dragThreshold && !isDragging {
            isDragging = true
            hasBeenPulledOut = false

            onDragBegin?()

            if let window = self.window {
                initialDragScreenPosition = window.convertPoint(toScreen: currentLocation)
                let frameInWindow = convert(bounds, to: nil)
                let tabScreenFrame = window.convertToScreen(frameInWindow)
                Self.dragWindowYPosition = tabScreenFrame.origin.y
                // +10 accounts for the tab shape curve overflow in the drag preview
                dragOffsetX = initialDragScreenPosition.x - tabScreenFrame.minX + 10
            }

            Self.currentDraggedIndex = tabIndex
            Self.currentInsertionIndex = nil

            if let scrollView = findEnclosingScrollView(), let window = scrollView.window {
                Self.scrollView = scrollView
                let clipView = scrollView.contentView
                let visibleRect = clipView.bounds
                let frameInWindow = clipView.convert(visibleRect, to: nil)
                let screenFrame = window.convertToScreen(frameInWindow)
                Self.scrollViewMinX = screenFrame.minX
                Self.scrollViewMaxX = screenFrame.maxX
            }

            trackMouseForDrag(initialEvent: event)
        }
    }

    private func trackMouseForDrag(initialEvent: NSEvent) {
        guard let window = self.window else { return }

        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .eventTracking) { event, stop in
            guard let event = event else { return }

            let screenPoint = window.convertPoint(toScreen: event.locationInWindow)

            if event.type == .leftMouseUp {
                Self.stopAutoScroll()
                Self.scrollView = nil

                if self.hasBeenPulledOut {
                    let insertionIndex = Self.calculateInsertionIndex(forScreenX: screenPoint.x)
                    let draggedIndex = Self.currentDraggedIndex

                    let willReorder = draggedIndex != nil
                        && insertionIndex != nil
                        && draggedIndex != insertionIndex
                        && draggedIndex! + 1 != insertionIndex!

                    CATransaction.begin()
                    CATransaction.setDisableActions(true)

                    Self.dragWindow?.orderOut(nil)
                    Self.dragWindow?.close()
                    Self.dragWindow = nil

                    self.onDragEnded?(willReorder)

                    if willReorder, let draggedIndex, let insertionIndex {
                        self.performHapticFeedback(.alignment)
                        self.onReorder?(draggedIndex, insertionIndex)
                    }

                    CATransaction.commit()
                } else {
                    Self.dragWindow?.orderOut(nil)
                    Self.dragWindow?.close()
                    Self.dragWindow = nil
                }

                Self.currentDraggedIndex = nil
                Self.currentInsertionIndex = nil

                self.isDragging = false
                self.hasBeenPulledOut = false
                self.mouseDownLocation = nil

                stop.pointee = true
            } else {
                if !self.hasBeenPulledOut {
                    let horizontalDistance = abs(screenPoint.x - self.initialDragScreenPosition.x)
                    if horizontalDistance > self.pullOutThreshold {
                        self.hasBeenPulledOut = true
                        self.performHapticFeedback(.levelChange)

                        let panel = self.createDragWindow()
                        panel.setFrameOrigin(NSPoint(x: screenPoint.x - self.dragOffsetX, y: Self.dragWindowYPosition))
                        Self.dragWindow = panel

                        let insertionIndex = Self.calculateInsertionIndex(forScreenX: screenPoint.x)
                        Self.currentInsertionIndex = insertionIndex

                        CATransaction.begin()
                        CATransaction.setDisableActions(true)
                        self.alphaValue = 0
                        self.onDragPulledOut?(self.tabIndex, insertionIndex)
                        panel.orderFront(nil)
                        CATransaction.commit()
                    }
                }

                if self.hasBeenPulledOut {
                    let panelWidth: CGFloat = 182
                    let desiredX = screenPoint.x - self.dragOffsetX
                    let clampedX = max(Self.scrollViewMinX, min(desiredX, Self.scrollViewMaxX - panelWidth))
                    Self.dragWindow?.setFrameOrigin(NSPoint(x: clampedX, y: Self.dragWindowYPosition))

                    Self.updateAutoScroll(forScreenX: screenPoint.x)

                    if let insertionIndex = Self.calculateInsertionIndex(forScreenX: screenPoint.x) {
                        if Self.currentInsertionIndex != insertionIndex {
                            Self.currentInsertionIndex = insertionIndex
                            self.performHapticFeedback(.alignment)
                            self.onInsertionIndexChanged?(insertionIndex)
                        }
                    }
                }
            }
        }
    }

    private func createDragWindow() -> NSPanel {
        guard let tabButtonView = hostedView else {
            return NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 182, height: 38),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
        }

        // The tab shape curves extend 10pt beyond bounds on each side
        let overflow: CGFloat = 10
        let size = tabButtonView.bounds.size
        let captureRect = NSRect(
            x: -overflow,
            y: 0,
            width: size.width + overflow * 2,
            height: size.height
        )
        let panelSize = captureRect.size

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hasShadow = false

        // Capture a bitmap snapshot including the tab shape overflow
        guard let bitmapRep = tabButtonView.bitmapImageRepForCachingDisplay(in: captureRect) else {
            return panel
        }
        tabButtonView.cacheDisplay(in: captureRect, to: bitmapRep)
        let image = NSImage(size: panelSize)
        image.addRepresentation(bitmapRep)

        let imageView = NSImageView(frame: NSRect(origin: .zero, size: panelSize))
        imageView.image = image
        imageView.imageScaling = .scaleNone
        panel.contentView = imageView

        return panel
    }

    // MARK: - Drop Destination (not used - we use custom mouse tracking)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .move }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .move }

    override func draggingExited(_ sender: NSDraggingInfo?) {}

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
}
