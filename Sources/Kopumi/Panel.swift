// The floating Cmd+V panel window: show/hide, key handling, caret placement.
import AppKit
import SwiftUI

/// Borderless panel that takes keyboard focus without activating Kopumi,
/// so the app you're pasting into stays frontmost.
final class KopumiPanel: NSPanel {
  override var canBecomeKey: Bool { true }
}

/// Drag handle on the panel's bottom edge, right edge or bottom-right corner: a borderless
/// window's own resize zone is too thin to grab. The top-left corner stays put.
final class ResizeGrip: NSView {
  private let position: NSCursor.FrameResizePosition

  init(_ position: NSCursor.FrameResizePosition, frame: NSRect, mask: NSView.AutoresizingMask) {
    self.position = position
    super.init(frame: frame)
    autoresizingMask = mask
  }

  required init?(coder: NSCoder) { nil }

  /// `content` filling a container, with grips laid over its edges.
  static func wrap(_ content: NSView) -> NSView {
    let size = NSSize(width: 720, height: 400)
    let box = NSView(frame: NSRect(origin: .zero, size: size))
    content.frame = box.bounds
    content.autoresizingMask = [.width, .height]
    box.addSubview(content)
    let t: CGFloat = 8
    box.addSubview(
      ResizeGrip(
        .bottom, frame: NSRect(x: 0, y: 0, width: size.width, height: t),
        mask: [.width, .maxYMargin]))
    box.addSubview(
      ResizeGrip(
        .right, frame: NSRect(x: size.width - t, y: 0, width: t, height: size.height),
        mask: [.height, .minXMargin]))
    box.addSubview(
      ResizeGrip(
        .bottomRight, frame: NSRect(x: size.width - 2 * t, y: 0, width: 2 * t, height: 2 * t),
        mask: [.minXMargin, .maxYMargin]))
    return box
  }

  override var mouseDownCanMoveWindow: Bool { false }
  /// Claims the drag; without it the panel background would move the window instead.
  override func mouseDown(with event: NSEvent) {}

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .frameResize(position: position, directions: .all))
  }

  override func mouseDragged(with e: NSEvent) {
    guard let w = window else { return }
    var f = w.frame
    let min = w.contentMinSize
    if position != .bottom { f.size.width = max(min.width, f.width + e.deltaX) }
    if position != .right {
      let h = max(min.height, f.height + e.deltaY)  // deltaY > 0 means the mouse moved down
      f.origin.y += f.height - h
      f.size.height = h
    }
    w.setFrame(f, display: true)
  }
}

@MainActor
final class PanelController {
  let model: PanelModel
  private let panel: KopumiPanel
  private var monitor: Any?

  init(store: Store, embedder: Embedder) {
    model = PanelModel(store: store, embedder: embedder)
    panel = KopumiPanel(
      contentRect: NSRect(x: 0, y: 0, width: 720, height: 400),
      styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: true)
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.isMovableByWindowBackground = true
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
    let host = NSHostingView(rootView: PanelView(model: model))
    host.sizingOptions = []  // the panel owns its size; SwiftUI content never grows it
    panel.contentView = ResizeGrip.wrap(host)
    panel.contentMinSize = NSSize(width: 560, height: 300)
    panel.setFrameAutosaveName("KopumiPanel")  // drag any edge to resize; the size is remembered
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
    panel.setFrame(placement(), display: false)
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
    case 43 where flags.contains(.command): model.openSettings()  // ⌘,
    default:
      guard flags.contains(.command), let n = Int(chars), (1...9).contains(n) else { return false }
      model.paste(n - 1)
    }
    return true
  }

  /// Below the text caret if the app exposes it, else at the mouse; kept on screen.
  private func placement() -> NSRect {
    // AX rects are top-left based; Cocoa is bottom-left.
    let anchor =
      caretRect().map { r in
        NSPoint(x: r.minX, y: (NSScreen.screens.first?.frame.height ?? 0) - r.maxY)
      } ?? NSEvent.mouseLocation
    let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
    guard let vf = screen?.visibleFrame.insetBy(dx: 8, dy: 8) else { return panel.frame }
    // Never bigger than the screen, so every edge stays reachable for resizing.
    let size = NSSize(
      width: min(panel.frame.width, vf.width), height: min(panel.frame.height, vf.height))
    var o = NSPoint(x: anchor.x, y: anchor.y - size.height - 6)
    if o.y < vf.minY { o.y = anchor.y + 28 }  // no room below → above the caret
    o.x = min(max(o.x, vf.minX), vf.maxX - size.width)
    o.y = min(max(o.y, vf.minY), vf.maxY - size.height)
    return NSRect(origin: o, size: size)
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
