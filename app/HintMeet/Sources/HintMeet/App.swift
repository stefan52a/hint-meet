import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Standaard- en minimumbreedte van het paneel (het venster zelf bepaalt de maat; macOS onthoudt hem).
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

/// Hostingview waarin de eerste klik meteen telt (ook als HintMeet niet de actieve app is) en die het
/// venster niet laat verslepen: een klik op een uitspraak of hint moet die selecteren.
final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
}

/// Zwevend paneel dat geen focus steelt: klikken erop haalt je toetsenbord niet uit de meeting.
final class OverlayPanel: NSPanel {
    /// Alleen buiten een meeting mag het paneel toetsen ontvangen (invoerveld "Met wie?").
    var acceptsKeyboard: () -> Bool = { false }
    /// App die actief was voordat een klik op het paneel HintMeet actief maakte; krijgt bij de start
    /// van een meeting de focus terug.
    var previousApp: NSRunningApplication?

    static let defaultSize = NSSize(width: PanelLayout.defaultWidth, height: 560)

    /// Een gewoon venster (titelbalk met sluiten, minimaliseren en maximaliseren, overal te vergroten) dat
    /// standaard boven andere vensters blijft en geen focus steelt.
    init(content: NSView) {
        super.init(contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        title = "HintMeet"
        minSize = NSSize(width: PanelLayout.minWidth, height: 220)
        isFloatingPanel = true
        level = UserDefaults.standard.object(forKey: "keepOnTop") as? Bool ?? true ? .floating : .normal
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .managed]
        isMovableByWindowBackground = false   // verslepen via de titelbalk of de kopbalk; elders zijn klikken voor de tekst
        hidesOnDeactivate = false
        isReleasedWhenClosed = false   // sluiten verbergt; Show Overlay, het Dock-icoon of 💡 haalt hem terug
        hasShadow = true
        contentView = content
    }
    override var canBecomeKey: Bool { acceptsKeyboard() }

    /// Hoogte van de kopbalk (hint-meet · project) vanaf de bovenrand van het paneel.
    static let headerHeight: CGFloat = 70   // titelbalk plus de regel hint-meet · project

    /// Buiten een meeting maakt elke klik op het paneel HintMeet de actieve app, zodat de menubalk linksboven
    /// weer van HintMeet is. Tijdens een meeting alleen een klik op de kopbalk: klikken op hints, ◀ ▶, 👍 en
    /// het transcript laten de focus (en je toetsenbord) bij de meeting-app.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown && !NSApp.isActive {
            let onHeader = event.locationInWindow.y >= frame.height - Self.headerHeight
            if acceptsKeyboard() || onHeader {
                previousApp = NSWorkspace.shared.frontmostApplication
                NSApp.activate(ignoringOtherApps: true)
            }
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
    var findWindow: NSWindow?
    lazy var searchService = SearchService(settings: settings)
    lazy var kbStatus = KBStatus(settings: settings)
    private var statusWatches: [AnyCancellable] = []
    private var loadingProjects: [String] = []
    private var loadingStarted = Date()
    private let meetingMenu = NSMenu(title: "Meeting")
    private let kbMenu = NSMenu(title: "Knowledge Base")
    private let windowMenu = NSMenu(title: "Window")
    var connection: Connection!
    var panel: OverlayPanel!
    var statusItem: NSStatusItem!
    var hosting: ClickThroughHostingView<OverlayView>!
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

        let view = OverlayView(store: store, backend: backend, preparer: preparer, kbPrep: kbPrep, kbStatus: kbStatus,
                               settings: settings, layout: layout,
                               send: { [weak self] msg in self?.connection.send(msg) },
                               startMeeting: { [weak self] in self?.startMeeting() },
                               playRecording: { [weak self] in self?.playRecording() },
                               stopMeeting: { [weak self] in self?.stopMeeting() },
                               openSettings: { [weak self] in self?.showSettings() },
                               addFolder: { [weak self] in self?.addKBFolder() },
                               find: { [weak self] in self?.showFind() })
        hosting = ClickThroughHostingView(rootView: view)
        hosting.sizingOptions = []   // het venster bepaalt de maat (jij sleept); de inhoud vult het
        panel = OverlayPanel(content: hosting)
        panel.acceptsKeyboard = { [weak self] in !(self?.backend.isRunning ?? true) }
        // macOS onthoudt plek en maat; de eerste keer rechtsboven op het hoofdscherm
        if !panel.setFrameUsingName(Self.frameName) {
            let f = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: f.maxX - OverlayPanel.defaultSize.width - 20, y: f.maxY - 20))
        }
        panel.setFrameAutosaveName(Self.frameName)
        panel.orderFrontRegardless()

        watchKBStatus()
        buildMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "💡"
        let menu = NSMenu()
        menu.delegate = self   // menu wordt bij elke klik opnieuw opgebouwd, met de actuele stand
        statusItem.menu = menu

        connection.start()
        // demo/test: "bronmap|project" opent Convert Documents en zet meteen om
        if let convert = ProcessInfo.processInfo.environment["HINT_MEET_CONVERT"],
           case let parts = convert.split(separator: "|", maxSplits: 1).map(String.init), !parts.isEmpty {
            let project = parts.count > 1 ? parts[1] : KBPrepView.projectName(for: parts[0])
            openKBPrep(source: parts[0], project: project)
            kbPrep.startKBPrep(settings, source: parts[0], project: project, force: false, noOCR: false)
        }
        if let q = ProcessInfo.processInfo.environment["HINT_MEET_FIND"] {   // test: Find Document met een zoekvraag
            searchService.pendingQuery = q
            showFind()
        }
        if let folder = ProcessInfo.processInfo.environment["HINT_MEET_ADD_FOLDER"] {   // test: Add Folder zonder kiesvenster
            ingest(folder: URL(fileURLWithPath: folder))
        }
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
        searchService.stop()
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
        let find = item("Find Documents…", #selector(showFind), "f")
        find.isEnabled = !settings.project.isEmpty && settings.backendReady
        let add = item("Add Folder as Knowledge Base…", #selector(addKBFolder), "")
        add.isEnabled = !kbPrep.isRunning && !preparer.isRunning && settings.backendReady
        return [projectItem, load, find, add, prep]
    }

    private func overlayItems() -> [NSMenuItem] {
        [item(panel.isVisible ? "Hide Overlay" : "Show Overlay", #selector(togglePanel), ""),
         item("Reset Overlay Size", #selector(resetPanelSize), ""),
         { let it = item("Keep Overlay on Top", #selector(toggleKeepOnTop), ""); it.state = panel.level == .floating ? .on : .off; return it }()]
    }

    @objc func prepareKB() { preparer.startPrepare(settings) }

    /// "Load KB" alleen tonen als het nodig is: opnieuw controleren bij een ander project, na laden of omzetten,
    /// en als je naar HintMeet terugschakelt.
    private func watchKBStatus() {
        kbStatus.refresh()
        statusWatches = [
            settings.$project.dropFirst().sink { [weak self] _ in
                DispatchQueue.main.async { self?.kbStatus.refresh() }
            },
            preparer.$state.sink { [weak self] state in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch state {
                    case .running:
                        self.loadingProjects = self.settings.selectedProjects
                        self.loadingStarted = Date()
                    case .done:
                        self.kbStatus.markLoaded(self.loadingProjects, startedAt: self.loadingStarted)
                        // Find Documents alvast laden (de KB staat net in de cache), zodat zoeken direct werkt
                        if !self.backend.isRunning { self.searchService.ensureRunning() }
                    case .failed: self.kbStatus.refresh()
                    case .idle: break
                    }
                }
            },
            kbPrep.$state.sink { [weak self] state in   // Convert Documents kan een kennisbank wijzigen
                if case .done = state { DispatchQueue.main.async { self?.kbStatus.refresh() } }
            },
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification).sink { [weak self] _ in
                DispatchQueue.main.async { self?.kbStatus.refresh() }
            },
        ]
    }

    /// "Find Document": zoeken op inhoud in de gekozen kennisbank(en). De zoekdienst blijft draaien zolang
    /// het venster open is en stopt bij sluiten (geeft het geheugen van de geladen KB weer vrij).
    @objc func showFind() {
        if findWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "Find Documents"
            w.contentView = NSHostingView(rootView: FindView(search: searchService, settings: settings))
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("HintMeetFind")
            if w.frame.origin == .zero { w.center() }
            // sluiten laat de zoekdienst geladen: de volgende keer is Find Documents direct
            findWindow = w
        }
        searchService.ensureRunning()
        NSApp.activate(ignoringOtherApps: true)
        findWindow?.makeKeyAndOrderFront(nil)
    }


    /// "Add Folder…": een map wordt een kennisbank. kb_prep zet om (kan uren duren; Stop bewaart wat klaar is,
    /// Load KB op dat project gaat later verder), daarna wordt het project gekozen en volgt Load KB vanzelf.
    @objc func addKBFolder() {
        guard !kbPrep.isRunning, !preparer.isRunning else { return }
        let open = NSOpenPanel()
        open.title = "Add Folder as Knowledge Base"
        open.message = "HintMeet converts the documents in this folder into a knowledge base and embeds them. The first time this can take a long time (hours for very large folders); you can stop and continue later. After that, loading is fast."
        open.prompt = "Add"
        open.canChooseDirectories = true
        open.canChooseFiles = false
        NSApp.activate(ignoringOtherApps: true)
        guard open.runModal() == .OK, let url = open.url else { return }
        ingest(folder: url)
    }

    /// Map omzetten en daarna laden (ook gebruikt door HINT_MEET_ADD_FOLDER voor tests).
    func ingest(folder url: URL) {
        let source = url.resolvingSymlinksInPath().path   // zoals kb_prep het pad opslaat
        let project = projectName(for: source)
        settings.project = project   // de nieuwe kennisbank kiezen; Load KB gaat er later ook mee verder
        // één taak met fasen: documenten omzetten, model, lezen, woordindex, embeddings, spraakherkenning
        preparer.startIngest(settings, source: source, project: project)
        panel.orderFrontRegardless()
    }

    /// Projectnaam voor een map: zijn naam, of met -2, -3 … als die naam al bij een andere bronmap hoort.
    /// Dezelfde map nog eens kiezen gaat verder in zijn bestaande kennisbank.
    private func projectName(for source: String) -> String {
        let base = KBPrepView.projectName(for: source)
        var name = base, n = 2
        while let bound = sourceRoot(of: name), bound != source {
            name = "\(base)-\(n)"
            n += 1
        }
        return name
    }

    private func sourceRoot(of project: String) -> String? {
        let manifest = URL(fileURLWithPath: settings.kbRoot).appendingPathComponent(project)
            .appendingPathComponent("_manifest.json")
        guard let data = try? Data(contentsOf: manifest),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // map bestaat zonder manifest (bv. zelf gevuld): niet overschrijven, andere naam kiezen
            return FileManager.default.fileExists(atPath: manifest.deletingLastPathComponent().path) ? "" : nil
        }
        return json["source_root"] as? String ?? ""
    }
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

    /// Was Find Documents geladen voor de meeting begon? Dan na de meeting weer laden.
    private var searchWasWarm = false

    /// Een meeting laadt de kennisbank zelf: de zoekdienst stoppen spaart een tweede kopie in het geheugen.
    private func pauseSearchForMeeting() {
        searchWasWarm = searchService.isLoaded
        searchService.stop()
    }

    @objc func startMeeting() {
        pauseSearchForMeeting()
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
        pauseSearchForMeeting()
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

    @objc func showKBPrep() { openKBPrep(source: nil, project: nil) }

    func openKBPrep(source: String?, project: String?) {
        if kbPrepWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Convert Documents"
            w.contentView = NSHostingView(rootView: KBPrepView(settings: settings, task: kbPrep,
                                                               initialSource: source, initialProject: project))
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
                case .idle:
                    self.statusItem.button?.title = "💡"
                    if self.searchWasWarm {   // na de meeting Find Documents weer klaarzetten
                        self.searchWasWarm = false
                        self.searchService.ensureRunning()
                    }
                }
            }
        }
    }

    // MARK: paneel

    private static let frameName = "HintMeetOverlay"

    @objc func resetPanelSize() {
        var frame = panel.frame
        let top = frame.maxY
        frame.size = OverlayPanel.defaultSize
        frame.origin.y = top - frame.height
        panel.setFrame(frame, display: true, animate: true)
    }

    @objc func toggleKeepOnTop() {
        let onTop = panel.level != .floating
        panel.level = onTop ? .floating : .normal
        UserDefaults.standard.set(onTop, forKey: "keepOnTop")
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
