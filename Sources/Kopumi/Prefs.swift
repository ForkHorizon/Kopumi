// User settings (UserDefaults keys + typed accessors). The Settings window binds to the same keys.
import Foundation

enum Prefs {
  static let maxItemsKey = "maxItems"
  static let holdDelayKey = "holdDelayMs"
  static let secretMinutesKey = "secretMinutes"
  static let ignoredAppsKey = "ignoredApps"  // bundle ids, one per line
  static let pausedUntilKey = "pausedUntil"  // seconds since 1970; 0 = capturing

  static var maxItems: Int { int(maxItemsKey, 500) }
  static var holdDelay: Duration { .milliseconds(int(holdDelayKey, 300)) }
  static var secretTTL: Int64 { Int64(int(secretMinutesKey, 10)) * 60_000 }

  static var ignoredApps: [String] {
    get {
      (UserDefaults.standard.string(forKey: ignoredAppsKey) ?? "")
        .split(separator: "\n").map(String.init)
    }
    set { UserDefaults.standard.set(newValue.joined(separator: "\n"), forKey: ignoredAppsKey) }
  }

  static var pausedUntil: Date? {
    get {
      let t = UserDefaults.standard.double(forKey: pausedUntilKey)
      return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }
    set { UserDefaults.standard.set(newValue?.timeIntervalSince1970 ?? 0, forKey: pausedUntilKey) }
  }
  static var isPaused: Bool { (pausedUntil ?? .distantPast) > Date() }

  private static func int(_ key: String, _ fallback: Int) -> Int {
    UserDefaults.standard.object(forKey: key) as? Int ?? fallback
  }
}

/// Two presses of the same shortcut within `window` seconds count as a double press.
struct DoubleTap {
  var window: TimeInterval = 0.4
  private var last: TimeInterval?

  /// True on the second press of a pair; the pair is then consumed.
  mutating func press(at t: TimeInterval) -> Bool {
    if let last, t - last <= window {
      self.last = nil
      return true
    }
    last = t
    return false
  }
}
