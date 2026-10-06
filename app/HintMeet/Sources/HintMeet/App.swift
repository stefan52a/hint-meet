import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Afmetingen die je zelf aan het paneel geeft met de greep rechtsonder (ResizeGrip); de hoogte is een minimum,
/// want meer inhoud laat het paneel nog steeds meegroeien.
@MainActor
final class PanelLayout: ObservableObject {
    static let defaultWidth: CGFloat = 760   // breed genoeg voor transcript en hint naast elkaar
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
    /// App die actief was voordat een klik op het paneel HintMeet actief maakte; krijgt bij de start
    /// van een meeting de focus terug.
    var previousApp: NSRunningApplication?

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

    /// Buiten een meeting maakt een klik op het paneel HintMeet de actieve app, zodat de menubalk linksboven
    /// weer van HintMeet is. Tijdens een meeting niet: dan blijft de focus bij de meeting-app.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown && acceptsKeyboard() && !NSApp.isActive {
            previousApp = NSWorkspace.shared.frontmostApplication
            NSApp.activate(ignoringOtherApps: true)
        }
        super.sendEvent(event)
    }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let store = HintStore()
    let settings = Settings()
    let layout = PanelLayout()
    var backend: Backend!
    var preparer: ProgressTask!
    let kbPrep = ProgressTask(logName: "kb_prep")
    var kbPrepWindow: NSWindow?
    private let meetingMenu = NSMenu(title: "Meeting")
    private let kbMenu = NSMenu(title: "Knowledge Base")
    private let windowMenu = NSMenu(title: "Window")
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
        preparer = ProgressTask(logName: "prepare")

        let view = OverlayView(store: store, backend: backend, preparer: preparer, settings: settings, layout: layout,
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
        changes = store.objectWillChange.merge(with: backend.objectWillChange, layout.objectWillChange,
                                               preparer.objectWillChange).sink {
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

        buildMainMenu()
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

    /// Klik op het Dock-icoon: het paneel tevoorschijn halen (het enige "venster" dat er altijd is).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel.orderFrontRegardless()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        preparer.stop()   // indexeren bewaart per batch; de volgende keer gaat hij verder
        kbPrep.stop()     // kb_prep legt bij Ctrl-C het manifest vast
        backend.stopNow()   // geen losse pijplijn achterlaten die nog naar de microfoon luistert
    }

    // MARK: menu

    /// Alle menu's worden bij het openen opnieuw opgebouwd, met de actuele stand. Het 💡-menu en de menubalk
    /// linksboven gebruiken dezelfde onderdelen.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let parts: [[NSMenuItem]]
        switch menu {
        case meetingMenu: parts = [meetingItems()]
        case kbMenu: parts = [kbItems()]
        case windowMenu: parts = [overlayItems()]
        default:   // het 💡-menu
            let header = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
            header.isEnabled = false
            let restart = item(settings.project.isEmpty ? "Restart HintMeet" : "Restart HintMeet · \(settings.projectLabel)",
                               #selector(restartApp), "r")
            restart.toolTip = "Quits HintMeet (a running meeting finishes its report first) and starts the latest build"
            parts = [[header], meetingItems(), kbItems(), overlayItems(),
                     [item("Settings…", #selector(showSettings), ","), item("Log", #selector(openLog), "")],
                     [restart, item("Quit HintMeet", #selector(NSApplication.terminate(_:)), "q")]]
        }
        for (i, group) in parts.enumerated() {
            if i > 0 { menu.addItem(.separator()) }
            group.forEach(menu.addItem)
        }
    }

    private var statusText: String {
        switch backend.state {
        case .idle: return "No meeting running"
        case .running: return "Listening · \(settings.projectLabel)"
        case .stopping: return "Stopping… (writing report)"
        case .failed(let why): return "⚠ \(why)"
        }
    }

    private func meetingItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if backend.isRunning {
            items.append(item("Stop Meeting", #selector(stopMeeting), "s"))
        } else {
            let start = item(settings.project.isEmpty ? "Start Meeting (choose a project first)" : "Start Meeting · \(settings.projectLabel)",
                             #selector(startMeeting), "s")
            start.isEnabled = !settings.project.isEmpty && settings.backendReady && !preparer.isRunning
            items.append(start)
        }
        let prev = item("Previous Hint", #selector(previousHint), "[")
        prev.isEnabled = !store.history.isEmpty
        let next = item("Next Hint", #selector(nextHint), "]")
        next.isEnabled = store.isBrowsing
        let live = item("Latest Hint", #selector(latestHint), "")
        live.isEnabled = store.isBrowsing
        items += [prev, next, live]
        let replay = item("Play Recording…", #selector(playRecording), "o")
        replay.isEnabled = !backend.isRunning && !settings.project.isEmpty && settings.backendReady && !preparer.isRunning
        items.append(replay)
        return items
    }

    private func kbItems() -> [NSMenuItem] {
        let projectItem = NSMenuItem(title: "Projects (select one or more)", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for name in settings.projects {
            let it = item(name, #selector(chooseProject(_:)), "")
            it.representedObject = name
            it.state = settings.selectedProjects.contains(name) ? .on : .off
            it.isEnabled = !backend.isRunning && !preparer.isRunning
            sub.addItem(it)
        }
        if sub.items.isEmpty { sub.addItem(NSMenuItem(title: "No projects in \(settings.kbRoot)", action: nil, keyEquivalent: "")) }
        projectItem.submenu = sub
        let load = item(preparer.isRunning ? "Load KB (running…)" : "Load KB", #selector(prepareKB), "l")
        load.isEnabled = !preparer.isRunning && !backend.isRunning && !settings.project.isEmpty && settings.backendReady
        let prep = item(kbPrep.isRunning ? "Convert Documents (running…)" : "Convert Documents (kb_prep)…",
                        #selector(showKBPrep), "")
        return [projectItem, load, prep]
    }

    private func overlayItems() -> [NSMenuItem] {
        [item(panel.isVisible ? "Hide Overlay" : "Show Overlay", #selector(togglePanel), ""),
         item("Reset Overlay Size", #selector(resetPanelSize), "")]
    }

    @objc func prepareKB() { preparer.startPrepare(settings) }
    @objc func previousHint() { store.back() }
    @objc func nextHint() { store.forward() }
    @objc func latestHint() { store.latest() }

    /// Menubalk linksboven, zoals bij andere apps: HintMeet, Bewerk, Meeting, Kennisbank, Venster, Help.
    private func buildMainMenu() {
        let main = NSMenu()
        func top(_ title: String, _ menu: NSMenu) {
            let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            it.submenu = menu
            main.addItem(it)
        }
        func fixed(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            return m
        }
        func standard(_ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let it = NSMenuItem(title: title, action: action, keyEquivalent: key)   // naar de responder chain
            it.keyEquivalentModifierMask = mods
            return it
        }
        let about = NSMenuItem(title: "About HintMeet", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                               keyEquivalent: "")
        top("HintMeet", fixed("HintMeet", [
            about, .separator(),
            item("Settings…", #selector(showSettings), ","), .separator(),
            standard("Hide HintMeet", #selector(NSApplication.hide(_:)), "h"),
            standard("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            standard("Show All", #selector(NSApplication.unhideAllApplications(_:)), ""), .separator(),
            item("Restart HintMeet", #selector(restartApp), "r"),
            item("Quit HintMeet", #selector(NSApplication.terminate(_:)), "q"),
        ]))
        // nodig voor knippen en plakken in tekstvelden, zoals "Met wie?"
        top("Edit", fixed("Edit", [
            standard("Undo", Selector(("undo:")), "z"), standard("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            standard("Cut", #selector(NSText.cut(_:)), "x"), standard("Copy", #selector(NSText.copy(_:)), "c"),
            standard("Paste", #selector(NSText.paste(_:)), "v"), standard("Select All", #selector(NSText.selectAll(_:)), "a"),
        ]))
        for (title, menu) in [("Meeting", meetingMenu), ("Knowledge Base", kbMenu), ("Window", windowMenu)] {
            menu.delegate = self
            top(title, menu)
        }
        // geen NSApp.windowsMenu: dat menu bouwen we zelf opnieuw op, en macOS zou er vensters in zetten
        let help = fixed("Help", [item("Log", #selector(openLog), "")])
        top("Help", help)
        NSApp.helpMenu = help
        NSApp.mainMenu = main
    }

    private func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = action == #selector(NSApplication.terminate(_:)) ? nil : self
        return it
    }

    @objc func startMeeting() {
        panel.resignKey()   // na typen in "Meeting info": toetsenbord terug naar de meeting
        if NSApp.isActive, let app = panel.previousApp, !app.isTerminated, app != NSRunningApplication.current {
            app.activate()   // de meeting-app weer voorop, met zijn eigen menubalk
        }
        panel.previousApp = nil   // één keer gebruiken; een volgende klik op het paneel onthoudt opnieuw
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
        panel.title = "Play Recording"
        panel.allowedContentTypes = [.audio, .mpeg4Audio, .mp3, .wav]
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        backend.start(recording: url.path)
        self.panel.orderFrontRegardless()
        watchBackend()
    }

    @objc func chooseProject(_ sender: NSMenuItem) {
        if let name = sender.representedObject as? String { settings.toggleProject(name) }   // aan/uit vinken
    }

    @objc func openLog() { NSWorkspace.shared.open(Backend.logURL) }

    @objc func showSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 520),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "HintMeet Settings"
            w.contentView = NSHostingView(rootView: SettingsView(settings: settings))
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func showKBPrep() {
        if kbPrepWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Convert Documents"
            w.contentView = NSHostingView(rootView: KBPrepView(settings: settings, task: kbPrep))
            w.isReleasedWhenClosed = false   // sluiten verbergt alleen; het omzetten loopt door
            w.center()
            kbPrepWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        kbPrepWindow?.makeKeyAndOrderFront(nil)
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
        app.setActivationPolicy(.regular)   // gewone app: Dock-icoon en menubalk linksboven, plus het 💡-menu
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
