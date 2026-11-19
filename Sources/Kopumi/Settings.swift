// Settings window, first-launch Accessibility screen, and the small window helper they share.
import AppKit
import ServiceManagement
import SwiftUI

@MainActor
enum Windows {
  private static var open: [String: NSWindow] = [:]

  static func show(_ id: String, title: String, chromeless: Bool = false, _ view: some View) {
    let window =
      open[id]
      ?? {
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.title = title
        w.styleMask =
          chromeless ? [.titled, .closable, .fullSizeContentView] : [.titled, .closable]
        w.titlebarAppearsTransparent = chromeless
        w.isReleasedWhenClosed = false
        w.center()
        open[id] = w
        return w
      }()
    NSApp.activate()
    window.makeKeyAndOrderFront(nil)
  }

  static func close(_ id: String) { open[id]?.close() }

  /// Light / dark for all of Kopumi's windows; "system" (nil) follows macOS.
  static func applyAppearance() {
    let name: NSAppearance.Name? =
      switch UserDefaults.standard.string(forKey: Prefs.appearanceKey) {
      case "light": .aqua
      case "dark": .darkAqua
      default: nil
      }
    NSApp.appearance = name.flatMap(NSAppearance.init(named:))
  }

  /// Accessory apps have no menu bar, but text fields need an Edit menu for ⌘C / ⌘V / ⌘A / ⌘Z.
  static func installEditMenu() {
    let edit = NSMenu(title: "Edit")
    let items: [(String, Selector, String)] = [
      ("Undo", Selector(("undo:")), "z"), ("Redo", Selector(("redo:")), "Z"),
      ("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"),
      ("Paste", #selector(NSText.paste(_:)), "v"),
      ("Select All", #selector(NSText.selectAll(_:)), "a"),
      ("Close Window", #selector(NSWindow.performClose(_:)), "w"),
    ]
    for (title, action, key) in items {
      edit.addItem(withTitle: title, action: action, keyEquivalent: key)
    }
    let root = NSMenuItem()
    root.submenu = edit
    let main = NSMenu()
    main.addItem(root)
    NSApp.mainMenu = main
  }
}

func appDisplayName(_ bundle: String?) -> String? {
  guard let bundle, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
  else { return nil }
  return FileManager.default.displayName(atPath: url.path).replacingOccurrences(
    of: ".app", with: "")
}

/// Settings state that isn't a stored preference. ObservableObject, not @State: SwiftUI's @State is
/// a macro on this SDK and the Command Line Tools don't ship its plugin.
@MainActor
final class SettingsModel: ObservableObject {
  @Published var openAtLogin = SMAppService.mainApp.status == .enabled
  @Published var loginNote: String?
  @Published var testing = false
  @Published var testResult: String?

  func setLogin(_ on: Bool) {
    do {
      if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
      loginNote = nil
    } catch {
      loginNote = error.localizedDescription
    }
    if SMAppService.mainApp.status == .requiresApproval {
      loginNote = "Approve Kopumi in System Settings → General → Login Items."
      SMAppService.openSystemSettingsLoginItems()
    }
    openAtLogin = SMAppService.mainApp.status == .enabled
  }

  func test(_ command: String) {
    testing = true
    testResult = nil
    Task {
      let start = ContinuousClock.now
      do {
        let reply = try await CloudAI.run("Reply with only the word OK.", command: command)
        let seconds = (ContinuousClock.now - start).components.seconds
        testResult = "Replied “\(reply.prefix(60))” in \(seconds) s."
      } catch {
        testResult = error.localizedDescription
      }
      testing = false
    }
  }
}

struct SettingsView: View {
  @AppStorage(Prefs.maxItemsKey) private var maxItems = 500
  @AppStorage(Prefs.appearanceKey) private var appearance = "system"
  @AppStorage(Prefs.holdDelayKey) private var holdDelay = 300
  @AppStorage(Prefs.secretMinutesKey) private var secretMinutes = 10
  @AppStorage(Prefs.ignoredAppsKey) private var ignoredApps = ""
  @AppStorage(CloudAI.commandKey) private var cloudCommand = CloudAI.presets[0].command
  @StateObject private var model = SettingsModel()

  private var apps: [String] { ignoredApps.split(separator: "\n").map(String.init) }

  var body: some View {
    Form {
      Section("General") {
        Picker("Appearance", selection: $appearance) {
          Text("System").tag("system")
          Text("Light").tag("light")
          Text("Dark").tag("dark")
        }
        .onChange(of: appearance) { Windows.applyAppearance() }
        Toggle("Open at login", isOn: Binding(get: { model.openAtLogin }, set: model.setLogin))
        if let loginNote = model.loginNote { note(loginNote) }
        Picker("Keep history", selection: $maxItems) {
          ForEach([100, 500, 1000, 5000], id: \.self) { Text("\($0) clips") }
        }
        LabeledContent("Hold ⌘V to open") {
          Slider(
            value: Binding(get: { Double(holdDelay) }, set: { holdDelay = Int($0) }),
            in: 200...800, step: 50)
          Text("\(holdDelay) ms").monospacedDigit().frame(width: 56, alignment: .trailing)
        }
      }
      Section("Privacy") {
        Picker("Delete secrets after", selection: $secretMinutes) {
          ForEach([1, 5, 10, 30, 60], id: \.self) { Text("\($0) min") }
        }
        ForEach(apps, id: \.self) { id in
          LabeledContent(appDisplayName(id) ?? id) { Button("Remove") { removeApp(id) } }
        }
        LabeledContent("Never record copies from") { Button("Add App…", action: addApp) }
        note("Password managers are always ignored.")
      }
      cloudSection
    }
    .formStyle(.grouped)
    .frame(width: 520)
    .fixedSize(horizontal: false, vertical: true)
  }

  private var cloudSection: some View {
    Section("Cloud AI") {
      TextField(
        "Command", text: $cloudCommand, prompt: Text("Off: no cloud actions"), axis: .vertical
      )
      .labelsHidden()
      .font(.system(.body, design: .monospaced))
      HStack {
        Menu("Presets") {
          ForEach(CloudAI.presets, id: \.name) { p in Button(p.name) { cloudCommand = p.command } }
          Divider()
          Button("Off") { cloudCommand = "" }
        }
        .fixedSize()
        Button(model.testing ? "Testing…" : "Test") { model.test(cloudCommand) }
          .disabled(model.testing || cloudCommand.trimmingCharacters(in: .whitespaces).isEmpty)
        Spacer()
      }
      if let testResult = model.testResult { note(testResult) }
      note("Runs in your login shell. Kopumi sends the prompt on stdin and uses what it prints.")
    }
  }

  private func note(_ text: String) -> some View {
    Text(text).font(.caption).foregroundStyle(.secondary)
  }

  private func addApp() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.application]
    panel.directoryURL = URL(fileURLWithPath: "/Applications")
    guard panel.runModal() == .OK, let url = panel.url,
      let id = Bundle(url: url)?.bundleIdentifier, !apps.contains(id)
    else { return }
    ignoredApps = (apps + [id]).joined(separator: "\n")
  }

  private func removeApp(_ id: String) {
    ignoredApps = apps.filter { $0 != id }.joined(separator: "\n")
  }

}

/// Shown while Kopumi lacks Accessibility access; closes itself once access is granted.
struct OnboardingView: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Kopumi").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.muted)
      Text("One permission, then you're set.").font(.system(size: 22, weight: .semibold))
      Text(
        "Kopumi needs Accessibility access to notice when you hold ⌘V and to paste a clip "
          + "for you. It looks only at ⌘V and ⌘C. Nothing you type is recorded."
      )
      .lineSpacing(3)
      VStack(alignment: .leading, spacing: 8) {
        step(1, "Click Open Settings")
        step(2, "Switch on Kopumi")
        step(3, "Come back. This window closes by itself")
      }
      Button(action: requestAccess) {
        Text("Open Settings").fontWeight(.semibold).foregroundStyle(Theme.surface)
          .padding(.horizontal, 16).padding(.vertical, 8)
          .background(Theme.ink, in: .rect(cornerRadius: 2))
      }
      .buttonStyle(.plain)
    }
    .font(.system(size: 13))
    .foregroundStyle(Theme.ink)
    .padding(.horizontal, 32).padding(.top, 36).padding(.bottom, 28)
    .frame(width: 460, alignment: .leading)
    .background(Theme.surface)
  }

  private func step(_ n: Int, _ text: String) -> some View {
    HStack(spacing: 12) {
      Text("\(n)").monospacedDigit().foregroundStyle(Theme.muted)
      Text(text)
    }
  }

  private func requestAccess() {
    _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    if let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    {
      NSWorkspace.shared.open(url)
    }
  }
}
