import AppKit
import SwiftUI

/// Borderless panel that takes keyboard focus without activating Kopumi,
/// so the app you're pasting into stays frontmost.
final class KopumiPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class PanelModel: ObservableObject {
    enum Focus { case clips, actions }

    @Published var query = "" { didSet { refresh() } }
    @Published private(set) var clips: [Clip] = []
    @Published var selection = 0 { didSet { if selection != oldValue { resetAction() } } }
    @Published private(set) var shown = 0  // bumps on every show → refocus search field
    @Published var focus = Focus.clips
    @Published var actionSelection = 0
    @Published private(set) var running: String?  // title of the action in flight
    @Published private(set) var result: String?
    @Published private(set) var error: String?
    var target: NSRunningApplication?
    var close: () -> Void = {}
    let store: Store
    let embedder: Embedder
    private var semanticTask: Task<Void, Never>?
    private var actionTask: Task<Void, Never>?
    private var imageCache: (id: String, image: NSImage?)?

    init(store: Store, embedder: Embedder) {
        self.store = store
        self.embedder = embedder
    }

    var selected: Clip? { clips.indices.contains(selection) ? clips[selection] : nil }
    var actions: [ClipAction] { selected.map(ClipAction.available) ?? [] }

    func reset() {
        query = ""
        refresh()
        shown += 1
    }

    /// Keyword hits show instantly; meaning-based hits merge in a moment later.
    func refresh() {
        let q = SearchQuery(query)
        let keyword = (try? store.search(q, limit: 50)) ?? []
        clips = keyword
        selection = 0
        focus = .clips
        resetAction()
        semanticTask?.cancel()
        guard q.text.count >= 3 else { return }
        semanticTask = Task {
            try? await Task.sleep(for: .milliseconds(150))  // debounce typing
            guard !Task.isCancelled else { return }
            let meaning = await semanticSearch(q, store: store, embedder: embedder, limit: 10)
            guard !Task.isCancelled else { return }
            let keep = selection == 0 ? nil : selected?.id  // don't yank a selection the user moved
            let byId = Dictionary((keyword + meaning).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            clips = fuse([keyword.map(\.id), meaning.map(\.id)]).compactMap { byId[$0] }
            selection = keep.flatMap { id in clips.firstIndex { $0.id == id } } ?? 0
        }
    }

    func move(_ delta: Int) {
        if focus == .actions {
            actionSelection = max(0, min(actions.count - 1, actionSelection + delta))
        } else if !clips.isEmpty {
            selection = max(0, min(clips.count - 1, selection + delta))
        }
    }

    func toggleActions() {
        guard result == nil, running == nil else { return }
        focus = focus == .clips && !actions.isEmpty ? .actions : .clips
        actionSelection = 0
    }

    /// ↩: paste the AI result, run the chosen action, or paste the clip.
    func enter(forcePlain: Bool) {
        if result != nil { pasteResult(forcePlain: forcePlain) }
        else if focus == .actions { runAction() }
        else { paste(forcePlain: forcePlain) }
    }

    /// Esc: step back one level. Returns false when there's nothing to step back from (→ close).
    func back() -> Bool {
        if running != nil || result != nil || error != nil { resetAction(); return true }
        if focus == .actions { focus = .clips; return true }
        return false
    }

    func paste(_ index: Int? = nil, forcePlain: Bool = false) {
        let i = index ?? selection
        guard clips.indices.contains(i) else { return }
        let clip = clips[i]
        close()
        try? store.touch(id: clip.id)
        Paster.paste(clip, blobs: (try? store.blobs(id: clip.id)) ?? [],
                     target: target?.bundleIdentifier, forcePlain: forcePlain)
    }

    func runAction(_ index: Int? = nil) {
        if let index { actionSelection = index; focus = .actions }
        guard let clip = selected, let text = clip.text, actions.indices.contains(actionSelection) else { return }
        let action = actions[actionSelection]
        switch action.engine {
        case .local(let transform):
            if let r = transform(text) { result = r } else { error = "Couldn't apply “\(action.title)” to this clip." }
        case .onDevice(let prompt):
            if let why = OnDeviceAI.unavailableReason { error = why; return }
            running = action.title
            actionTask = Task {
                do {
                    let r = try await OnDeviceAI.respond(instructions: OnDeviceAI.actionInstructions,
                                                         prompt: prompt + "\n\nText:\n" + text)
                    guard !Task.isCancelled else { return }
                    result = r
                } catch {
                    guard !Task.isCancelled else { return }
                    self.error = OnDeviceAI.describe(error)
                }
                running = nil
            }
        }
    }

    /// Saves the result as a new clip (linked to its source) and pastes it.
    private func pasteResult(forcePlain: Bool) {
        guard let r = result, let source = selected else { return }
        let new = NewClip(kind: classify(r).kind, text: r, sourceApp: source.sourceApp,
                          contentHash: Watcher.hash("text", Data(r.utf8)), derivedFrom: source.id)
        guard let id = try? store.upsert(new), let clip = try? store.clip(id: id) else { return }
        close()
        Paster.paste(clip, blobs: [], target: target?.bundleIdentifier, forcePlain: forcePlain)
    }

    private func resetAction() {
        actionTask?.cancel()
        actionTask = nil
        running = nil
        result = nil
        error = nil
    }

    func image(for clip: Clip) -> NSImage? {
        if let c = imageCache, c.id == clip.id { return c.image }
        let img = (try? store.blobs(id: clip.id))?.first.flatMap { NSImage(data: $0.data) }
        imageCache = (clip.id, img)
        return img
    }

    func appName(_ bundle: String?) -> String? {
        guard let bundle, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

struct PanelView: View {
    @ObservedObject var model: PanelModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search by words or meaning — type:url  app:xcode  is:today", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($searchFocused)
            }
            .padding(14)
            Divider()
            HStack(spacing: 0) {
                list.frame(width: 320)
                Divider()
                VStack(spacing: 0) {
                    detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                    if !model.actions.isEmpty {
                        Divider()
                        ActionList(model: model)
                    }
                }
            }
            Divider()
            Text(hint).font(.caption).foregroundStyle(.secondary).padding(8)
        }
        .frame(width: 760, height: 480)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .onAppear { searchFocused = true }
        .onChange(of: model.shown) { searchFocused = true }
    }

    private var hint: String {
        if model.result != nil { return "↩ paste result   ⌥↩ plain text   esc back" }
        if model.running != nil { return "esc cancel" }
        if model.focus == .actions { return "↑↓ choose   ↩ run   ⇥ / esc back to clips" }
        return "↩ paste   ⌥↩ plain text   ⇥ actions   ⌘1–9 quick paste   esc close"
    }

    @ViewBuilder private var detail: some View {
        if let title = model.running {
            ProgressView { Text("\(title)…") }.controlSize(.small)
        } else if let result = model.result {
            VStack(alignment: .leading, spacing: 8) {
                Label("Result", systemImage: "sparkles").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    Text(result).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(14)
        } else if let error = model.error {
            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary).padding(14)
        } else if let c = model.selected {
            Preview(clip: c, model: model)
        } else {
            Text(model.query.isEmpty ? "Nothing copied yet" : "No matches").foregroundStyle(.secondary)
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(model.clips.enumerated()), id: \.element.id) { i, c in
                        Row(clip: c, index: i, selected: i == model.selection, dimmed: model.focus == .actions)
                            .id(i)
                            .onTapGesture(count: 2) { model.paste(i) }
                            .onTapGesture { model.selection = i; model.focus = .clips }
                    }
                }
                .padding(6)
            }
            .onChange(of: model.selection) { proxy.scrollTo(model.selection) }
        }
    }
}

private struct Row: View {
    let clip: Clip
    let index: Int
    let selected: Bool
    let dimmed: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: clip.sensitive ? "lock.fill" : clip.kind.symbol)
                .foregroundStyle(.secondary).frame(width: 18)
            Text(clip.label).lineLimit(1)
            Spacer(minLength: 4)
            if index < 9 { Text("⌘\(index + 1)").font(.caption).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(selected ? Color.accentColor.opacity(dimmed ? 0.12 : 0.25) : .clear, in: .rect(cornerRadius: 6))
        .contentShape(.rect)
    }
}

private struct ActionList: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("ACTIONS  ⇥").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                .padding(.horizontal, 8).padding(.bottom, 2)
            ForEach(Array(model.actions.enumerated()), id: \.element.id) { i, a in
                let on = model.focus == .actions && i == model.actionSelection
                HStack(spacing: 8) {
                    Image(systemName: a.symbol).frame(width: 16).foregroundStyle(.secondary)
                    Text(a.title)
                    Spacer()
                    if case .onDevice = a.engine {
                        Image(systemName: "apple.intelligence").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .font(.callout)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(on ? Color.accentColor.opacity(0.25) : .clear, in: .rect(cornerRadius: 6))
                .contentShape(.rect)
                .onTapGesture { model.runAction(i) }
            }
        }
        .padding(8)
    }
}

private struct Preview: View {
    let clip: Clip
    let model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack(spacing: 6) {
                Label(clip.kind.rawValue, systemImage: clip.kind.symbol)
                if let app = model.appName(clip.sourceApp) { Text("· \(app)") }
                Text("· \(Date(timeIntervalSince1970: Double(clip.lastUsedAt) / 1000), style: .relative)")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
    }

    @ViewBuilder private var content: some View {
        if clip.sensitive {
            Label("Hidden secret — paste works, preview doesn't.", systemImage: "lock.fill").foregroundStyle(.secondary)
        } else if clip.kind == .image, let img = model.image(for: clip) {
            Image(nsImage: img).resizable().scaledToFit()
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if clip.kind == .color, let c = hexRGBA(clip.text ?? "") {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(.sRGB, red: Double(c[0]) / 255, green: Double(c[1]) / 255,
                                    blue: Double(c[2]) / 255, opacity: Double(c[3]) / 255))
                        .frame(height: 60)
                }
                ScrollView {
                    Text(clip.text ?? "")
                        .font([.code, .json, .table].contains(clip.kind) ? .system(.body, design: .monospaced) : .body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

@MainActor
final class PanelController {
    let model: PanelModel
    private let panel: KopumiPanel
    private var monitor: Any?

    init(store: Store, embedder: Embedder) {
        model = PanelModel(store: store, embedder: embedder)
        panel = KopumiPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
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
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) {
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
            let code = e.keyCode, flags = e.modifierFlags, chars = e.charactersIgnoringModifiers ?? ""
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
        case 125: model.move(1)                                       // ↓
        case 126: model.move(-1)                                      // ↑
        case 48: model.toggleActions()                                // ⇥
        case 36, 76: model.enter(forcePlain: flags.contains(.option)) // ↩ / enter
        case 53: if !model.back() { hide() }                          // esc
        default:
            guard flags.contains(.command), let n = Int(chars), (1...9).contains(n) else { return false }
            model.paste(n - 1)
        }
        return true
    }

    /// Below the text caret if the app exposes it, else at the mouse; kept on screen.
    private func origin() -> NSPoint {
        let anchor = caretRect().map { r in
            NSPoint(x: r.minX, y: (NSScreen.screens.first?.frame.height ?? 0) - r.maxY)  // AX is top-left based
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
        var focused: CFTypeRef?, range: CFTypeRef?, bounds: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success,
              let range,
              AXUIElementCopyParameterizedAttributeValue(
                  element, kAXBoundsForRangeParameterizedAttribute as CFString, range, &bounds) == .success,
              let bounds, CFGetTypeID(bounds) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(bounds as! AXValue, .cgRect, &rect), rect != .zero else { return nil }
        return rect
    }
}
