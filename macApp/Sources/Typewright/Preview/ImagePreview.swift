import AppKit
import Observation
import SwiftUI

/// Keeps the image in the middle while it's smaller than the view.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return rect }
        if rect.width > doc.frame.width { rect.origin.x = (doc.frame.width - rect.width) / 2 }
        if rect.height > doc.frame.height { rect.origin.y = (doc.frame.height - rect.height) / 2 }
        return rect
    }
}

/// Shows an image file, fitted to the view until zoomed.
@MainActor @Observable
final class ImagePreviewController {
    private(set) var scale: CGFloat = 1
    private(set) var autoFits = true
    private(set) var pixelSize: CGSize?

    @ObservationIgnored let view: NSScrollView = {
        let scroll = NSScrollView()
        scroll.contentView = CenteringClipView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.05
        scroll.maxMagnification = 32
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        return scroll
    }()
    @ObservationIgnored private let imageView: NSImageView = {
        let view = NSImageView()
        view.imageScaling = .scaleAxesIndependently
        view.animates = true
        return view
    }()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        view.documentView = imageView
        let nc = NotificationCenter.default
        observers = [
            // Pinching takes over from fitting.
            nc.addObserver(forName: NSScrollView.willStartLiveMagnifyNotification, object: view, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.autoFits = false }
            },
            nc.addObserver(forName: NSScrollView.didEndLiveMagnifyNotification, object: view, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scale = self?.view.magnification ?? 1 }
            },
        ]
        view.postsFrameChangedNotifications = true
        observers.append(nc.addObserver(forName: NSView.frameDidChangeNotification, object: view, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.autoFits == true { self?.fit(animated: false) } }
        })
    }

    func show(_ url: URL) {
        let image = NSImage(contentsOf: url)
        imageView.image = image
        let size = image?.size ?? .zero
        imageView.frame = NSRect(origin: .zero, size: size)
        pixelSize = image?.representations.first.map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) }
        autoFits = true
        // The view gets its real size on the next layout pass.
        DispatchQueue.main.async { self.fit(animated: false) }
    }

    func zoomIn() { setScale(view.magnification * 1.25) }
    func zoomOut() { setScale(view.magnification / 1.25) }

    func fitToView() {
        autoFits = true
        fit(animated: true)
    }

    /// Shrinks large images to fit; small ones stay at their natural size.
    private func fit(animated: Bool) {
        let size = imageView.frame.size
        let bounds = view.contentSize
        guard size.width > 0, size.height > 0, bounds.width > 0 else { return }
        apply(min(1, bounds.width / size.width, bounds.height / size.height), animated: animated)
    }

    private func setScale(_ value: CGFloat) {
        autoFits = false
        apply(min(max(value, view.minMagnification), view.maxMagnification), animated: true)
    }

    private func apply(_ value: CGFloat, animated: Bool) {
        let center = NSPoint(x: imageView.frame.midX, y: imageView.frame.midY)
        if animated {
            NSAnimationContext.runAnimationGroup { $0.duration = 0.2; view.animator().setMagnification(value, centeredAt: center) }
        } else {
            view.setMagnification(value, centeredAt: center)
        }
        scale = value
    }
}

private struct ImageViewHost: NSViewRepresentable {
    let controller: ImagePreviewController
    func makeNSView(context: Context) -> NSScrollView { controller.view }
    func updateNSView(_ view: NSScrollView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 300, height: proposal.height ?? 300)
    }
}

/// Full-width viewer for an image file in the space.
struct ImageFileView: View {
    let controller: ImagePreviewController
    @State private var hovering = false

    var body: some View {
        ImageViewHost(controller: controller)
            .background(SidebarMaterial())
            .overlay(alignment: .bottom) {
                FloatingBar(isVisible: hovering) {
                    let percent = "\(Int((controller.scale * 100).rounded()))%"
                    Button { controller.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
                        .help("Zoom out")
                    Button { controller.fitToView() } label: {
                        Text(controller.autoFits ? "Fit (\(percent))" : percent).monospacedDigit().frame(minWidth: 38)
                    }
                    .help("Fit to view")
                    Button { controller.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
                        .help("Zoom in")
                    if let size = controller.pixelSize, size.width > 0 {
                        Divider().frame(height: 16)
                        Text("\(Int(size.width)) × \(Int(size.height))").monospacedDigit()
                    }
                }
            }
            .onHover { hovering = $0 }
    }
}
