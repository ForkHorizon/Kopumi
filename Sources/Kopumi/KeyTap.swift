// Global keyboard tap and the Cmd+V tap-vs-hold state machine.
import AppKit
import Synchronization

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
///
/// The tap is an active filter: macOS holds every keystroke (and the mouse events queued behind
/// it) until the callback answers. So it runs on its own thread, never the main thread: if the
/// UI stalls (rendering, search, database), system-wide input must not stall with it.
/// All tap state below is touched only on that thread; the main thread talks to it via `onTapThread`.
enum KeyTap {
  /// Virtual key codes (kVK_ANSI_V, kVK_ANSI_C).
  static let vKeyCode: CGKeyCode = 9
  static let cKeyCode: CGKeyCode = 8
  /// Tag on our synthetic events so the tap lets them through untouched.
  static let marker: Int64 = 0x4B4F_5055  // "KOPU"
  /// Apps that read Cmd+V themselves (VMs, remote desktops) — never intercept there.
  static let passthroughApps: Set<String> = [
    "com.parallels.desktop.console", "com.vmware.fusion", "com.utmapp.UTM",
    "com.microsoft.rdc.macos",
  ]
  @MainActor static var onHold: () -> Void = {}
  @MainActor static var onDoubleCopy: () -> Void = {}

  // Tap-thread state.
  nonisolated(unsafe) private static var port: CFMachPort?
  nonisolated(unsafe) private static var loop: CFRunLoop?
  nonisolated(unsafe) private static var machine = HoldMachine()
  nonisolated(unsafe) private static var copyTap = DoubleTap()
  nonisolated(unsafe) private static var holdTimer: CFRunLoopTimer?
  /// Frontmost app, written on the main thread by a workspace notification, read on the tap thread.
  private static let frontmost = Mutex<String?>(nil)

  /// Creates the tap and its thread. False without Accessibility access (call again later).
  @MainActor
  static func start() -> Bool {
    let mask = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) {
      $0 | 1 << $1.rawValue
    }
    guard
      let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
        eventsOfInterest: mask,
        callback: { _, type, event, _ in KeyTap.handle(type, event) },
        userInfo: nil)
    else { return false }
    port = tap
    trackFrontmostApp()
    let thread = Thread {
      KeyTap.loop = CFRunLoopGetCurrent()
      if let port = KeyTap.port {
        CFRunLoopAddSource(
          CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
      }
      CFRunLoopRun()
    }
    thread.name = "Kopumi key tap"
    thread.qualityOfService = .userInteractive
    thread.start()
    return true
  }

  /// Runs on the tap thread for every key event. Must answer fast and never wait on the main thread.
  private static func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
    let pass = Unmanaged.passUnretained(event)
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      // Logged so a freeze leaves evidence; re-enabled so Kopumi keeps working.
      print(
        "⚠️ key tap disabled by macOS (\(type == .tapDisabledByTimeout ? "timeout" : "user input")), re-enabling"
      )
      if let port { CGEvent.tapEnable(tap: port, enable: true) }
      return pass
    }
    guard event.getIntegerValueField(.eventSourceUserData) != marker,
      let e = Self.event(type, event)
    else { return pass }
    if type == .keyDown, isPlainCmdC(event), copyTap.press(at: ProcessInfo.processInfo.systemUptime)
    {
      Task { @MainActor in onDoubleCopy() }  // observe only: the copy itself always goes through
    }
    return feed(e) ? nil : pass
  }

  private static func modifiers(_ e: CGEvent) -> CGEventFlags {
    e.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
  }

  private static func isPlainCmdC(_ e: CGEvent) -> Bool {
    e.getIntegerValueField(.keyboardEventKeycode) == Int64(cKeyCode)
      && modifiers(e) == .maskCommand && e.getIntegerValueField(.keyboardEventAutorepeat) == 0
  }

  private static func event(_ type: CGEventType, _ event: CGEvent) -> HoldMachine.Event? {
    let isV = event.getIntegerValueField(.keyboardEventKeycode) == Int64(vKeyCode)
    switch type {
    case .keyDown where isV:
      return .vDown(
        cmdOnly: modifiers(event) == .maskCommand,
        isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
    case .keyUp where isV: return .vUp
    case .keyDown: return .otherKeyDown
    case .flagsChanged where !event.flags.contains(.maskCommand): return .cmdReleased
    default: return nil
    }
  }

  /// Tap thread only. Returns whether to swallow the event.
  private static func feed(_ e: HoldMachine.Event) -> Bool {
    if machine.state == .idle, case .vDown = e,
      let app = frontmost.withLock({ $0 }), passthroughApps.contains(app)
    {
      return false
    }
    let (swallow, effect) = machine.handle(e)
    switch effect {
    case .none: break
    case .startTimer: startHoldTimer()
    case .pasteNative: postCmdV()
    case .openPanel: Task { @MainActor in onHold() }
    }
    return swallow
  }

  /// One-shot timer on the tap thread's run loop; a new press replaces a pending one.
  private static func startHoldTimer() {
    if let holdTimer { CFRunLoopTimerInvalidate(holdTimer) }
    let fire = CFAbsoluteTimeGetCurrent() + Prefs.holdDelaySeconds
    let timer = CFRunLoopTimerCreateWithHandler(nil, fire, 0, 0, 0) { _ in
      _ = KeyTap.feed(.timerFired)
    }
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .commonModes)
    holdTimer = timer
  }

  /// Called when the panel closes, so a lost V key-up can never leave Cmd+V stuck.
  @MainActor static func reset() { onTapThread { machine.reset() } }

  private static func onTapThread(_ work: @escaping () -> Void) {
    guard let loop else { return }
    CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue, work)
    CFRunLoopWakeUp(loop)
  }

  @MainActor private static func trackFrontmostApp() {
    let update: @Sendable () -> Void = {
      frontmost.withLock { $0 = NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    }
    update()
    NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { _ in update() }
  }

  /// Thread-safe: posting events needs no particular thread.
  static func postCmdV() {
    for down in [true, false] {
      let e = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: down)
      e?.flags = .maskCommand
      e?.setIntegerValueField(.eventSourceUserData, value: marker)
      e?.post(tap: .cghidEventTap)
    }
  }
}
