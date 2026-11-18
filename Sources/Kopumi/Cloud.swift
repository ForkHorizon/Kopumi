// Cloud actions: run the user's own AI CLI (Codex, Claude Code, …) on their subscription.
import AppKit

struct CloudError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

enum CloudAI {
  /// Prompt goes in on stdin, the answer comes back on stdout. Model/reasoning come from the CLI's config.
  static let presets: [(name: String, command: String)] = [
    ("Codex", "codex exec --skip-git-repo-check --sandbox read-only --ephemeral --color never -"),
    ("Claude Code", "claude -p --no-session-persistence --output-format text"),
  ]
  // ponytail: high-reasoning CLIs take 30 s+ even for tiny prompts; make this a setting if 5 min bites.
  static let timeout: Duration = .seconds(300)
  private static let commandKey = "cloudCommand"

  /// Empty = cloud actions off.
  static var command: String {
    get { UserDefaults.standard.string(forKey: commandKey) ?? presets[0].command }
    set { UserDefaults.standard.set(newValue, forKey: commandKey) }
  }
  static var isEnabled: Bool { !command.trimmingCharacters(in: .whitespaces).isEmpty }
  static var name: String {
    presets.first { $0.command == command }?.name
      ?? command.split(separator: " ").first.map(String.init) ?? "your CLI"
  }

  /// Asked once per CLI and action, because the clip's text leaves the Mac.
  static func hasConsent(_ actionID: String) -> Bool {
    UserDefaults.standard.bool(forKey: consentKey(actionID))
  }
  static func grantConsent(_ actionID: String) {
    UserDefaults.standard.set(true, forKey: consentKey(actionID))
  }
  private static func consentKey(_ id: String) -> String { "cloudConsent.\(command).\(id)" }

  static func describe(_ error: Error) -> String { error.localizedDescription }

  static func prompt(task: String, text: String) -> String {
    """
    You are a text tool inside a clipboard app. Do not run commands, read files or edit anything. \
    Reply with only the result: no preamble, no explanation, no code fences unless the result is code.

    Task: \(task)

    Text:
    \(text)
    """
  }

  /// Runs `command` through a login shell (so the user's PATH and CLI config apply) in an empty
  /// folder. Cancelling the task or hitting the timeout terminates the CLI.
  @concurrent
  static func run(_ prompt: String, command: String = command) async throws -> String {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kopumi-cloud")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-lc", "exec " + command]  // exec: terminate() reaches the CLI itself
    p.currentDirectoryURL = dir
    let (input, output, errors) = (Pipe(), Pipe(), Pipe())
    (p.standardInput, p.standardOutput, p.standardError) = (input, output, errors)
    try p.run()
    let killer = Task {
      try await Task.sleep(for: timeout)
      p.terminate()
    }
    defer { killer.cancel() }
    try input.fileHandleForWriting.write(contentsOf: Data(prompt.utf8))
    try input.fileHandleForWriting.close()
    let (out, err) = await withTaskCancellationHandler {
      async let out = readAll(output.fileHandleForReading)
      async let err = readAll(errors.fileHandleForReading)
      return await (out, err)
    } onCancel: {
      p.terminate()
    }
    p.waitUntilExit()
    try Task.checkCancellation()
    return try result(p, out, err)
  }

  private static func result(_ p: Process, _ out: Data, _ err: Data) throws -> String {
    if p.terminationReason == .uncaughtSignal {
      throw CloudError(message: "\(name) took longer than \(timeout) and was stopped.")
    }
    let text = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard p.terminationStatus == 0, !text.isEmpty else {
      let tail = String(decoding: err, as: UTF8.self).split(separator: "\n").suffix(3).joined(
        separator: " ")
      let hint = p.terminationStatus == 127 ? " Is it installed? Change it in the Kopumi menu." : ""
      throw CloudError(message: "\(name) failed (exit \(p.terminationStatus)).\(hint) \(tail)")
    }
    return text
  }

  // ponytail: blocks a pool thread per stream while the CLI runs; fine for one action at a time.
  @concurrent
  private static func readAll(_ h: FileHandle) async -> Data { (try? h.readToEnd()) ?? Data() }
}

/// Menu bar submenu: pick the CLI (or turn cloud actions off) and test it.
extension MenuController {
  func cloudMenuItem() -> NSMenuItem {
    let sub = NSMenu()
    let current = CloudAI.command
    let isPreset = CloudAI.presets.contains { $0.command == current }
    for p in CloudAI.presets {
      sub.addItem(
        item(p.name, #selector(chooseCloud(_:)), value: p.command, on: current == p.command))
    }
    sub.addItem(item("Custom Command…", #selector(customCloud), on: CloudAI.isEnabled && !isPreset))
    sub.addItem(item("Off", #selector(chooseCloud(_:)), value: "", on: !CloudAI.isEnabled))
    sub.addItem(.separator())
    let test = item("Test Connection", #selector(testCloud))
    test.isEnabled = CloudAI.isEnabled
    sub.addItem(test)
    let root = NSMenuItem(
      title: "Cloud AI: " + (CloudAI.isEnabled ? CloudAI.name : "Off"), action: nil,
      keyEquivalent: "")
    root.submenu = sub
    return root
  }

  private func item(_ title: String, _ action: Selector, value: String? = nil, on: Bool = false)
    -> NSMenuItem
  {
    let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
    i.target = self
    i.representedObject = value
    i.state = on ? .on : .off
    return i
  }

  @objc func chooseCloud(_ sender: NSMenuItem) {
    CloudAI.command = sender.representedObject as? String ?? ""
  }

  @objc func customCloud() {
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
    field.stringValue = CloudAI.command
    let alert = NSAlert()
    alert.messageText = "Cloud AI command"
    alert.informativeText =
      "Runs in your login shell. Kopumi sends the prompt on stdin and pastes what it prints."
    alert.accessoryView = field
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Cancel")
    NSApp.activate()
    if alert.runModal() == .alertFirstButtonReturn { CloudAI.command = field.stringValue }
  }

  @objc func testCloud() {
    let name = CloudAI.name
    Task {
      let start = ContinuousClock.now
      let message: String
      do {
        let reply = try await CloudAI.run("Reply with only the word OK.")
        message =
          "\(name) replied “\(reply.prefix(80))” in \((ContinuousClock.now - start).formatted(.units(allowed: [.seconds])))."
      } catch {
        message = error.localizedDescription
      }
      let alert = NSAlert()
      alert.messageText = "Cloud AI test"
      alert.informativeText = message
      NSApp.activate()
      alert.runModal()
    }
  }
}
