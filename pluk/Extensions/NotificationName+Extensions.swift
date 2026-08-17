import Foundation

extension Notification.Name {
    static let redisKeysRefreshRequested = Notification.Name("redisKeysRefreshRequested")
    static let didRequestDelete = Notification.Name("didRequestDelete")
    static let didRequestCopy = Notification.Name("didRequestCopy")
    static let didRequestPaste = Notification.Name("didRequestPaste")
    static let markRowAsDeleted = Notification.Name("markRowAsDeleted")
    static let foreignKeyNavigationRequested = Notification.Name("ForeignKeyNavigationRequested")
    
    /// Table refresh naming
    static let tableRefresh = Notification.Name("tableRefresh")
    static let addNewRecord = Notification.Name("addNewRecord")
    
    /// Request an NSTableView-level reload without refetching data
    static let tableReloadData = Notification.Name("tableReloadData")

    /// Toggle the left sidebar in the main split view
    static let toggleLeftSidebar = Notification.Name("ToggleLeftSidebar")

    /// Toggle the right sidebar (row details)
    static let toggleRightSidebar = Notification.Name("ToggleRightSidebar")

    /// Tab change notification
    static let tabDidChange = Notification.Name("tabDidChange")

    /// Connection database updates
    static let databasesUpdated = Notification.Name("databasesUpdated")
    static let connectedDatabaseChanged = Notification.Name("connectedDatabaseChanged")
    static let switchDatabaseShortcut = Notification.Name("SwitchDatabaseShortcut")
    static let toggleFilterBuilder = Notification.Name("ToggleFilterBuilder")
    static let filterBuilderDidClose = Notification.Name("FilterBuilderDidClose")

    /// Schema mode context menu actions
    static let schemaTableRefresh = Notification.Name("schemaTableRefresh")
    static let schemaAddColumn = Notification.Name("schemaAddColumn")
    static let indexTableRefresh = Notification.Name("indexTableRefresh")
    static let indexAddIndex = Notification.Name("indexAddIndex")

    /// Quick Look popover
    static let cellQuickLookRequested = Notification.Name("cellQuickLookRequested")

    /// App appearance changed (posted by AppDelegate KVO, hierarchy-independent)
    static let appAppearanceDidChange = Notification.Name("appAppearanceDidChange")

    /// Sidebar animation lifecycle (for performance optimization)
    static let sidebarAnimationWillStart = Notification.Name("SidebarAnimationWillStart")
    static let sidebarAnimationDidEnd = Notification.Name("SidebarAnimationDidEnd")

    /// Notebook chart freeze/unfreeze during sidebar animations
    static let notebookChartFreeze = Notification.Name("NotebookChartFreeze")
    static let notebookChartUnfreeze = Notification.Name("NotebookChartUnfreeze")

    /// Sidebar visibility changed (userInfo contains "isVisible": Bool)
    static let sidebarVisibilityChanged = Notification.Name("SidebarVisibilityChanged")

    /// Sidebar item registry changed (connection/notebook added or removed)
    static let sidebarItemsDidChange = Notification.Name("SidebarItemsDidChange")

    /// Notebook block hover (userInfo: "blockIndex": Int, "isHovered": Bool)
    static let notebookBlockHoverChanged = Notification.Name("NotebookBlockHoverChanged")

    /// Auth + billing deep-link callbacks
    static let workOSAuthCallback = Notification.Name("WorkOSAuthCallback")
    static let billingCallbackReceived = Notification.Name("BillingCallbackReceived")
    static let convexOAuthCallback = Notification.Name("ConvexOAuthCallback")
}
