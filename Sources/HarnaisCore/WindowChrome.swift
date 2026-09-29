import AppKit
import SwiftUI

private struct TitlebarLeadingKey: EnvironmentKey {
    static let defaultValue: CGFloat = 84
}

private struct TitlebarHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 52
}

enum HarnaisChromeKind {
    /// Main window: no title, 52pt inset, traffic lights + name on one row.
    case window
    /// Sheet: native traffic lights, no title string (content already has one).
    case sheet
}

enum WindowChromeMetrics {
    /// T3 Code Electron `hiddenInset` trafficLightPosition — padding from the window's top-left.
    /// AppKit's corner sits tighter than Electron at 16×18, so these are nudged to match T3 visually.
    static let trafficLightX: CGFloat = 20
    static let titlebarHeight: CGFloat = 52
    static let titleGap: CGFloat = 12
}

extension EnvironmentValues {
    var titlebarLeading: CGFloat {
        get { self[TitlebarLeadingKey.self] }
        set { self[TitlebarLeadingKey.self] = newValue }
    }

    var titlebarHeight: CGFloat {
        get { self[TitlebarHeightKey.self] }
        set { self[TitlebarHeightKey.self] = newValue }
    }
}

struct WindowConfigurator: NSViewRepresentable {
    var title: String = "Harnais"
    var kind: HarnaisChromeKind = .window
    var titlebarLeading: Binding<CGFloat>?
    var titlebarHeight: Binding<CGFloat>?

    func makeCoordinator() -> Coordinator {
        Coordinator(titlebarLeading: titlebarLeading, titlebarHeight: titlebarHeight)
    }

    final class Coordinator {
        var titlebarLeading: Binding<CGFloat>?
        var titlebarHeight: Binding<CGFloat>?

        init(titlebarLeading: Binding<CGFloat>?, titlebarHeight: Binding<CGFloat>?) {
            self.titlebarLeading = titlebarLeading
            self.titlebarHeight = titlebarHeight
        }

        func report(leading: CGFloat, height: CGFloat) {
            if let titlebarLeading, abs(titlebarLeading.wrappedValue - leading) > 0.5 {
                titlebarLeading.wrappedValue = leading
            }
            if let titlebarHeight, abs(titlebarHeight.wrappedValue - height) > 0.5 {
                titlebarHeight.wrappedValue = height
            }
        }
    }

    func makeNSView(context: Context) -> TitlebarProbeView {
        let view = TitlebarProbeView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: TitlebarProbeView, context: Context) {
        context.coordinator.titlebarLeading = titlebarLeading
        context.coordinator.titlebarHeight = titlebarHeight
        nsView.coordinator = context.coordinator
        nsView.kind = kind
        nsView.titleText = title
        nsView.apply()
    }
}

final class TitlebarProbeView: NSView {
    weak var coordinator: WindowConfigurator.Coordinator?
    var kind: HarnaisChromeKind = .window
    var titleText = "Harnais"

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
    }

    override func layout() {
        super.layout()
        apply()
    }

    func apply() {
        guard let window else { return }
        window.appearance = nil
        window.backgroundColor = HarnaisPalette.sidebarNSColor
        window.isOpaque = true
        window.titlebarSeparatorStyle = .none
        if window.title != titleText {
            window.title = titleText
        }
        for type: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(type)?.isHidden = false
        }
        switch kind {
        case .window:
            if window.titleVisibility != .hidden {
                window.titleVisibility = .hidden
            }
            if !window.titlebarAppearsTransparent {
                window.titlebarAppearsTransparent = true
            }
            if !window.styleMask.contains(.fullSizeContentView) {
                window.styleMask.insert(.fullSizeContentView)
            }
            window.toolbarStyle = .unified
            window.isMovableByWindowBackground = true
            if window.toolbar == nil {
                let toolbar = NSToolbar(identifier: NSToolbar.Identifier("harnais.chrome"))
                toolbar.displayMode = .iconOnly
                toolbar.allowsUserCustomization = false
                window.toolbar = toolbar
            }
            ensureInsetTitlebar(window)
            TrafficLightAdjuster.install(on: window, coordinator: coordinator)
        case .sheet:
            if window.titleVisibility != .hidden {
                window.titleVisibility = .hidden
            }
            if window.titlebarAppearsTransparent {
                window.titlebarAppearsTransparent = false
            }
            if window.styleMask.contains(.fullSizeContentView) {
                window.styleMask.remove(.fullSizeContentView)
            }
            window.isMovableByWindowBackground = false
        }
    }

    private func ensureInsetTitlebar(_ window: NSWindow) {
        let identifier = NSUserInterfaceItemIdentifier("harnais.inset")
        if window.titlebarAccessoryViewControllers.contains(where: { $0.identifier == identifier }) {
            return
        }
        let accessory = NSTitlebarAccessoryViewController()
        accessory.identifier = identifier
        accessory.layoutAttribute = .right
        accessory.view = TitlebarInsetSpacer()
        window.addTitlebarAccessoryViewController(accessory)
    }
}

/// Repositions traffic lights after AppKit tiles the titlebar.
/// T3 Code uses Electron `hiddenInset` with `{ x: 16, y: 18 }`.
private final class TrafficLightAdjuster: NSView {
    weak var coordinator: WindowConfigurator.Coordinator?

    static func install(on window: NSWindow, coordinator: WindowConfigurator.Coordinator?) {
        guard let close = window.standardWindowButton(.closeButton),
              let host = close.superview?.superview ?? close.superview
        else { return }
        if let existing = host.subviews.compactMap({ $0 as? TrafficLightAdjuster }).first {
            existing.coordinator = coordinator
            existing.reposition()
            return
        }
        let adjuster = TrafficLightAdjuster(frame: .zero)
        adjuster.coordinator = coordinator
        adjuster.identifier = NSUserInterfaceItemIdentifier("harnais.traffic")
        host.addSubview(adjuster)
        adjuster.reposition()
    }

    override func viewWillDraw() {
        super.viewWillDraw()
        reposition()
    }

    override func layout() {
        super.layout()
        reposition()
    }

    func reposition() {
        guard let window,
              let close = window.standardWindowButton(.closeButton),
              let mini = window.standardWindowButton(.miniaturizeButton),
              let zoom = window.standardWindowButton(.zoomButton),
              let container = close.superview,
              let parent = container.superview
        else { return }

        let x = WindowChromeMetrics.trafficLightX
        let buttonHeight = close.frame.height
        let yFromTop = (WindowChromeMetrics.titlebarHeight - buttonHeight) / 2
        let originInWindow = NSPoint(
            x: x,
            y: window.frame.height - yFromTop - buttonHeight
        )

        if container.bounds.width < 160 {
            let closeOriginInParent = parent.convert(originInWindow, from: nil)
            move(
                container,
                to: NSPoint(
                    x: closeOriginInParent.x - close.frame.origin.x,
                    y: closeOriginInParent.y - close.frame.origin.y
                )
            )
        } else {
            let origin = container.convert(originInWindow, from: nil)
            let spacing = max(mini.frame.minX - close.frame.minX, close.frame.width + 8)
            move(close, to: origin)
            move(mini, to: NSPoint(x: origin.x + spacing, y: origin.y))
            move(zoom, to: NSPoint(x: origin.x + spacing * 2, y: origin.y))
        }

        let zoomInWindow = zoom.convert(zoom.bounds, to: nil)
        let leading = max(zoomInWindow.maxX + WindowChromeMetrics.titleGap, 80)
        DispatchQueue.main.async { [weak self] in
            self?.coordinator?.report(leading: leading, height: WindowChromeMetrics.titlebarHeight)
        }
    }

    private func move(_ view: NSView, to origin: NSPoint) {
        if abs(view.frame.origin.x - origin.x) > 0.5 || abs(view.frame.origin.y - origin.y) > 0.5 {
            view.setFrameOrigin(origin)
        }
    }
}

private final class TitlebarInsetSpacer: NSView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: WindowChromeMetrics.titlebarHeight)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 1, height: WindowChromeMetrics.titlebarHeight))
    }

    required init?(coder: NSCoder) {
        nil
    }
}
