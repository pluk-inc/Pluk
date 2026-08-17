import AppKit
import SwiftUI

class TabContentView: NSView {
    let tab: DatabaseTab
    let databaseType: DatabaseType
    let environmentInjector: ((AnyView) -> AnyView)?
    weak var instance: ConnectionInstance?
    private var contentView: NSView?
    private var canvasViewController: CanvasViewController?

    init(tab: DatabaseTab, databaseType: DatabaseType, environmentInjector: ((AnyView) -> AnyView)? = nil, instance: ConnectionInstance? = nil) {
        self.tab = tab
        self.databaseType = databaseType
        self.environmentInjector = environmentInjector
        self.instance = instance
        super.init(frame: .zero)
        setupView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func applyEnvironments(_ view: some View) -> AnyView {
        guard let injector = environmentInjector else { return AnyView(view) }
        return injector(AnyView(view))
    }

    private func setupView() {
        wantsLayer = true

        layer?.cornerRadius = 10

        if tab.type == .canvas {
            setupCanvasView()
            return
        }

        switch databaseType {
        case .postgres, .sqlite, .mysql, .convex:
            setupTableView()

        case .mongodb:
            setupMongoDBView()

        case .redis:
            setupRedisView()

        default:
            setupDefaultView()
        }
    }

    private func setupCanvasView() {
        guard let instance else {
            setupDefaultView()
            return
        }
        let vc = CanvasViewController(instance: instance)
        canvasViewController = vc
        vc.loadView()
        setContentView(vc.view)
        vc.viewDidAppear()
    }

    private func setupTableView() {
        let rootView: AnyView

        switch tab.type {
        case .sqlEditor:
            rootView = applyEnvironments(SQLEditorView())
        case .functionEditor:
            rootView = applyEnvironments(FunctionEditorView())
        case .canvas:
            return
        case .browse, .aggregate, .schema, .indexes, .redisKey, .redisCommand:
            // SQL .browse/.aggregate/.schema/.indexes tabs are routed to
            // TableContentViewController (AppKit) in
            // DocumentViewController.makeTabContentView and never reach here.
            setupDefaultView()
            return
        }

        setContentView(NSHostingView(rootView: rootView))
    }

    private func setupMongoDBView() {
        let rootView = applyEnvironments(DocumentList(selectedTab: tab))
        setContentView(NSHostingView(rootView: rootView))
    }

    private func setupRedisView() {
        switch tab.type {
        case .redisKey:
            setContentView(NSHostingView(rootView: applyEnvironments(RedisKeyDetailView(tab: tab))))
        case .redisCommand:
            setContentView(NSHostingView(rootView: applyEnvironments(RedisCommandEditorView(tab: tab))))
        default:
            setupDefaultView()
        }
    }

    private func setupDefaultView() {
        let noSelectionView = NSView()
        let label = NSTextField(
            labelWithString: databaseType == .redis ? "No key selected" : "No collection selected"
        )
        label.font = NSFont.systemFont(ofSize: 18, weight: .medium)
        label.textColor = NSColor.secondaryLabelColor
        label.alignment = .center

        noSelectionView.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: noSelectionView.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: noSelectionView.centerYAnchor)
        ])

        setContentView(noSelectionView)
    }

    private func setContentView(_ view: NSView) {
        contentView?.removeFromSuperview()
        contentView = view
        addSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: topAnchor),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
}
