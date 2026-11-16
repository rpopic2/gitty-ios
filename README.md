# gitty

An iOS app for reading and reviewing code on the go: fast, light on the battery, and native-feeling, like Safari plus Photos for code.

## Step 1: raw text viewer

- Opens one hard-coded file (`gitty/App/Sources.swift`) and shows it the way Safari shows raw text: Courier 13pt, wrapped lines, Safari's margins, light and dark mode.
- **Downloaded files never expire.** They are kept in Application Support, which iOS never clears, and shown with no network access. The file is downloaded again **only** when you pull to refresh. That refresh is a conditional request, so an unchanged file costs only an HTTP 304.
- A Safari-style bottom bar shows the file name. It collapses as you scroll down and shows a thin loading line only while something is downloading. It looks like Safari on iOS 26+ (Liquid Glass) and on iOS 18.
- The text is shown in a native `UITextView` using TextKit 1 with contiguous layout: every line's height is exact (like Safari), so the scroll bar and text never jump. TextKit 2 was tried first, but its estimated heights made both jump.

## Project setup

- `gitty.xcodeproj` keeps `gitty/` as a **synchronized folder**: every file under it is automatically part of the `gitty` app target. Add new files by putting them in the folder. The project file doesn't need editing.
- Deployment target **iOS 18.0**, iPhone and iPad only.
- `gitty/Assets.xcassets` has empty AppIcon and AccentColor slots.
- Swift settings come from the Xcode template: Swift 5 language mode, default actor isolation `MainActor`, approachable concurrency, member import visibility. The Core and style types are marked `nonisolated` so they can run off the main thread. The code is also Swift 6 strict-concurrency clean.

### First pull on a Mac that has the old template folder

The first upload committed `gitty/` as an empty submodule link, because the folder had its own `.git`. Before pulling, **delete your local `gitty/` folder**, including its hidden `.git` and the template's `gittyApp.swift`, `ContentView.swift` and `Assets.xcassets`. Then pull. If you skip this, the template's `gittyApp.swift` clashes with `gitty/App/GittyApp.swift` (two `@main`).

### Adding the test target (one time, in Xcode)

The tests are in `gittyTests/` and use Swift Testing. To run them:

1. File ▸ New ▸ Target ▸ **Unit Testing Bundle**. Name it `gittyTests`, set Testing System to **Swift Testing**, and set Target to be Tested to **gitty**.
2. Xcode creates its own `gittyTests` folder with a sample file. Remove that folder reference and add the existing `gittyTests/` folder (as a folder) to the `gittyTests` target.
3. Press ⌘U.

## Layout

| Path | What it does |
|---|---|
| `gitty/App/GittyApp.swift` | App entry point (`@main`) |
| `gitty/Core/DocumentStore.swift` | Saved copies on disk and the network fetch: never expires, conditional refresh |
| `gitty/Core/RawTextDecoder.swift` | Bytes to text, decoded the way Safari does it (BOM, then charset, then UTF-8, then windows-1252) |
| `gitty/Viewer/RawTextStyle.swift` | Safari's raw-text style constants, taken from WebKit's source |
| `gitty/Viewer/CodeTextView.swift` | Text view (TextKit 1, full layout), pull-to-refresh, scroll tracking for the bar |
| `gitty/Viewer/FileBar.swift` | Safari-style bottom bar and loading line, sizes in `FileBarMetrics` |
| `gitty/Viewer/CodeDocumentModel.swift` | Screen state: loading, refresh, progress, bar |
| `gitty/Viewer/CodeScreen.swift` | The screen |
| `gittyTests/` | Decoder and store tests |
