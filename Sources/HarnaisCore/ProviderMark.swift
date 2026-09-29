import AppKit
import Domain
import SwiftUI

struct ProviderMark: View {
    let provider: ProviderKind
    var size: CGFloat = 20

    var body: some View {
        // Brand marks render single-tint today (existing SVG assets are
        // monochrome); multicolor brand assets are a follow-up. Glyph marks
        // (LucideIcon) are always monochrome by design.
        VectorTemplateMark(
            resource: provider.iconResource,
            tint: provider.iconTint,
            isTemplate: true
        )
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

extension ProviderKind {
    var iconResource: (name: String, ext: String) {
        switch self {
        case .claude: ("ClaudeIcon", "svg")
        case .codex: ("CodexIcon", "svg")
        case .cursor: ("CursorIcon", "svg")
        case .opencode: ("OpenCodeIcon", "svg")
        }
    }

    var iconTint: NSColor {
        switch self {
        case .claude:
            NSColor(srgbRed: 217 / 255, green: 119 / 255, blue: 87 / 255, alpha: 1)
        case .codex, .cursor, .opencode:
            .labelColor
        }
    }
}

/// Draws bundled SVG resources through AppKit's vector image representation.
/// - Brand marks (ProviderMark, IntegrationMark, Harnais app mark): tinted
///   today, full-color assets are a follow-up. Pass isTemplate=false once a
///   multicolor asset lands.
/// - Glyph marks (LucideIcon): always monochrome template images.
struct VectorTemplateMark: NSViewRepresentable {
    let resource: (name: String, ext: String)
    var tint: NSColor = .white
    var isTemplate = true

    func makeNSView(context: Context) -> VectorMarkContainerView {
        let view = VectorMarkContainerView()
        view.image = VectorMarkCache.image(named: resource.name, extension: resource.ext, isTemplate: isTemplate)
        view.tint = tint
        view.isTemplate = isTemplate
        return view
    }

    func updateNSView(_ view: VectorMarkContainerView, context: Context) {
        view.image = VectorMarkCache.image(named: resource.name, extension: resource.ext, isTemplate: isTemplate)
        view.tint = tint
        view.isTemplate = isTemplate
        view.needsDisplay = true
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: VectorMarkContainerView,
        context: Context
    ) -> CGSize? {
        let proposedWidth = proposal.width ?? proposal.height ?? 16
        let proposedHeight = proposal.height ?? proposal.width ?? 16
        let width = proposedWidth.isFinite && proposedWidth > 0 ? proposedWidth : 16
        let height = proposedHeight.isFinite && proposedHeight > 0 ? proposedHeight : 16
        return CGSize(width: min(width, 64), height: min(height, 64))
    }
}

final class VectorMarkContainerView: NSView {
    private let imageView = NSImageView()

    var image: NSImage? {
        get { imageView.image }
        set { imageView.image = newValue }
    }

    var isTemplate = true {
        didSet { refreshTintMode() }
    }

    var tint: NSColor = .white {
        didSet { refreshTintMode() }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 1, height: 1) }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        imageView.imageAlignment = .alignCenter
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageFrameStyle = .none
        imageView.contentTintColor = tint
        addSubview(imageView)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        imageView.frame = bounds
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshBackingScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refreshBackingScale()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshTintMode()
        imageView.needsDisplay = true
    }

    private func refreshTintMode() {
        // Non-template (future full-color brand assets) must not be tinted.
        imageView.contentTintColor = isTemplate ? tint : nil
    }

    private func refreshBackingScale() {
        if let scale = window?.backingScaleFactor {
            layer?.contentsScale = scale
        }
        imageView.needsDisplay = true
        needsDisplay = true
    }
}

enum HarnaisResourceBundle {
    static let bundle: Bundle = resolve(applicationBundle: .main, moduleBundle: .module)

    static func resolve(applicationBundle: Bundle, moduleBundle: Bundle) -> Bundle {
        let candidates = [
            applicationBundle.bundleURL.appendingPathComponent("Harnais_HarnaisCore.bundle"),
            applicationBundle.resourceURL?.appendingPathComponent("Harnais_HarnaisCore.bundle"),
        ].compactMap { $0 }
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            if let bundle = Bundle(url: url) {
                return bundle
            }
        }
        return moduleBundle
    }
}

@MainActor
private enum VectorMarkCache {
    private static var images: [String: NSImage] = [:]

    static func image(named name: String, extension ext: String, isTemplate: Bool = true) -> NSImage? {
        let key = "\(name).\(ext).template=\(isTemplate)"
        if let image = images[key] { return image }
        guard let url = HarnaisResourceBundle.bundle.url(forResource: name, withExtension: ext),
              let image = NSImage(contentsOf: url)
        else { return nil }
        image.isTemplate = isTemplate
        images[key] = image
        return image
    }
}
