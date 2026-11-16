// Global keyboard tap and the Cmd+V tap-vs-hold state machine.
import AppKit

/// Cmd+V: quick tap = native paste, hold = open the panel. Pure state machine so it can be checked.
struct HoldMachine {
  enum Event: Equatable {
    case vDown(cmdOnly: Bool, isRepeat: Bool)
    case vUp, cmdReleased, otherKeyDown, timerFired
  }
  enum Effect: Equatable { case none, startTimer, pasteNative, openPanel }
  enum State { case idle, pending, holding }

  private(set) var state = State.idle

  mutating func reset() { state = .idle }

  /// Whether to swallow the event, and what to do about it.
  mutating func handle(_ e: Event) -> (swallow: Bool, effect: Effect) {
    switch (state, e) {
    case (.idle, .vDown(cmdOnly: true, isRepeat: false)):
      state = .pending
      return (true, .startTimer)
    case (.idle, _):
      return (false, .none)
    case (.pending, .vDown):  // autorepeat while deciding
      return (true, .none)
    case (.pending, .vUp):
      state = .idle
      return (true, .pasteNative)
    // ponytail: the other key reaches the app before our synthetic paste; rare, fix if anyone notices.
    case (.pending, .cmdReleased), (.pending, .otherKeyDown):
      state = .idle
      return (false, .pasteNative)
    case (.pending, .timerFired):
      state = .holding
      return (false, .openPanel)
    case (.holding, .vDown):
      return (true, .none)
    case (.holding, .vUp):
      state = .idle
      return (true, .none)
    case (.holding, _):
      return (false, .none)
    }
  }
}

/// Global keyboard tap. Needs Accessibility permission.
enum KeyTap {
  /// Tag on our synthetic events so the tap lets them through untouched.
  /// Virtual key code of V (kVK_ANSI_V).
  static let vKeyCode: CGKeyCode = 9
  static let marker: Int64 = 0x4B4F_5055  // "KOPU"
  // ponytail: constant; becomes a setting in M5.
  static let holdDelay = Duration.milliseconds(300)
  /// Apps that read Cmd+V themselves (VMs, remote desktops) — never intercept there.
  static let passthroughApps: Set<String> = [
    "com.parallels.desktop.console", "com.vmware.fusion", "com.utmapp.UTM",
    "com.microsoft.rdc.macos",
  ]
  nonisolated(unsafe) static var port: CFMachPort?
  @MainActor static var machine = HoldMachine()
  @MainActor static var timer: Task<Void, Never>?
  @MainActor static var onHold: () -> Void = {}

  static func start() -> Bool {
    let mask = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) {
      $0 | 1 << $1.rawValue
    }
    guard
      let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
        eventsOfInterest: mask,
        callback: { _, type, event, _ in
          let pass = Unmanaged.passUnretained(event)
          // macOS disables slow/interrupted taps; turn it straight back on.
          if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let p = KeyTap.port { CGEvent.tapEnable(tap: p, enable: true) }
            return pass
          }
          guard event.getIntegerValueField(.eventSourceUserData) != KeyTap.marker,
            let e = KeyTap.event(type, event)
          else { return pass }
          // The tap runs on the main run loop.
          let swallow = MainActor.assumeIsolated { KeyTap.feed(e) }
          return swallow ? nil : pass
        },
        userInfo: nil
      )
    else { return false }
    port = tap
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    return true
  }

  private static func event(_ type: CGEventType, _ event: CGEvent) -> HoldMachine.Event? {
    let isV = event.getIntegerValueField(.keyboardEventKeycode) == Int64(vKeyCode)
    switch type {
    case .keyDown where isV:
      let mods = event.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
      return .vDown(
        cmdOnly: mods == .maskCommand,
        isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
    case .keyUp where isV: return .vUp
    case .keyDown: return .otherKeyDown
    case .flagsChanged where !event.flags.contains(.maskCommand): return .cmdReleased
    default: return nil
    }
  }

  @MainActor
  static func feed(_ e: HoldMachine.Event) -> Bool {
    if machine.state == .idle, case .vDown = e,
      let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
      passthroughApps.contains(app)
    {
      return false
    }
    let (swallow, effect) = machine.handle(e)
    switch effect {
    case .none: break
    case .startTimer:
      timer?.cancel()
      timer = Task {
        try? await Task.sleep(for: holdDelay)
        if !Task.isCancelled { _ = feed(.timerFired) }
      }
    case .pasteNative: postCmdV()
    case .openPanel: onHold()
    }
    return swallow
  }

  /// Called when the panel closes, so a lost V key-up can never leave Cmd+V stuck.
  @MainActor static func reset() { machine.reset() }

  static func postCmdV() {
    for down in [true, false] {
      let e = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: down)
      e?.flags = .maskCommand
      e?.setIntegerValueField(.eventSourceUserData, value: marker)
      e?.post(tap: .cghidEventTap)
    }
  }
}
