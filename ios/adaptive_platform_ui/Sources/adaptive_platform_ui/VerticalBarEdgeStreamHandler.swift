import Flutter
import UIKit

/// Streams where UIKit places its vertical bar for this window
/// (`UITraitCollection.verticalBarEdge`, iOS 27.1) to Dart.
///
/// Each event is a map: `edge` is a physical side ("left", "right", "none",
/// or "unsupported" before iOS 27.1), and `top` and `bottom`, when present,
/// are the distances from the window's top and bottom edges to UIKit's layout
/// region for a bar on that edge (`layoutRegionForBarOnEdge:extent:`). That
/// region is where the system lays out its own vertical bar, so it keeps clear
/// of the status cluster, and of every Live Activity stacked in it.
///
/// Read through the Objective-C runtime so the plugin still builds against
/// SDKs older than 27.1.
final class VerticalBarEdgeStreamHandler: NSObject, FlutterStreamHandler {
    private let registrar: FlutterPluginRegistrar
    private var sink: FlutterEventSink?
    private var observer: EdgeObserverView?
    private var lastSent: NSDictionary?
    /// Bumped on every listen/cancel so retry closures from an earlier
    /// subscription stop instead of racing the current one.
    private var generation = 0

    private static let quickAttempts = 20
    private static let quickInterval: TimeInterval = 0.05
    private static let slowInterval: TimeInterval = 0.5

    init(registrar: FlutterPluginRegistrar) {
        self.registrar = registrar
        super.init()
    }

    func onListen(
        withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink
    ) -> FlutterError? {
        generation += 1
        observer?.removeFromSuperview()
        observer = nil
        lastSent = nil
        sink = events
        attach(attempt: 0, generation: generation)
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        generation += 1
        observer?.removeFromSuperview()
        observer = nil
        sink = nil
        lastSent = nil
        return nil
    }

    /// The Flutter view can still be outside a window when Dart starts
    /// listening (scene-based apps), so retry. After the quick attempts run
    /// out, report "unsupported" once so Dart can fall back, but keep polling
    /// slowly in case the view joins a window later.
    private func attach(attempt: Int, generation: Int) {
        guard generation == self.generation, sink != nil, observer == nil else { return }
        guard let host = registrar.viewController?.view, host.window != nil else {
            if attempt == Self.quickAttempts {
                send(["edge": "unsupported"])
            }
            let delay = attempt < Self.quickAttempts ? Self.quickInterval : Self.slowInterval
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.attach(attempt: attempt + 1, generation: generation)
            }
            return
        }
        let view = EdgeObserverView(frame: host.bounds)
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        view.onChange = { [weak self] v in self?.send(v.reading()) }
        host.insertSubview(view, at: 0)
        observer = view
        send(view.reading())
    }

    private func send(_ reading: [String: Any]) {
        let value = reading as NSDictionary
        guard value != lastSent else { return }
        lastSent = value
        sink?(reading)
    }

    static func edge(of view: UIView) -> String {
        let key = "verticalBarEdge"
        let traits = view.traitCollection
        guard traits.responds(to: NSSelectorFromString(key)),
            let raw = (traits.value(forKey: key) as? NSNumber)?.intValue
        else { return "unsupported" }
        let rtl = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
        switch raw {
        case 1: return rtl ? "right" : "left"  // UIVerticalBarEdgeLeading
        case 2: return rtl ? "left" : "right"  // UIVerticalBarEdgeTrailing
        default: return "none"                 // UIVerticalBarEdgeUnspecified
        }
    }
}

/// Draws nothing and takes no touches; reports layout, trait and safe-area
/// changes of the Flutter view (pane switch, divider drag, rotation). Moving
/// between Split View panes does not change the view's size, as both panes are
/// the same width, but it does change the safe-area insets, so those are the
/// signal for pane moves.
///
/// It also holds a hidden probe pinned to UIKit's layout guide for a bar on
/// the system's edge. The guide follows the status cluster, so when a Live
/// Activity starts or ends, the probe moves and this view lays out again.
private final class EdgeObserverView: UIView {
    var onChange: ((EdgeObserverView) -> Void)?

    /// The width of the bar the region is requested for, as the system's
    /// own vertical bar.
    private static let barExtent: CGFloat = 84

    private var probe: UIView?
    private var probeEdge: String?

    override func layoutSubviews() {
        super.layoutSubviews()
        onChange?(self)
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        onChange?(self)
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        onChange?(self)
    }

    /// The current edge, with the bar region's insets when the system has one.
    func reading() -> [String: Any] {
        let edge = VerticalBarEdgeStreamHandler.edge(of: self)
        updateProbe(for: edge)
        guard let probe = probe, bounds.height > 0, probe.frame.height > 0 else {
            return ["edge": edge]
        }
        return [
            "edge": edge,
            "top": Double(probe.frame.minY),
            "bottom": Double(bounds.height - probe.frame.maxY),
        ]
    }

    /// Pins the probe to the bar region on [edge], replacing it when the edge
    /// changes, and removes it where there is no vertical bar.
    private func updateProbe(for edge: String) {
        guard edge != probeEdge else { return }
        probeEdge = edge
        probe?.removeFromSuperview()
        probe = nil

        let rectEdge: UIRectEdge
        switch edge {
        case "left": rectEdge = .left
        case "right": rectEdge = .right
        default: return
        }
        guard let guide = Self.barLayoutGuide(in: self, edge: rectEdge) else { return }

        let view = UIView()
        view.isHidden = true
        view.isUserInteractionEnabled = false
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: guide.topAnchor),
            view.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
        ])
        probe = view

        // Solve the new constraints now, so this reading already has the frame.
        layoutIfNeeded()
    }

    /// `-[UIView layoutGuideForLayoutRegion:]` with
    /// `+[UIViewLayoutRegion layoutRegionForBarOnEdge:extent:]` (iOS 27.1),
    /// or nil where either is missing.
    private static func barLayoutGuide(in view: UIView, edge: UIRectEdge) -> UILayoutGuide? {
        let regionSelector = NSSelectorFromString("layoutRegionForBarOnEdge:extent:")
        let guideSelector = NSSelectorFromString("layoutGuideForLayoutRegion:")
        guard let regionClass = NSClassFromString("UIViewLayoutRegion"),
            let regionMethod = class_getClassMethod(regionClass, regionSelector),
            view.responds(to: guideSelector)
        else { return nil }

        typealias MakeRegion = @convention(c) (AnyClass, Selector, UInt, CGFloat) -> AnyObject?
        let makeRegion = unsafeBitCast(method_getImplementation(regionMethod), to: MakeRegion.self)
        guard let region = makeRegion(regionClass, regionSelector, edge.rawValue, barExtent) else {
            return nil
        }
        return view.perform(guideSelector, with: region)?.takeUnretainedValue() as? UILayoutGuide
    }
}
