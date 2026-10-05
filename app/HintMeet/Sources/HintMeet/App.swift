import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Afmetingen die je zelf aan het paneel geeft met de greep rechtsonder (ResizeGrip); de hoogte is een minimum,
/// want meer inhoud laat het paneel nog steeds meegroeien.
@MainActor
final class PanelLayout: ObservableObject {
    static let defaultWidth: CGFloat = 440
    static let minWidth: CGFloat = 320
    @Published var width: CGFloat
    @Published var minHeight: CGFloat
    private let key = "overlaySize"

    init() {
        let saved = (UserDefaults.standard.array(forKey: key) as? [Double] ?? []).filter(\.isFinite)
        width = saved.count == 2 ? saved[0] : Self.defaultWidth
        minHeight = saved.count == 2 ? saved[1] : 0
        clamp(to: NSScreen.main?.visibleFrame.size)
    }

    /// Nooit kleiner dan het minimum en nooit groter dan het scherm (bv. na wisselen naar een kleiner scherm).
    func clamp(to screen: NSSize?) {
        let maxW = screen.map { $0.width - 40 } ?? 2000
        let maxH = screen.map { $0.height * 0.8 } ?? 1200
        width = min(max(width, Self.minWidth), max(maxW, Self.minWidth))
        minHeight = min(max(minHeight, 0), maxH)
    }

    func save() { UserDefaults.standard.set([width, minHeight], forKey: key) }

    func reset() {
        width = Self.defaultWidth
        minHeight = 0
        UserDefaults.standard.removeObject(forKey: key)
    }
}

/// Zwevend paneel dat geen focus steelt: klikken erop haalt je toetsenbord niet uit de meeting.
final class OverlayPanel: NSPanel {
    /// Alleen buiten een meeting mag het paneel toetsen ontvangen (invoerveld "Met wie?").
    var acceptsKeyboard: () -> Bool = { false }

    init(content: NSView) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: PanelLayout.defaultWidth, height: 200),
                   styleMask: [.nonactivatingPanel, .borderless],
                   backing: .buffered, defer: false)
        minSize = NSSize(width: PanelLayout.minWidth, height: 80)
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
    override var canBecomeKey: Bool { acceptsKeyboard() }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let store = HintStore()
    let settings = Settings()
    let layout = PanelLayout()
    var backend: Backend!
    var connection: Connection!
    var panel: OverlayPanel!
    var statusItem: NSStatusItem!
    var hosting: NSHostingView<OverlayView>!
    var settingsWindow: NSWindow?
    var changes: AnyCancellable?
    private var refit: DispatchWorkItem?
    private var quitWatch: AnyCancellable?
    private var restarting = false
    private let topLeftKey = "overlayTopLeft"

    func applicationDidFinishLaunching(_ notification: Notification) {
        let port = Int(ProcessInfo.processInfo.environment["HINT_MEET_PORT"] ?? "") ?? 8765
        connection = Connection(port: port, store: store)
        backend = Backend(settings: settings, port: port)

        let view = OverlayView(store: store, backend: backend, settings: settings, layout: layout,
                               send: { [weak self] msg in self?.connection.send(msg) },
                               startMeeting: { [weak self] in self?.startMeeting() },
                               playRecording: { [weak self] in self?.playRecording() },
                               stopMeeting: { [weak self] in self?.stopMeeting() },
                               openSettings: { [weak self] in self?.showSettings() })
        hosting = NSHostingView(rootView: view)
        // alleen de gemeten maat doorgeven (voor fit); min/max zouden het venster op de inhoud vastzetten
        hosting.sizingOptions = [.intrinsicContentSize]
        panel = OverlayPanel(content: hosting)
        panel.acceptsKeyboard = { [weak self] in !(self?.backend.isRunning ?? true) }
        panel.setFrameTopLeftPoint(initialTopLeft())
        fit()
        panel.orderFrontRegardless()
        // meegroeien met de inhoud, met de bovenrand vast; en onthouden waar het paneel staat
        changes = store.objectWillChange.merge(with: backend.objectWillChange, layout.objectWillChange).sink {
            [weak self] _ in
            DispatchQueue.main.async { self?.fit() }
            // het regeltje over een ingetrokken hint verdwijnt na een paar seconden: dan opnieuw passen
            self?.refitLater()
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let f = self.panel.frame
                UserDefaults.standard.set([f.minX, f.maxY], forKey: self.topLeftKey)
            }
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "💡"
        let menu = NSMenu()
        menu.delegate = self   // menu wordt bij elke klik opnieuw opgebouwd, met de actuele stand
        statusItem.menu = menu

        connection.start()
        if ProcessInfo.processInfo.environment["HINT_MEET_AUTOSTART"] != nil {
            startMeeting()
        } else if settings.project.isEmpty || !settings.backendReady {
            showSettings()
        }
    }

    /// Afsluiten (ook via Herstarten) wacht tot de pijplijn het verslag heeft gemaakt; het paneel toont de voortgang.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard backend.isRunning else { return .terminateNow }
        backend.stop()
        panel.orderFrontRegardless()
        quitWatch = backend.$state.sink { [weak self] state in
            guard state != .stopping, state != .running else { return }
            DispatchQueue.main.async {
                self?.quitWatch = nil
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        backend.stopNow()   // geen losse pijplijn achterlaten die nog naar de microfoon luistert
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status: String
        switch backend.state {
        case .idle: status = "Geen meeting actief"
        case .running: status = "Luistert · \(settings.project)"
        case .stopping: status = "Stopt… (verslag wordt gemaakt)"
        case .failed(let why): status = "⚠ \(why)"
        }
        let header = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        if backend.isRunning {
            menu.addItem(item("Meeting stoppen", #selector(stopMeeting), "s"))
        } else {
            let start = item(settings.project.isEmpty ? "Meeting starten (kies eerst een project)" : "Meeting starten · \(settings.project)",
                             #selector(startMeeting), "s")
            start.isEnabled = !settings.project.isEmpty && settings.backendReady
            menu.addItem(start)
        }
        let replay = item("Opname afspelen…", #selector(playRecording), "o")
        replay.isEnabled = !backend.isRunning && !settings.project.isEmpty && settings.backendReady
        menu.addItem(replay)
        let projectItem = NSMenuItem(title: "Project", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for name in settings.projects {
            let it = item(name, #selector(chooseProject(_:)), "")
            it.representedObject = name
            it.state = name == settings.project ? .on : .off
            it.isEnabled = !backend.isRunning
            sub.addItem(it)
        }
        if sub.items.isEmpty { sub.addItem(NSMenuItem(title: "Geen projecten in \(settings.kbRoot)", action: nil, keyEquivalent: "")) }
        projectItem.submenu = sub
        menu.addItem(projectItem)
        menu.addItem(.separator())
        menu.addItem(item(panel.isVisible ? "Overlay verbergen" : "Overlay tonen", #selector(togglePanel), "h"))
        menu.addItem(item("Overlay standaardgrootte", #selector(resetPanelSize), ""))
        menu.addItem(item("Instellingen…", #selector(showSettings), ","))
        menu.addItem(item("Logboek", #selector(openLog), ""))
        menu.addItem(.separator())
        let restart = item(settings.project.isEmpty ? "HintMeet herstarten" : "HintMeet herstarten · \(settings.project)",
                           #selector(restartApp), "r")
        restart.toolTip = "Sluit HintMeet af (een lopende meeting maakt eerst zijn verslag) en start de nieuwste build opnieuw"
        menu.addItem(restart)
        menu.addItem(item("Stop HintMeet", #selector(NSApplication.terminate(_:)), "q"))
    }

    private func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = action == #selector(NSApplication.terminate(_:)) ? nil : self
        return it
    }

    @objc func startMeeting() {
        panel.resignKey()   // na typen in "Met wie?": toetsenbord terug naar de meeting
        backend.start()
        statusItem.button?.title = backend.isRunning ? "💡●" : "💡"
        panel.orderFrontRegardless()
        watchBackend()
    }

    @objc func stopMeeting() { backend.stop() }

    /// Afsluiten en opnieuw openen (pakt een nieuwe build op); het gekozen project blijft staan, er start
    /// geen meeting. Een hulpproces wacht tot deze app echt weg is, ook als het verslag nog even duurt.
    @objc func restartApp() {
        guard !restarting else { return }   // nog eens klikken tijdens het wachten: geen tweede app
        restarting = true
        let bundle = Bundle.main.bundlePath
        let script = "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; "
            + "open -n \"$0\""
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", script, bundle]
        do {
            try helper.run()
        } catch {
            restarting = false
            NSSound.beep()
            return
        }
        NSApp.terminate(nil)   // applicationShouldTerminate wacht eerst op het verslag van een lopende meeting
    }

    /// Een eerdere opname (bv. van de Plaud) afspelen alsof het een live meeting is.
    @objc func playRecording() {
        let panel = NSOpenPanel()
        panel.title = "Opname afspelen"
        panel.allowedContentTypes = [.audio, .mpeg4Audio, .mp3, .wav]
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        backend.start(recording: url.path)
        self.panel.orderFrontRegardless()
        watchBackend()
    }

    @objc func chooseProject(_ sender: NSMenuItem) {
        if let name = sender.representedObject as? String { settings.project = name }
    }

    @objc func openLog() { NSWorkspace.shared.open(Backend.logURL) }

    @objc func showSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 520),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "HintMeet-instellingen"
            w.contentView = NSHostingView(rootView: SettingsView(settings: settings))
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private var stateWatch: AnyCancellable?
    private func watchBackend() {
        stateWatch = backend.$state.sink { [weak self] state in
            DispatchQueue.main.async {
                guard let self else { return }
                switch state {
                case .running: self.statusItem.button?.title = "💡●"
                case .stopping: self.statusItem.button?.title = "💡…"
                case .failed: self.statusItem.button?.title = "💡⚠"
                case .idle: self.statusItem.button?.title = "💡"
                }
            }
        }
    }

    // MARK: paneel

    private func initialTopLeft() -> NSPoint {
        if let saved = UserDefaults.standard.array(forKey: topLeftKey) as? [Double], saved.count == 2 {
            let p = NSPoint(x: saved[0], y: saved[1])
            if NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -20, dy: -20).contains(p) }) { return p }
        }
        let f = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        return NSPoint(x: f.maxX - layout.width - 20, y: f.maxY - 20)
    }

    @objc func resetPanelSize() { layout.reset() }

    /// Eén uitgestelde fit, die bij elke nieuwe wijziging opnieuw begint (geen stapel timers tijdens streamen).
    private func refitLater() {
        refit?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fit() }
        refit = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.5, execute: work)
    }

    func fit() {
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        var frame = panel.frame
        let top = frame.maxY
        frame.size = NSSize(width: max(size.width, PanelLayout.minWidth), height: size.height)
        frame.origin.y = top - frame.height
        if let vf = panel.screen?.visibleFrame, frame.minY < vf.minY {
            frame.origin.y = min(vf.minY, vf.maxY - frame.height)   // onderrand niet buiten beeld laten groeien
        }
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
