import Foundation
import ServiceManagement

/// Achtergronddienst HintMeetWaker aan of uit: een gewone LaunchAgent in ~/Library/LaunchAgents die het programma
/// in deze app start (vast pad, blijft geldig na een nieuwe build; build-app.sh herstart hem dan). Aan: launchd
/// start hem bij het inloggen en houdt hem in leven; hij start HintMeet als de telefoon aanklopt.
enum PhoneWake {
    static let label = "com.zoof-it.hintmeet.waker"
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static var program: String { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/HintMeetWaker").path }
    private static var domain: String { "gui/\(getuid())" }

    /// Geeft een melding voor in de instellingen, of nil als alles in orde is.
    @MainActor
    static func update(on: Bool) -> String? {
        if GatewayTestMode.active { return nil }   // testbuild buiten een app-bundel: niets aanmelden
        cleanUpOldRegistration()
        if on {
            guard FileManager.default.isExecutableFile(atPath: program) else {
                return "The background helper is missing from this build of HintMeet; build it with app/build-app.sh."
            }
            let plist: [String: Any] = ["Label": label, "ProgramArguments": [program], "RunAtLoad": true,
                                        "KeepAlive": true, "ProcessType": "Background"]
            do {
                try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                if (try? Data(contentsOf: plistURL)) != data {
                    try data.write(to: plistURL, options: .atomic)
                    launchctl("bootout", "\(domain)/\(label)")   // oude versie eruit, dan de nieuwe erin
                }
            } catch {
                return "Couldn't set up starting from the phone while HintMeet is closed: \(error.localizedDescription)"
            }
            if launchctl("print", "\(domain)/\(label)") != 0, launchctl("bootstrap", domain, plistURL.path) != 0 {
                return "Couldn't start the background helper (launchctl bootstrap failed)."
            }
        } else {
            launchctl("bootout", "\(domain)/\(label)")
            try? FileManager.default.removeItem(at: plistURL)
        }
        return nil
    }

    @discardableResult
    private static func launchctl(_ args: String...) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// Een eerdere versie meldde de dienst aan via SMAppService (aan het app-bundel gebonden, brak bij elke build).
    private static func cleanUpOldRegistration() {
        let old = SMAppService.agent(plistName: "\(label).plist")
        if old.status != .notRegistered { try? old.unregister() }
    }
}
