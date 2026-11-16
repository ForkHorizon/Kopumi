// The floating Cmd+V panel window: show/hide, key handling, caret placement.
import AppKit
import SwiftUI

/// Borderless panel that takes keyboard focus without activating Kopumi,
/// so the app you're pasting into stays frontmost.
final class KopumiPanel: NSPanel {
  override var canBecomeKey: Bool { true }
}

@MainActor
final class PanelController {
  let model: PanelModel
  private let panel: KopumiPanel
  private var monitor: Any?

  init(store: Store, embedder: Embedder) {
    model = PanelModel(store: store, embedder: embedder)
    panel = KopumiPanel(
      contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.isMovableByWindowBackground = true
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
    panel.contentView = NSHostingView(rootView: PanelView(model: model))
    model.close = { [weak self] in self?.hide() }
    NotificationCenter.default.addObserver(
      forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
    ) {
      [weak self] _ in MainActor.assumeIsolated { self?.hide() }  // click outside → close
    }
  }

  func show() {
    guard monitor == nil else { return }
    model.target = NSWorkspace.shared.frontmostApplication
    model.reset()
    panel.setFrameOrigin(origin())
    panel.makeKeyAndOrderFront(nil)
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
      let code = e.keyCode
      let flags = e.modifierFlags
      let chars = e.charactersIgnoringModifiers ?? ""
      let handled = MainActor.assumeIsolated { self?.handleKey(code, flags, chars) ?? false }
      return handled ? nil : e
    }
  }

  func hide() {
    guard let m = monitor else { return }
    NSEvent.removeMonitor(m)
    monitor = nil
    panel.orderOut(nil)
    KeyTap.reset()
  }

  /// Returns true when the key was ours (not typed into the search field).
  private func handleKey(_ code: UInt16, _ flags: NSEvent.ModifierFlags, _ chars: String) -> Bool {
    switch code {
    case 125: model.move(1)  // ↓
    case 126: model.move(-1)  // ↑
    case 48: model.toggleActions()  // ⇥
    case 36, 76: model.enter(forcePlain: flags.contains(.option))  // ↩ / enter
    case 53: if !model.back() { hide() }  // esc
    default:
      guard flags.contains(.command), let n = Int(chars), (1...9).contains(n) else { return false }
      model.paste(n - 1)
    }
    return true
  }

  /// Below the text caret if the app exposes it, else at the mouse; kept on screen.
  private func origin() -> NSPoint {
    // AX rects are top-left based; Cocoa is bottom-left.
    let anchor =
      caretRect().map { r in
        NSPoint(x: r.minX, y: (NSScreen.screens.first?.frame.height ?? 0) - r.maxY)
      } ?? NSEvent.mouseLocation
    let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
    guard let vf = screen?.visibleFrame else { return anchor }
    let size = panel.frame.size
    var o = NSPoint(x: anchor.x, y: anchor.y - size.height - 6)
    if o.y < vf.minY { o.y = anchor.y + 28 }  // no room below → above the caret
    o.x = min(max(o.x, vf.minX), vf.maxX - size.width)
    o.y = min(max(o.y, vf.minY), vf.maxY - size.height)
    return o
  }

  private func caretRect() -> CGRect? {
    let system = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(system, 0.1)  // never hang on a frozen app
    var focused: CFTypeRef?
    var range: CFTypeRef?
    var bounds: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused)
        == .success,
      let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
    else { return nil }
    let element = unsafeDowncast(focused, to: AXUIElement.self)  // type id checked above
    guard
      AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range)
        == .success,
      let range,
      AXUIElementCopyParameterizedAttributeValue(
        element, kAXBoundsForRangeParameterizedAttribute as CFString, range, &bounds) == .success,
      let bounds, CFGetTypeID(bounds) == AXValueGetTypeID()
    else { return nil }
    var rect = CGRect.zero
    let value = unsafeDowncast(bounds, to: AXValue.self)  // type id checked above
    guard AXValueGetValue(value, .cgRect, &rect), rect != .zero else { return nil }
    return rect
  }
}
