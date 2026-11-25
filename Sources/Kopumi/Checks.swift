// Self-checks: `Kopumi --check` (logic, no UI) and `Kopumi --check-ai` (real on-device models).
import AppKit

/// Uses precondition (not assert) so the checks also fail in release builds.
@MainActor
func runChecks() throws {
  checkClassifier()
  checkHoldMachine()
  checkPasteAndActions()
  checkSearchSyntax()
  checkCapture()
  checkPrefsAndAppend()
  checkKeyTapOffMain()
  checkAppearance()
  checkInputSafety()
  try checkStoreBasics()
  try checkStoreSearchAndEnrichment()
  try checkSync()
  print("checks passed")
}

private func checkClassifier() {
  let kinds: [(String, ClipKind)] = [
    ("https://example.com/a?b=1", .url),
    ("me@example.com", .email),
    ("#ff8800", .color),
    ("rgb(10, 20, 30)", .color),
    (#"{"a": [1, 2]}"#, .json),
    ("[not json", .text),
    ("func foo() {\n    return 1\n}", .code),
    ("name\tage\nbob\t3", .table),
    ("Hello there, how are you doing today?", .text),
  ]
  for (s, want) in kinds {
    let got = classify(s).kind
    precondition(got == want, "classify(\(s.debugDescription)) = \(got), want \(want)")
  }
  precondition(classify("a\nb", sourceApp: "com.apple.dt.Xcode").kind == .code)

  let secrets = [
    "sk-ant-api03-abcdefghijklmnopqrstuvwxyz", "AKIAIOSFODNN7EXAMPLE", "4111 1111 1111 1111",
    "ghp_" + String(repeating: "a", count: 36), "-----BEGIN OPENSSH PRIVATE KEY-----",
  ]
  for s in secrets { precondition(isSensitive(s), "should be sensitive: \(s)") }
  for s in ["hello world", "4111 1111 1111 1112", "call me at 415 555 0132"] {
    precondition(!isSensitive(s), "should not be sensitive: \(s)")
  }

  let a = uuidv7(now: 1_000)
  let b = uuidv7(now: 2_000)
  precondition(a.count == 36 && Array(a)[14] == "7" && a < b, "uuidv7 \(a) \(b)")
}

/// Every Cmd+V path must end in a paste, the panel, or a pass-through.
private func checkHoldMachine() {
  func run(_ events: [HoldMachine.Event]) -> [String] {
    var m = HoldMachine()
    let steps = events.map { e in
      let r = m.handle(e)
      return "\(r.swallow ? "S" : "P"):\(r.effect)"
    }
    return steps + ["\(m.state)"]
  }
  let down = HoldMachine.Event.vDown(cmdOnly: true, isRepeat: false)
  let rep = HoldMachine.Event.vDown(cmdOnly: true, isRepeat: true)
  let cases: [([HoldMachine.Event], [String])] = [
    ([down, .vUp], ["S:startTimer", "S:pasteNative", "idle"]),  // quick tap
    (
      [down, rep, .timerFired, rep, .vUp],
      ["S:startTimer", "S:none", "P:openPanel", "S:none", "S:none", "idle"]
    ),
    ([down, .cmdReleased, .vUp], ["S:startTimer", "P:pasteNative", "P:none", "idle"]),
    ([down, .otherKeyDown], ["S:startTimer", "P:pasteNative", "idle"]),
    ([.vDown(cmdOnly: false, isRepeat: false)], ["P:none", "idle"]),  // Cmd+Shift+V etc.
    ([.timerFired, .vUp], ["P:none", "P:none", "idle"]),  // stale timer
  ]
  for (events, want) in cases {
    let got = run(events)
    precondition(got == want, "hold machine \(events): \(got), want \(want)")
  }
}

private func checkPasteAndActions() {
  precondition(pasteStyle(for: "com.apple.Terminal", forcePlain: false) == .terminal)
  precondition(pasteStyle(for: "com.apple.dt.Xcode", forcePlain: false) == .plain)
  precondition(pasteStyle(for: "com.apple.TextEdit", forcePlain: false) == .asCopied)
  precondition(pasteStyle(for: "com.apple.TextEdit", forcePlain: true) == .plain)
  precondition(pasteText("ls -la\n\n", .terminal) == "ls -la")
  precondition(pasteText("a\n", .plain) == "a\n")
  precondition(hexRGBA("#f80") == [255, 136, 0, 255] && hexRGBA("#ff8800cc")?[3] == 204)
  precondition(hexRGBA("red") == nil)

  precondition(formatJSON(#"{"b":1,"a":[1, 2]}"#, pretty: false) == #"{"a":[1,2],"b":1}"#)
  precondition(formatJSON(#"{"a":1}"#, pretty: true)?.contains("\n") == true)
  precondition(formatJSON("nope", pretty: true) == nil)
  precondition(cleanURL("https://x.com/p?utm_source=a&id=3&fbclid=z") == "https://x.com/p?id=3")
  precondition(cleanURL("https://x.com/p?utm_source=a") == "https://x.com/p")
  precondition(hexToRGB("#ff8800") == "rgb(255, 136, 0)")
  precondition(hexToRGB("#ff880080") == "rgba(255, 136, 0, 0.50)")
  precondition(needsTitle(.code, "a\nb\nc\nd") && !needsTitle(.text, "short"))
  precondition(!needsTitle(.url, String(repeating: "x", count: 300)))
}

private func checkSearchSyntax() {
  let q = SearchQuery("type:url  App:Xcode is:today  foo bar")
  precondition(q.kind == .url && q.app == "xcode" && q.today && q.text == "foo bar", "\(q)")
  precondition(SearchQuery("type:bogus").text == "type:bogus", "unknown type stays text")
  precondition(fuse([["a", "b", "c"], ["b"]]) == ["b", "a", "c"], "rank fusion")
}

@MainActor
private func checkCapture() {
  let pb = NSPasteboard(name: .init("kopumi-check"))
  defer { pb.releaseGlobally() }
  pb.clearContents()
  pb.setString("https://example.com", forType: .string)
  precondition(Watcher.capture(pb, sourceApp: nil)?.kind == .url)
  precondition(Watcher.capture(pb, sourceApp: "com.1password.1password") == nil, "ignored app")
  pb.clearContents()
  pb.setString("secret", forType: .string)
  pb.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
  precondition(Watcher.capture(pb, sourceApp: nil) == nil, "concealed type")
}

private func textClip(_ t: String, secret: Bool = false) -> NewClip {
  NewClip(
    kind: .text, text: t, contentHash: "text:" + t, sensitive: secret,
    blobs: [("public.rtf", Data(t.utf8))])
}

/// Runs `body` against a throwaway database.
@MainActor
private func withTempStore(_ body: (Store) throws -> Void) throws {
  let path = NSTemporaryDirectory() + "kopumi-check-\(UUID()).sqlite"
  defer { try? FileManager.default.removeItem(atPath: path) }
  try body(try Store(path: path, deviceId: "check"))
}

@MainActor
private func checkStoreBasics() throws {
  try withTempStore { store in
    let idA = try store.upsert(textClip("A"), now: 1)
    try store.upsert(textClip("B"), now: 2)
    let idA2 = try store.upsert(textClip("A"), now: 3)
    precondition(idA2 == idA, "dedupe keeps id")
    let order = try store.recent(limit: 10).map(\.text)
    precondition(order == ["A", "B"], "recent order \(order)")
    let blob = try store.blobs(id: idA).first?.data
    precondition(blob == Data("A".utf8), "blob roundtrip")

    try store.prune(maxItems: 1, now: 4)
    let pruned = try store.recent(limit: 10).map(\.text)
    precondition(pruned == ["A"], "prune by count")

    try store.clearHistory(now: 5)
    let cleared = try store.recent(limit: 10)
    precondition(cleared.isEmpty, "clear")
    let blobsAfter = try store.blobs(id: idA)
    precondition(blobsAfter.isEmpty, "blobs dropped on clear")
    let idA3 = try store.upsert(textClip("A"), now: 6)
    precondition(idA3 != idA, "re-copy after clear is a new clip")

    try store.upsert(textClip("sk-secret", secret: true), now: 7)
    try store.prune(maxItems: 100, now: 7 + Store.sensitiveTTL + 1)
    let left = try store.recent(limit: 10).map(\.text)
    precondition(left == ["A"], "secret expired \(left)")
  }
}

@MainActor
private func checkStoreSearchAndEnrichment() throws {
  try withTempStore { store in
    try store.upsert(textClip("A"), now: 1)
    try store.upsert(textClip("SELECT * FROM users JOIN orders"), now: 2)
    try store.upsert(textClip("Café menu for Friday"), now: 3)
    // A failing query yields a sentinel, so every precondition below still fails on errors.
    @MainActor func hits(_ q: String) -> [String?] {
      (try? store.search(q, limit: 10).map(\.text)) ?? ["<search error>"]
    }
    precondition(hits("user ord") == ["SELECT * FROM users JOIN orders"], "prefix search")
    precondition(hits("cafe").count == 1, "diacritics-insensitive")
    precondition(hits(#"he"llo"#).isEmpty, "quotes are escaped")
    precondition(hits("  ").count == 3, "empty query = recent")
    precondition(hits("type:code").isEmpty, "kind filter")

    // OCR/title become searchable, embeddings round-trip, nothing left to enrich
    while let job = try store.nextToEnrich() {
      let isA = job.clip.text == "A"
      try store.saveEnrichment(
        id: job.clip.id, title: isA ? "Shopping list" : nil, ocr: isA ? "invoice total 42" : nil,
        embedding: ("m1", [0.6, 0.8]))
    }
    precondition(hits("invoice") == ["A"], "OCR searchable")
    let titled = try store.search("shopping", limit: 10).first?.label
    precondition(titled == "Shopping list", "title is label + searchable")
    let models = try store.embeddingModels()
    precondition(models == ["m1"], "embedding model stored")
    let vector = try store.embeddings(model: "m1").first?.vector
    precondition(vector == [0.6, 0.8], "vector roundtrip")

    try store.clearHistory(now: 12)
    precondition(hits("users").isEmpty, "cleared clips leave the index")
    precondition(hits("invoice").isEmpty, "cleared OCR leaves the index")
    let modelsAfter = try store.embeddingModels()
    precondition(modelsAfter.isEmpty, "embeddings dropped on clear")
  }
}

/// Exercises the real on-device models (embeddings, OCR, Foundation Models).
@MainActor
func runAIChecks() async {
  await checkEmbeddings()
  await checkOCR()
  await checkFoundationModels()
  print("ai checks done")
}

private func dot(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }

private func checkEmbeddings() async {
  let e = Embedder()
  guard let cat = await e.embed("My cat sleeps on the sofa all day"),
    let kitten = await e.embed("A kitten napping on the couch"),
    let revenue = await e.embed("Quarterly revenue grew by twelve percent")
  else { return print("✗ embeddings unavailable") }
  let near = dot(cat.vector, kitten.vector)
  let far = dot(cat.vector, revenue.vector)
  print(
    "embeddings (\(cat.model), dim \(cat.vector.count)): cat~kitten \(near), cat~revenue \(far)")
  precondition(near > far, "similar sentences must score higher")
  if let q = await e.embed("pet resting", modelID: cat.model) {
    print("query 'pet resting': cat \(dot(q, cat.vector)), revenue \(dot(q, revenue.vector))")
  }
  if let ru = await e.embed("Кошка спит на диване") { print("russian → model \(ru.model)") }
}

@MainActor
private func checkOCR() async {
  let img = NSImage(size: NSSize(width: 600, height: 120), flipped: false) { r in
    NSColor.white.setFill()
    r.fill()
    let attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 40), .foregroundColor: NSColor.black,
    ]
    ("Invoice total 4200 EUR" as NSString).draw(at: NSPoint(x: 20, y: 40), withAttributes: attrs)
    return true
  }
  guard let tiff = img.tiffRepresentation,
    let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
  else { return print("✗ could not render test image") }
  let text = await OCR.text(png)
  print("OCR:", text ?? "nil")
  precondition(text?.contains("4200") == true, "OCR should read the number")
}

private func checkFoundationModels() async {
  if let why = OnDeviceAI.unavailableReason { return print("Foundation Models:", why) }
  let sql = """
    SELECT u.name, count(o.id) FROM users u JOIN orders o ON o.user_id = u.id \
    GROUP BY u.name ORDER BY 2 DESC LIMIT 10
    """
  print("title:", await OnDeviceAI.title(for: sql) ?? "nil")
  do {
    let fixed = try await OnDeviceAI.respond(
      instructions: OnDeviceAI.actionInstructions,
      prompt: "Fix grammar, spelling and punctuation. Change nothing else.\n\n"
        + "Text:\nhe dont know were the meating is")
    print("fix grammar:", fixed)
  } catch {
    print("fix grammar failed:", OnDeviceAI.describe(error))
  }
}

/// Cloud runner plumbing with stand-in commands (no AI is called).
@MainActor
func checkCloud() async throws {
  let echoed = try await CloudAI.run("héllo\nworld", command: "cat")
  precondition(echoed == "héllo\nworld", "stdin → stdout: \(echoed)")
  for (command, expect) in [("exit 3", "exit 3"), ("kopumi-no-such-cli-xyz", "Is it installed?")] {
    do {
      _ = try await CloudAI.run("x", command: command)
      preconditionFailure("\(command) should fail")
    } catch {
      precondition(error.localizedDescription.contains(expect), "\(command): \(error)")
    }
  }
  let started = ContinuousClock.now
  let slow = Task { try await CloudAI.run("x", command: "sleep 30") }
  try await Task.sleep(for: .milliseconds(300))
  slow.cancel()
  let outcome = await slow.result
  precondition(ContinuousClock.now - started < .seconds(5), "cancel must kill the CLI")
  if case .success = outcome { preconditionFailure("cancelled run must throw") }

  let saved = CloudAI.command
  defer { CloudAI.command = saved }
  let text = Clip(
    id: "c", kind: .text, text: "hi", title: nil, sourceApp: nil, sensitive: false, lastUsedAt: 0)
  CloudAI.command = "cat"
  precondition(ClipAction.available(for: text).contains { $0.id == "cloud.summarize" })
  precondition(ClipAction.available(for: text).first { $0.id == "cloud.reply" }?.badge == "CAT")
  CloudAI.command = ""
  precondition(!ClipAction.available(for: text).contains { $0.id.hasPrefix("cloud.") }, "off")
  let secret = Clip(
    id: "s", kind: .text, text: "sk-x", title: nil, sourceApp: nil, sensitive: true, lastUsedAt: 0)
  CloudAI.command = "cat"
  precondition(ClipAction.available(for: secret).isEmpty, "secrets never get actions")
  precondition(CloudAI.prompt(task: "T1", text: "X2").contains("Task: T1\n\nText:\nX2"))
  print("cloud checks passed")
}

/// Double Cmd+C timing and merge rules, pause, user ignore list. Restores any prefs it touches.
@MainActor
private func checkPrefsAndAppend() {
  var tap = DoubleTap()
  let presses = [0, 0.3, 0.5, 1.5, 1.8].map { tap.press(at: $0) }
  precondition(presses == [false, true, false, false, true], "double tap \(presses)")

  func clip(_ text: String?, _ kind: ClipKind = .text, secret: Bool = false) -> Clip {
    Clip(
      id: text ?? "img", kind: kind, text: text, title: nil, sourceApp: "app", sensitive: secret,
      lastUsedAt: 0)
  }
  let merged = Watcher.appended(clip("first"), to: clip("second"))
  precondition(merged?.text == "first\nsecond" && merged?.derivedFrom == "first", "append")
  precondition(Watcher.appended(clip("same"), to: clip("same")) == nil, "no self-append")
  precondition(Watcher.appended(clip("a", secret: true), to: clip("b")) == nil, "no secrets")
  precondition(Watcher.appended(clip(nil, .image), to: clip("b")) == nil, "no images")

  let (savedPause, savedApps) = (Prefs.pausedUntil, Prefs.ignoredApps)
  defer { (Prefs.pausedUntil, Prefs.ignoredApps) = (savedPause, savedApps) }
  Prefs.pausedUntil = Date().addingTimeInterval(60)
  precondition(Prefs.isPaused, "paused")
  Prefs.pausedUntil = Date().addingTimeInterval(-1)
  precondition(!Prefs.isPaused, "pause expired")
  Prefs.pausedUntil = nil
  precondition(!Prefs.isPaused, "resumed")

  Prefs.ignoredApps = ["com.example.diary"]
  let pb = NSPasteboard(name: .init("kopumi-check-prefs"))
  defer { pb.releaseGlobally() }
  pb.clearContents()
  pb.setString("dear diary", forType: .string)
  precondition(Watcher.capture(pb, sourceApp: "com.example.diary") == nil, "user-ignored app")
  precondition(Watcher.capture(pb, sourceApp: "com.example.notes") != nil, "other apps captured")
}

/// Smoke check: the tap callback (handle → feed, double-Cmd+C detection) runs off the main thread.
/// Calling it directly does not reproduce the isolation trap macOS's real event delivery hit, so
/// the guard against that is structural: `KeyTap.callback` is declared outside any @MainActor code.
/// Only harmless events: a plain "A" and Cmd+C (Cmd+V would post a real paste).
private func checkKeyTapOffMain() {
  let done = DispatchSemaphore(value: 0)
  nonisolated(unsafe) var passed = 0
  Thread {
    for (key, flags) in [(CGKeyCode(0), CGEventFlags()), (KeyTap.cKeyCode, .maskCommand)] {
      guard let e = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true) else {
        continue
      }
      e.flags = flags
      if KeyTap.callback(OpaquePointer(bitPattern: 1)!, .keyDown, e, nil) != nil { passed += 1 }
    }
    done.signal()
  }.start()
  done.wait()
  precondition(passed == 2, "tap callback must pass plain keys through off the main thread")
}

/// Each Appearance choice sets the app-wide appearance; "system" clears it. Restores the pref.
@MainActor
private func checkAppearance() {
  _ = NSApplication.shared
  let saved = UserDefaults.standard.string(forKey: Prefs.appearanceKey)
  defer {
    UserDefaults.standard.set(saved, forKey: Prefs.appearanceKey)
    Windows.applyAppearance()
  }
  for (choice, want) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
    UserDefaults.standard.set(choice, forKey: Prefs.appearanceKey)
    Windows.applyAppearance()
    precondition(NSApp.appearance?.name == want, "appearance \(choice)")
  }
  UserDefaults.standard.set("system", forKey: Prefs.appearanceKey)
  Windows.applyAppearance()
  precondition(NSApp.appearance == nil, "system follows macOS")
}

/// Synthetic pastes must never suppress the real keyboard/mouse, and the timeout fuse must trip
/// only on repeated timeouts within its window.
private func checkInputSafety() {
  guard let source = KeyTap.pasteSource() else { preconditionFailure("paste event source") }
  precondition(source.localEventsSuppressionInterval == 0, "no input suppression after a paste")
  let permitted = source.getLocalEventsFilterDuringSuppressionState(
    .eventSuppressionStateSuppressionInterval)
  precondition(
    permitted.contains([.permitLocalMouseEvents, .permitLocalKeyboardEvents]),
    "real keyboard and mouse stay live during a synthetic paste")

  var fuse = TapFuse(limit: 3, window: 60)
  let trips = [0, 10, 100, 110, 115].map { fuse.trip(at: $0) }
  precondition(trips == [false, false, false, false, true], "fuse \(trips)")

  // A deleted executable (rebuild/update under the running app) must be noticed at once.
  let file = NSTemporaryDirectory() + "kopumi-watch-\(getpid())"
  FileManager.default.createFile(atPath: file, contents: nil)
  let gone = DispatchSemaphore(value: 0)
  let watch = KeyTap.watchFileGone(file) { gone.signal() }
  precondition(watch != nil, "watch executable")
  try? FileManager.default.removeItem(atPath: file)
  precondition(gone.wait(timeout: .now() + 2) == .success, "deleted executable noticed")
  watch?.cancel()
}
