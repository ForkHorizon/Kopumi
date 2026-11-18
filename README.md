# Kopumi

A smart clipboard manager for macOS 26+ (Apple Silicon). It lives in the menu bar: tap ⌘V to paste as usual, hold ⌘V to search your history by words or meaning and run AI actions on a clip. Everything stays on your Mac unless you run a cloud action through your own AI CLI.

## Develop

```sh
./run.sh                      # build, bundle, sign, launch (logs in the terminal)
.build/debug/Kopumi --check   # self-checks (no UI)
.build/debug/Kopumi --check-ai          # real on-device models
.build/debug/Kopumi --snapshot <dir>    # render the panel and windows to PNGs offscreen
```

Needs only the Xcode Command Line Tools. `run.sh` signs with your "Apple Development" certificate if you have one, so macOS keeps the Accessibility permission across rebuilds; otherwise it signs ad-hoc and may ask again.

## Release

```sh
./release.sh 0.2                               # → .build/Kopumi-0.2.dmg, notarized and stapled
SKIP_NOTARIZE=1 SIGN_ID=- ./release.sh 0.2     # dry run without an Apple account
```

One-time setup (paid Apple Developer Program): a **Developer ID Application** certificate in your login keychain, and notarization credentials stored with `xcrun notarytool store-credentials kopumi-notary`. Details are in the header of `release.sh`.

See [PLAN.md](PLAN.md) for the design and roadmap.
