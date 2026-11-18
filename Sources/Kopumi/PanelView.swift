// SwiftUI views for the Cmd+V panel: search, clip list, preview, actions.
import SwiftUI

/// Monochrome palette: flat surface, ink, muted ink, hairlines. Inverts in dark mode.
enum Theme {
  static let surface = dynamic(
    NSColor(srgbRed: 0.925, green: 0.93, blue: 0.94, alpha: 1),
    NSColor(srgbRed: 0.085, green: 0.09, blue: 0.1, alpha: 1))
  static let ink = dynamic(NSColor(white: 0.07, alpha: 1), NSColor(white: 0.94, alpha: 1))
  static let muted = dynamic(NSColor(white: 0.46, alpha: 1), NSColor(white: 0.58, alpha: 1))
  static let hairline = dynamic(NSColor(white: 0, alpha: 0.13), NSColor(white: 1, alpha: 0.14))

  private static func dynamic(_ light: NSColor, _ dark: NSColor) -> Color {
    Color(
      nsColor: NSColor(name: nil) {
        $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
      })
  }
}

struct PanelView: View {
  @ObservedObject var model: PanelModel
  @FocusState private var searchFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      search
      HStack(alignment: .top, spacing: 28) {
        list.frame(width: 300)
        VStack(alignment: .leading, spacing: 18) {
          detail.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          if !model.actions.isEmpty { ActionList(model: model) }
        }
      }
      hints
    }
    .padding(22)
    .frame(width: 760, height: 480)
    .foregroundStyle(Theme.ink)
    .background(Theme.surface, in: .rect(cornerRadius: 8))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.hairline))
    .onAppear { searchFocused = true }
    .onChange(of: model.shown) { searchFocused = true }
  }

  private var search: some View {
    VStack(spacing: 10) {
      HStack(spacing: 10) {
        Image(systemName: "magnifyingglass").fontWeight(.light)
        TextField("Search by words or meaning", text: $model.query)
          .textFieldStyle(.plain)
          .font(.system(size: 17))
          .focused($searchFocused)
        Text("type:  app:  is:today").font(.system(size: 11)).foregroundStyle(Theme.muted)
      }
      Theme.hairline.frame(height: 1)
    }
  }

  private var hints: some View {
    let pairs: [(String, String)] =
      if model.result != nil {
        [("↩", "Paste result"), ("⌥↩", "Plain text"), ("esc", "Back")]
      } else if model.running != nil { [("esc", "Cancel")] } else if model.focus == .actions {
        [("↑↓", "Choose"), ("↩", "Run"), ("⇥", "Clips")]
      } else {
        [
          ("↩", "Paste"), ("⌥↩", "Plain text"), ("⇥", "Actions"), ("⌘1–9", "Quick"),
          ("esc", "Close"),
        ]
      }
    return HStack(spacing: 18) {
      ForEach(pairs, id: \.1) { key, label in
        HStack(spacing: 5) {
          Text(key).fontWeight(.medium)
          Text(label).foregroundStyle(Theme.muted)
        }
      }
    }
    .font(.system(size: 11))
  }

  @ViewBuilder private var detail: some View {
    if let title = model.running {
      section("Working") {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("\(title)…").foregroundStyle(Theme.muted)
        }
      }
    } else if let result = model.result {
      section("Result") {
        ScrollView {
          Text(result).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    } else if let error = model.error {
      section("Couldn't finish") { Text(error).foregroundStyle(Theme.muted) }
    } else if let c = model.selected {
      Preview(clip: c, model: model)
    } else {
      Text(model.query.isEmpty ? "Nothing copied yet" : "No matches").foregroundStyle(Theme.muted)
    }
  }

  private var list: some View {
    section("Clips") {
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(spacing: 2) {
            ForEach(Array(model.clips.enumerated()), id: \.element.id) { i, c in
              Row(
                clip: c, index: i, selected: i == model.selection, outlined: model.focus == .actions
              )
              .id(i)
              .onTapGesture(count: 2) { model.paste(i) }
              .onTapGesture {
                model.selection = i
                model.focus = .clips
              }
            }
          }
        }
        .scrollIndicators(.never)
        .onChange(of: model.selection) { proxy.scrollTo(model.selection) }
      }
    }
  }
}

/// Small muted label above a block, like a form section.
func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
  VStack(alignment: .leading, spacing: 10) {
    Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.muted)
    content()
  }
}

/// Selected = solid inverted block; outlined when focus moved to the actions.
private struct Row: View {
  let clip: Clip
  let index: Int
  let selected: Bool
  let outlined: Bool

  var body: some View {
    let inverted = selected && !outlined
    HStack(spacing: 10) {
      Image(systemName: clip.sensitive ? "lock" : clip.kind.symbol)
        .fontWeight(.light).frame(width: 16)
      Text(clip.label).lineLimit(1).fontWeight(inverted ? .semibold : .regular)
      Spacer(minLength: 4)
      if index < 9 {
        Text("⌘\(index + 1)").font(.system(size: 10)).monospacedDigit()
          .foregroundStyle(inverted ? Theme.surface : Theme.muted)
      }
    }
    .font(.system(size: 13))
    .foregroundStyle(inverted ? Theme.surface : Theme.ink)
    .padding(.horizontal, 10).padding(.vertical, 7)
    .background(inverted ? Theme.ink : .clear, in: .rect(cornerRadius: 2))
    .overlay {
      if selected && outlined { RoundedRectangle(cornerRadius: 2).strokeBorder(Theme.ink) }
    }
    .contentShape(.rect)
  }
}

private struct ActionList: View {
  @ObservedObject var model: PanelModel

  var body: some View {
    section("Actions") {
      VStack(alignment: .leading, spacing: 2) {
        ForEach(Array(model.actions.enumerated()), id: \.element.id) { i, a in
          let on = model.focus == .actions && i == model.actionSelection
          HStack(spacing: 10) {
            Image(systemName: a.symbol).fontWeight(.light).frame(width: 16)
            Text(a.title).fontWeight(on ? .semibold : .regular)
            Spacer()
            if case .onDevice = a.engine {
              Text("AI").font(.system(size: 9, weight: .medium))
                .foregroundStyle(on ? Theme.surface : Theme.muted)
            }
          }
          .font(.system(size: 12))
          .foregroundStyle(on ? Theme.surface : Theme.ink)
          .padding(.horizontal, 10).padding(.vertical, 5)
          .background(on ? Theme.ink : .clear, in: .rect(cornerRadius: 2))
          .contentShape(.rect)
          .onTapGesture { model.runAction(i) }
        }
      }
    }
  }
}

private struct Preview: View {
  let clip: Clip
  let model: PanelModel

  var body: some View {
    section(meta) {
      content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
  }

  private var meta: String {
    let when = Date(timeIntervalSince1970: Double(clip.lastUsedAt) / 1000)
      .formatted(.relative(presentation: .named))
    let kind =
      [.url, .json].contains(clip.kind)
      ? clip.kind.rawValue.uppercased() : clip.kind.rawValue.capitalized
    return ([kind, model.appName(clip.sourceApp), when] as [String?])
      .compactMap { $0 }.joined(separator: "  —  ")
  }

  @ViewBuilder private var content: some View {
    if clip.sensitive {
      Text("Hidden secret. Paste works, preview doesn't.").foregroundStyle(Theme.muted)
    } else if clip.kind == .image, let img = model.image(for: clip) {
      Image(nsImage: img).resizable().scaledToFit()
        .overlay(Rectangle().strokeBorder(Theme.hairline))
    } else {
      VStack(alignment: .leading, spacing: 12) {
        if clip.kind == .color, let c = hexRGBA(clip.text ?? "") {
          Rectangle()
            .fill(
              Color(
                .sRGB, red: Double(c[0]) / 255, green: Double(c[1]) / 255,
                blue: Double(c[2]) / 255, opacity: Double(c[3]) / 255)
            )
            .frame(width: 72, height: 72)
            .overlay(Rectangle().strokeBorder(Theme.hairline))
        }
        ScrollView {
          Text(clip.text ?? "")
            .font(
              [.code, .json, .table].contains(clip.kind)
                ? .system(size: 12, design: .monospaced) : .system(size: 13)
            )
            .lineSpacing(3)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
      }
    }
  }
}
