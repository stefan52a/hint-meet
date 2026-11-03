import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Instellingen → Phone: de telefoon-companion aan/uit, de koppel-QR en een nieuwe koppeling.
struct PhoneSettingsView: View {
    @ObservedObject var settings: Settings
    /// nil in een tweede HintMeet: alleen de eerste heeft een gateway (poort 8790).
    let gateway: Gateway?
    @State private var confirmNewPairing = false
    @State private var pairingVersion = 0   // na "New pairing" de QR opnieuw maken

    var body: some View {
        Section("Phone") {
            if let gateway {
                PhoneGatewayView(settings: settings, gateway: gateway,
                                 confirmNewPairing: $confirmNewPairing, pairingVersion: $pairingVersion)
            } else {
                Text("Only the first HintMeet (without a number in the menu bar) can talk to the phone.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct PhoneGatewayView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var gateway: Gateway
    @Binding var confirmNewPairing: Bool
    @Binding var pairingVersion: Int

    var body: some View {
        Toggle("Allow phone companion", isOn: Binding(get: { settings.phoneEnabled },
                                                       set: { gateway.setEnabled($0) }))
        Text("The HintMeet app on your Android phone records the meeting and shows the hints; this Mac does the "
             + "work. Both need Tailscale. Only devices in your tailnet with the key from the QR code get in.")
            .font(.caption).foregroundStyle(.secondary)
        if settings.phoneEnabled {
            if let listening = gateway.listening {
                Text("Listening on \(listening)").font(.caption).foregroundStyle(.secondary)
            }
            if let problem = gateway.problem {
                Text(problem).font(.caption).foregroundStyle(.orange)
            }
            if gateway.listening != nil, let url = gateway.pairingURL() {
                HStack {
                    Spacer()
                    if let image = QRCode.image(url, side: 200) {
                        Image(nsImage: image)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 200, height: 200)
                            .accessibilityLabel("Pairing QR code")
                    }
                    Spacer()
                }
                .id(pairingVersion)
                Text("In the HintMeet app on the phone, tap Pair and scan this code.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("New pairing…") { confirmNewPairing = true }
                .alert("New pairing?", isPresented: $confirmNewPairing) {
                    Button("New Pairing", role: .destructive) {
                        gateway.newPairing()
                        pairingVersion += 1
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The phone that is paired now stops working until you scan the new code with it.")
                }
            Text("Keep this Mac on power with the lid open during phone meetings.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

enum QRCode {
    /// Scherpe QR: CoreImage maakt hem met één pixel per module; zonder smoothing opgeschaald.
    static func image(_ text: String, side: CGFloat) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let code = filter.outputImage else { return nil }
        // witte rand van 4 modules (de "quiet zone"): telefooncamera's vinden de code anders slecht
        let quiet: CGFloat = 4
        let framed = code.transformed(by: CGAffineTransform(translationX: quiet, y: quiet))
            .composited(over: CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0,
                                                                        width: code.extent.width + 2 * quiet,
                                                                        height: code.extent.height + 2 * quiet)))
        let scale = max(1, floor(side / framed.extent.width))
        let scaled = framed.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
