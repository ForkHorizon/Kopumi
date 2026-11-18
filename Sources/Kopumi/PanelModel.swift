// Panel state: search results, selection, and running clip actions.
import AppKit

@MainActor
final class PanelModel: ObservableObject {
  enum Focus { case clips, actions }

  @Published var query = "" { didSet { if query != oldValue { refresh() } } }
  @Published private(set) var clips: [Clip] = []
  @Published var selection = 0 { didSet { if selection != oldValue { resetAction() } } }
  @Published private(set) var shown = 0  // bumps on every show → refocus search field
  @Published var focus = Focus.clips
  @Published var actionSelection = 0
  @Published private(set) var running: String?  // title of the action in flight
  @Published private(set) var result: String?
  @Published private(set) var error: String?
  /// A cloud action waiting for "send this text to the CLI?" confirmation.
  @Published private(set) var consent: (action: ClipAction, prompt: String)?
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
      let byId = Dictionary(
        (keyword + meaning).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
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
    guard result == nil, running == nil, consent == nil else { return }
    focus = focus == .clips && !actions.isEmpty ? .actions : .clips
    actionSelection = 0
  }

  /// ↩: paste the AI result, run the chosen action, or paste the clip.
  func enter(forcePlain: Bool) {
    if consent != nil {
      confirmCloud()
    } else if result != nil {
      pasteResult(forcePlain: forcePlain)
    } else if focus == .actions {
      runAction()
    } else {
      paste(forcePlain: forcePlain)
    }
  }

  /// Esc: step back one level. Returns false when there's nothing to step back from (→ close).
  func back() -> Bool {
    if running != nil || result != nil || error != nil || consent != nil {
      resetAction()
      return true
    }
    if focus == .actions {
      focus = .clips
      return true
    }
    return false
  }

  func paste(_ index: Int? = nil, forcePlain: Bool = false) {
    let i = index ?? selection
    guard clips.indices.contains(i) else { return }
    let clip = clips[i]
    close()
    try? store.touch(id: clip.id)
    Paster.paste(
      clip, blobs: (try? store.blobs(id: clip.id)) ?? [],
      target: target?.bundleIdentifier, forcePlain: forcePlain)
  }

  func runAction(_ index: Int? = nil) {
    if let index {
      actionSelection = index
      focus = .actions
    }
    guard let clip = selected, let text = clip.text, actions.indices.contains(actionSelection)
    else { return }
    let action = actions[actionSelection]
    switch action.engine {
    case .local(let transform):
      if let r = transform(text) {
        result = r
      } else {
        error = "Couldn't apply “\(action.title)” to this clip."
      }
    case .onDevice(let task):
      // ponytail: ~4k-token window ≈ 6k chars; longer text goes to the cloud CLI when one is on.
      if text.count > 6_000, CloudAI.isEnabled {
        askCloud(action, CloudAI.prompt(task: task, text: text))
      } else {
        runOnDevice(action.title, task: task, text: text)
      }
    case .cloud(let task):
      askCloud(action, CloudAI.prompt(task: task, text: text))
    }
  }

  private func runOnDevice(_ title: String, task: String, text: String) {
    if let why = OnDeviceAI.unavailableReason {
      error = why
      return
    }
    start(title, describe: OnDeviceAI.describe) {
      try await OnDeviceAI.respond(
        instructions: OnDeviceAI.actionInstructions, prompt: task + "\n\nText:\n" + text)
    }
  }

  private func askCloud(_ action: ClipAction, _ prompt: String) {
    if CloudAI.hasConsent(action.id) {
      runCloud(action.title, prompt)
    } else {
      consent = (action, prompt)
    }
  }

  private func confirmCloud() {
    guard let c = consent else { return }
    consent = nil
    CloudAI.grantConsent(c.action.id)
    runCloud(c.action.title, c.prompt)
  }

  private func runCloud(_ title: String, _ prompt: String) {
    start("\(title) in \(CloudAI.name)", describe: CloudAI.describe) {
      try await CloudAI.run(prompt)
    }
  }

  /// One cancellable action at a time; esc or a new selection cancels it (and kills a running CLI).
  private func start(
    _ label: String, describe: @escaping (Error) -> String,
    _ work: @escaping @MainActor () async throws -> String
  ) {
    running = label
    actionTask = Task {
      do {
        let r = try await work()
        guard !Task.isCancelled else { return }
        result = r
      } catch {
        guard !Task.isCancelled else { return }
        self.error = describe(error)
      }
      running = nil
    }
  }

  /// Saves the result as a new clip (linked to its source) and pastes it.
  private func pasteResult(forcePlain: Bool) {
    guard let r = result, let source = selected else { return }
    let new = NewClip(
      kind: classify(r).kind, text: r, sourceApp: source.sourceApp,
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
    consent = nil
  }

  func image(for clip: Clip) -> NSImage? {
    if let c = imageCache, c.id == clip.id { return c.image }
    let img = (try? store.blobs(id: clip.id))?.first.flatMap { NSImage(data: $0.data) }
    imageCache = (clip.id, img)
    return img
  }

  func appName(_ bundle: String?) -> String? { appDisplayName(bundle) }
}
