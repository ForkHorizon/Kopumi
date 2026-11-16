import AppKit

/// Self-checks: `swift run Kopumi --check`. Uses precondition so it also fails in release builds.
@MainActor
func runChecks() {
    // Classifier
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

    // Sensitive guard
    for s in ["sk-ant-api03-abcdefghijklmnopqrstuvwxyz", "AKIAIOSFODNN7EXAMPLE", "4111 1111 1111 1111",
              "ghp_" + String(repeating: "a", count: 36), "-----BEGIN OPENSSH PRIVATE KEY-----"] {
        precondition(isSensitive(s), "should be sensitive: \(s)")
    }
    for s in ["hello world", "4111 1111 1111 1112", "call me at 415 555 0132"] {
        precondition(!isSensitive(s), "should not be sensitive: \(s)")
    }

    // Cmd+V hold state machine — every path must end in a paste, the panel, or a pass-through.
    func run(_ events: [HoldMachine.Event]) -> [String] {
        var m = HoldMachine()
        return events.map { let r = m.handle($0); return "\(r.swallow ? "S" : "P"):\(r.effect)" }
            + ["\(m.state)"]
    }
    let down = HoldMachine.Event.vDown(cmdOnly: true, isRepeat: false)
    let rep = HoldMachine.Event.vDown(cmdOnly: true, isRepeat: true)
    let cases: [([HoldMachine.Event], [String])] = [
        ([down, .vUp], ["S:startTimer", "S:pasteNative", "idle"]),                       // quick tap
        ([down, rep, .timerFired, rep, .vUp], ["S:startTimer", "S:none", "P:openPanel", "S:none", "S:none", "idle"]),
        ([down, .cmdReleased, .vUp], ["S:startTimer", "P:pasteNative", "P:none", "idle"]),  // Cmd let go first
        ([down, .otherKeyDown], ["S:startTimer", "P:pasteNative", "idle"]),
        ([.vDown(cmdOnly: false, isRepeat: false)], ["P:none", "idle"]),                    // Cmd+Shift+V etc.
        ([.timerFired, .vUp], ["P:none", "P:none", "idle"]),                                // stale timer
    ]
    for (events, want) in cases {
        let got = run(events)
        precondition(got == want, "hold machine \(events): \(got), want \(want)")
    }

    // Context-aware paste
    precondition(pasteStyle(for: "com.apple.Terminal", forcePlain: false) == .terminal)
    precondition(pasteStyle(for: "com.apple.dt.Xcode", forcePlain: false) == .plain)
    precondition(pasteStyle(for: "com.apple.TextEdit", forcePlain: false) == .asCopied)
    precondition(pasteStyle(for: "com.apple.TextEdit", forcePlain: true) == .plain)
    precondition(pasteText("ls -la\n\n", .terminal) == "ls -la")
    precondition(pasteText("a\n", .plain) == "a\n")
    precondition(hexRGBA("#f80") == [255, 136, 0, 255] && hexRGBA("#ff8800cc")?[3] == 204 && hexRGBA("red") == nil)

    // Search syntax + rank fusion
    let q = SearchQuery("type:url  App:Xcode is:today  foo bar")
    precondition(q.kind == .url && q.app == "xcode" && q.today && q.text == "foo bar", "\(q)")
    precondition(SearchQuery("type:bogus").text == "type:bogus", "unknown type stays text")
    precondition(fuse([["a", "b", "c"], ["b"]]) == ["b", "a", "c"], "rank fusion")

    // Local actions
    precondition(formatJSON(#"{"b":1,"a":[1, 2]}"#, pretty: false) == #"{"a":[1,2],"b":1}"#)
    precondition(formatJSON(#"{"a":1}"#, pretty: true)?.contains("\n") == true)
    precondition(formatJSON("nope", pretty: true) == nil)
    precondition(cleanURL("https://x.com/p?utm_source=a&id=3&fbclid=z") == "https://x.com/p?id=3")
    precondition(cleanURL("https://x.com/p?utm_source=a") == "https://x.com/p")
    precondition(hexToRGB("#ff8800") == "rgb(255, 136, 0)" && hexToRGB("#ff880080") == "rgba(255, 136, 0, 0.50)")
    precondition(needsTitle(.code, "a\nb\nc\nd") && !needsTitle(.text, "short") && !needsTitle(.url, String(repeating: "x", count: 300)))

    // UUIDv7
    let a = uuidv7(now: 1_000), b = uuidv7(now: 2_000)
    precondition(a.count == 36 && Array(a)[14] == "7" && a < b, "uuidv7 \(a) \(b)")

    // Capture rules
    let pb = NSPasteboard(name: .init("kopumi-check"))
    pb.clearContents(); pb.setString("https://example.com", forType: .string)
    precondition(Watcher.capture(pb, sourceApp: nil)?.kind == .url)
    precondition(Watcher.capture(pb, sourceApp: "com.1password.1password") == nil, "ignored app")
    pb.clearContents(); pb.setString("secret", forType: .string)
    pb.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
    precondition(Watcher.capture(pb, sourceApp: nil) == nil, "concealed type")
    pb.releaseGlobally()

    // Store
    let path = NSTemporaryDirectory() + "kopumi-check-\(UUID()).sqlite"
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try! Store(path: path, deviceId: "check")
    func clip(_ t: String, secret: Bool = false) -> NewClip {
        NewClip(kind: .text, text: t, contentHash: "text:" + t, sensitive: secret, blobs: [("public.rtf", Data(t.utf8))])
    }
    let idA = try! store.upsert(clip("A"), now: 1)
    try! store.upsert(clip("B"), now: 2)
    precondition(try! store.upsert(clip("A"), now: 3) == idA, "dedupe keeps id")
    var recent = try! store.recent(limit: 10)
    precondition(recent.map(\.text) == ["A", "B"], "recent order \(recent.map(\.text))")
    precondition(try! store.blobs(id: idA).first?.data == Data("A".utf8), "blob roundtrip")

    try! store.prune(maxItems: 1, now: 4)
    precondition(try! store.recent(limit: 10).map(\.text) == ["A"], "prune by count")

    try! store.clearHistory(now: 5)
    precondition(try! store.recent(limit: 10).isEmpty, "clear")
    precondition(try! store.blobs(id: idA).isEmpty, "blobs dropped on clear")
    precondition(try! store.upsert(clip("A"), now: 6) != idA, "re-copy after clear is a new clip")

    // Search
    try! store.upsert(clip("SELECT * FROM users JOIN orders"), now: 10)
    try! store.upsert(clip("Café menu for Friday"), now: 11)
    precondition(try! store.search("user ord", limit: 10).map(\.text) == ["SELECT * FROM users JOIN orders"], "prefix search")
    precondition(try! store.search("cafe", limit: 10).count == 1, "diacritics-insensitive search")
    precondition(try! store.search(#"he"llo"#, limit: 10).isEmpty, "quotes are escaped")
    precondition(try! store.search("  ", limit: 10).count == 3, "empty query = recent")
    precondition(try! store.search(SearchQuery("type:code"), limit: 10).isEmpty, "kind filter")

    // Enrichment: OCR/title become searchable, embeddings round-trip, nothing left to enrich
    while let job = try! store.nextToEnrich() {
        try! store.saveEnrichment(id: job.clip.id, title: job.clip.text == "A" ? "Shopping list" : nil,
                                  ocr: job.clip.text == "A" ? "invoice total 42" : nil,
                                  embedding: ("m1", [0.6, 0.8]))
    }
    precondition(try! store.search("invoice", limit: 10).map(\.text) == ["A"], "OCR text is searchable")
    precondition(try! store.search("shopping", limit: 10).first?.label == "Shopping list", "title is label + searchable")
    precondition(try! store.embeddingModels() == ["m1"] && store.embeddings(model: "m1").first?.vector == [0.6, 0.8])
    try! store.clearHistory(now: 12)
    precondition(try! store.search("users", limit: 10).isEmpty, "cleared clips leave the index")
    precondition(try! store.search("invoice", limit: 10).isEmpty, "cleared OCR leaves the index")
    precondition(try! store.embeddingModels().isEmpty, "embeddings dropped on clear")
    try! store.upsert(clip("A"), now: 13)

    try! store.upsert(clip("sk-secret", secret: true), now: 7)
    try! store.prune(maxItems: 100, now: 7 + Store.sensitiveTTL + 1)
    recent = try! store.recent(limit: 10)
    precondition(recent.map(\.text) == ["A"], "secret expired \(recent.map(\.text))")

    print("checks passed")
}

/// `Kopumi --check-ai`: exercises the real on-device models (embeddings, OCR, Foundation Models).
@MainActor
func runAIChecks() async {
    let e = Embedder()
    guard let cat = await e.embed("My cat sleeps on the sofa all day"),
          let kitten = await e.embed("A kitten napping on the couch"),
          let car = await e.embed("Quarterly revenue grew by twelve percent")
    else { print("✗ embeddings unavailable"); return }
    let sim = { (a: [Float], b: [Float]) in zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }
    print("embeddings (\(cat.model), dim \(cat.vector.count)): cat~kitten \(sim(cat.vector, kitten.vector)), cat~revenue \(sim(cat.vector, car.vector))")
    precondition(sim(cat.vector, kitten.vector) > sim(cat.vector, car.vector), "similar sentences must score higher")
    if let q = await e.embed("pet resting", modelID: cat.model) {
        print("query 'pet resting': cat \(sim(q, cat.vector)), revenue \(sim(q, car.vector))")
    }
    if let ru = await e.embed("Кошка спит на диване") { print("russian → model \(ru.model)") }

    // OCR on a rendered image
    let img = NSImage(size: NSSize(width: 600, height: 120), flipped: false) { r in
        NSColor.white.setFill(); r.fill()
        ("Invoice total 4200 EUR" as NSString).draw(at: NSPoint(x: 20, y: 40),
            withAttributes: [.font: NSFont.systemFont(ofSize: 40), .foregroundColor: NSColor.black])
        return true
    }
    let png = NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    let text = await OCR.text(png)
    print("OCR:", text ?? "nil")
    precondition(text?.contains("4200") == true, "OCR should read the number")

    if let why = OnDeviceAI.unavailableReason { print("Foundation Models:", why); return }
    let title = await OnDeviceAI.title(for: "SELECT u.name, count(o.id) FROM users u JOIN orders o ON o.user_id = u.id GROUP BY u.name ORDER BY 2 DESC LIMIT 10")
    print("title:", title ?? "nil")
    do {
        let fixed = try await OnDeviceAI.respond(instructions: OnDeviceAI.actionInstructions,
                                                 prompt: "Fix grammar, spelling and punctuation. Change nothing else.\n\nText:\nhe dont know were the meating is")
        print("fix grammar:", fixed)
    } catch { print("fix grammar failed:", OnDeviceAI.describe(error)) }
    print("ai checks done")
}
