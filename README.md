# gitty

An iOS app for reading and reviewing code on the go: fast, light on the battery, and native-feeling, like Safari plus Photos for code.

## Features

- **Safari's raw-text look:** Courier 13pt, wrapped lines, Safari's margins, light and dark mode.
- **Works offline, never expires:** downloaded files stay on the device and open without the network. They are downloaded again only when you pull to refresh, and an unchanged file costs just an HTTP 304.
- **Smooth, exact scrolling:** every line's height is known up front, so the scroll bar and text never jump.
- **Safari-style bottom bar:** shows the file name, collapses while you scroll down, and shows a thin loading line only while downloading. Liquid Glass on iOS 26+, the Safari 18 style on iOS 18.

For now the app opens one hard-coded file (`gitty/App/Sources.swift`).

## Project

- iOS 18.0+, iPhone and iPad.
- `gitty/` is a synchronized folder, so any file you put in it joins the `gitty` target automatically.
- The default actor isolation is `MainActor`. Types that run off the main thread are marked `nonisolated`.

### Tests

The `gittyTests/` folder holds Swift Testing tests but has no target yet. To add one, choose File ▸ New ▸ Target ▸ Unit Testing Bundle and name it `gittyTests` (Swift Testing, testing `gitty`). Then replace the folder Xcode generates with the existing `gittyTests/` folder and press ⌘U.

## Code map

| Path | What it does |
|---|---|
| `gitty/App/` | App entry point and the hard-coded source URL |
| `gitty/Core/DocumentStore.swift` | Saved copies on disk and the network fetch: never expires, conditional refresh |
| `gitty/Core/RawTextDecoder.swift` | Bytes to text, decoded the way Safari does it (BOM, charset, UTF-8, windows-1252) |
| `gitty/Viewer/RawTextStyle.swift` | Safari's raw-text style constants, taken from WebKit's source |
| `gitty/Viewer/CodeTextView.swift` | `UITextView` (TextKit 1, full layout), pull-to-refresh, scroll tracking for the bar |
| `gitty/Viewer/FileBar.swift` | Bottom bar and loading line, sizes in `FileBarMetrics` |
| `gitty/Viewer/CodeDocumentModel.swift` | Screen state: loading, refresh, progress, bar |
| `gitty/Viewer/CodeScreen.swift` | The screen |
| `gittyTests/` | Decoder and store tests |
