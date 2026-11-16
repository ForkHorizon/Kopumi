// SwiftUI views for the Cmd+V panel: search, clip list, preview, actions.
import SwiftUI

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
              .onTapGesture {
                model.selection = i
                model.focus = .clips
              }
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
    .background(
      selected ? Color.accentColor.opacity(dimmed ? 0.12 : 0.25) : .clear,
      in: .rect(cornerRadius: 6)
    )
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
      Label("Hidden secret — paste works, preview doesn't.", systemImage: "lock.fill")
        .foregroundStyle(.secondary)
    } else if clip.kind == .image, let img = model.image(for: clip) {
      Image(nsImage: img).resizable().scaledToFit()
    } else {
      VStack(alignment: .leading, spacing: 10) {
        if clip.kind == .color, let c = hexRGBA(clip.text ?? "") {
          RoundedRectangle(cornerRadius: 8)
            .fill(
              Color(
                .sRGB, red: Double(c[0]) / 255, green: Double(c[1]) / 255,
                blue: Double(c[2]) / 255, opacity: Double(c[3]) / 255)
            )
            .frame(height: 60)
        }
        ScrollView {
          Text(clip.text ?? "")
            .font(
              [.code, .json, .table].contains(clip.kind)
                ? .system(.body, design: .monospaced) : .body
            )
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
  }
}
