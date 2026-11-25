// Settings → Sync: turn on, pair another device by QR / link, unpair.
import AppKit
import SwiftUI

/// Text field state (ObservableObject: @State is a macro the Command Line Tools can't expand).
@MainActor
final class SyncForm: ObservableObject {
  @Published var link = ""
  @Published var error: String?
  @Published var confirmRotate = false
}

struct SyncSection: View {
  @ObservedObject var sync: Sync
  @AppStorage("syncRelay") private var relay = "https://kopumi.forkhorizon.com"
  @StateObject private var form = SyncForm()

  var body: some View {
    Section("Sync") {
      if let a = sync.account { paired(a) } else { off }
      if let e = form.error { note(e) }
    }
  }

  private var off: some View {
    Group {
      TextField("Relay", text: $relay, prompt: Text("https://relay.example.com"))
      HStack {
        Button("Turn On Sync") {
          let address = relay.trimmingCharacters(in: .whitespaces)
          guard
            let url = URL(
              string: address.hasSuffix("/") ? String(address.dropLast()) : address),
            url.scheme == "https" || url.host == "localhost"
          else {
            form.error = "Enter your relay's https:// address."
            return
          }
          form.error = nil
          sync.use(.create(relay: url))
        }
        Spacer()
      }
      TextField("Or join with a link", text: $form.link, prompt: Text("kopumi://pair?…"))
      HStack {
        Button("Join") {
          guard let a = SyncAccount(link: form.link) else {
            form.error =
              form.link.hasPrefix("http")
              ? "That's a relay address: put it in Relay above and click Turn On Sync."
              : "That isn't a Kopumi pairing link. Copy one from a device that already syncs."
            return
          }
          form.error = nil
          form.link = ""
          try? sync.store.markAllDirty()
          sync.use(a)
        }
        .disabled(form.link.isEmpty)
        Spacer()
      }
      note(
        "Clips are encrypted on this Mac before they leave it. The relay only stores data it "
          + "can't read. Secrets are never synced.")
    }
  }

  private func paired(_ a: SyncAccount) -> some View {
    Group {
      LabeledContent("Status", value: sync.status)
      LabeledContent("Relay", value: a.relay.host() ?? a.relay.absoluteString)
      HStack(alignment: .top, spacing: 16) {
        if let qr = qrImage(a.link, size: 140) {
          Image(decorative: qr, scale: 2).interpolation(.none)
            .frame(width: 140, height: 140)
        }
        VStack(alignment: .leading, spacing: 8) {
          Text("Pair a phone").fontWeight(.medium)
          Text(
            "In Kopumi on Android: Settings → Scan Pairing Code. It contains your sync key: "
              + "show it only to your own devices."
          )
          .font(.caption).foregroundStyle(.secondary)
          Button("Copy Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(a.link, forType: .string)
          }
        }
      }
      HStack {
        Button("Sync Now") { sync.kick() }
        Button("Turn Off on This Mac") { sync.use(nil) }
        Spacer()
        Button("Unpair All Devices…") { form.confirmRotate = true }
      }
      .confirmationDialog(
        "Unpair all devices?", isPresented: $form.confirmRotate
      ) {
        Button("Unpair All", role: .destructive) { Task { await sync.rotate() } }
      } message: {
        Text(
          "Clips on the relay are deleted and this Mac moves to a new sync key. Other devices "
            + "stop syncing until you pair them again. Clips already on each device stay there.")
      }
    }
  }

  private func note(_ text: String) -> some View {
    Text(text).font(.caption).foregroundStyle(.secondary)
  }
}
