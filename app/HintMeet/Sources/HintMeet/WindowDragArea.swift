import AppKit
import SwiftUI

/// Achtergrond waarmee je het venster versleept (de kopbalk van het paneel). Elders in het paneel zijn
/// klikken voor de tekst, dus daar kan het niet meer.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ view: NSView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}
