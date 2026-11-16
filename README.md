# Gitty

An iOS app for reading and reviewing code on the go: fast, light on the battery, and native-feeling, like Safari plus Photos for code.

## Step 1: raw text viewer

- Opens one hard-coded file (`Gitty/App/Sources.swift`) and shows it the way Safari shows raw text: Courier 13pt, wrapped lines, Safari's margins, light and dark mode.
- **Downloaded files never expire.** They are kept in Application Support, which iOS never clears, and shown with no network access. The file is downloaded again **only** when you pull to refresh. That refresh is a conditional request, so an unchanged file costs only an HTTP 304.
- A Safari-style bottom bar shows the file name. It collapses as you scroll down and shows a thin loading line only while something is downloading. It looks like Safari on iOS 26 (Liquid Glass) and on iOS 18.
- The text is shown in a native TextKit 2 `UITextView`, which lays out only what's on screen.

## Adding the sources to the Xcode project

The repo doesn't have an Xcode project yet. Once the empty base project exists:

1. Delete the template's `App` and `ContentView` files, then drag `Gitty/` into the app target and `GittyTests/` into the unit-test target.
2. Set the deployment target to **iOS 18.0**. You need Xcode 26 or newer (Swift 6.2): the code uses `nonisolated` on types and the iOS 26 APIs behind `#available` checks.
3. The tests use `@testable import Gitty`. If your app module has a different name, change that line.

The code works with either setting of *Default Actor Isolation* (MainActor or nonisolated) and with Swift 6 strict concurrency. No Info.plist changes are needed.

## Layout

| Path | What it does |
|---|---|
| `Gitty/Core/DocumentStore.swift` | Saved copies on disk and the network fetch: never expires, conditional refresh |
| `Gitty/Core/RawTextDecoder.swift` | Bytes to text, decoded the way Safari does it (BOM, then charset, then UTF-8, then windows-1252) |
| `Gitty/Viewer/RawTextStyle.swift` | Safari's raw-text style constants, taken from WebKit's source |
| `Gitty/Viewer/CodeTextView.swift` | TextKit 2 text view, pull-to-refresh, scroll tracking for the bar |
| `Gitty/Viewer/FileBar.swift` | Safari-style bottom bar and loading line, sizes in `FileBarMetrics` |
| `Gitty/Viewer/CodeDocumentModel.swift` | Screen state: loading, refresh, progress, bar |
| `Gitty/Viewer/CodeScreen.swift` | The screen |
