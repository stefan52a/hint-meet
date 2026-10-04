import AppKit
import Combine
import SwiftUI

/// Zwevend paneel dat geen focus steelt: klikken erop haalt je toetsenbord niet uit de meeting.
final class OverlayPanel: NSPanel {
    init(content: NSView) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 380, height: 200),
                   styleMask: [.nonactivatingPanel, .borderless],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        contentView = content
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = HintStore()
    var connection: Connection!
    var panel: OverlayPanel!
    var statusItem: NSStatusItem!
    var hosting: NSHostingView<OverlayView>!
    var changes: AnyCancellable?
    private let topLeftKey = "overlayTopLeft"

    func applicationDidFinishLaunching(_ notification: Notification) {
        let port = Int(ProcessInfo.processInfo.environment["HINT_MEET_PORT"] ?? "") ?? 8765
        connection = Connection(port: port, store: store)

        let view = OverlayView(store: store) { [weak self] msg in self?.connection.send(msg) }
        hosting = NSHostingView(rootView: view)
        panel = OverlayPanel(content: hosting)
        panel.setFrameTopLeftPoint(initialTopLeft())
        fit()
        panel.orderFrontRegardless()
        // meegroeien met de inhoud, met de bovenrand vast; en onthouden waar het paneel staat
        changes = store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.fit() }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let f = self.panel.frame
                UserDefaults.standard.set([f.minX, f.maxY], forKey: self.topLeftKey)
            }
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.title = "💡"
        let menu = NSMenu()
        menu.addItem(withTitle: "Overlay tonen/verbergen", action: #selector(togglePanel), keyEquivalent: "h")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Stop HintMeet", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu

        connection.start()
    }

    private func initialTopLeft() -> NSPoint {
        if let saved = UserDefaults.standard.array(forKey: topLeftKey) as? [Double], saved.count == 2 {
            let p = NSPoint(x: saved[0], y: saved[1])
            if NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -20, dy: -20).contains(p) }) { return p }
        }
        let f = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        return NSPoint(x: f.maxX - 400, y: f.maxY - 20)
    }

    func fit() {
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        var frame = panel.frame
        let top = frame.maxY
        frame.size = NSSize(width: max(size.width, 380), height: size.height)
        frame.origin.y = top - frame.height
        panel.setFrame(frame, display: true)
    }

    @objc func togglePanel() {
        if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
    }
}

@main
struct HintMeetMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)   // geen Dock-icoon, wel menubalk
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
