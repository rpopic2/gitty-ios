# gitty

An iOS app for reading and reviewing code on the go: fast, light on the battery, and native-feeling, like Safari plus Photos for code.

## Features

- **Safari's raw-text look:** Courier 13pt, wrapped lines, Safari's margins, light and dark mode.
- **Works offline, never expires:** downloaded files stay on the device and open without the network. They are downloaded again only when you pull to refresh, and an unchanged file costs just an HTTP 304.
- **Picks up where you left off:** the reading position of each file is saved when scrolling stops and when the app goes to the background. It is stored as a text position, so it survives rotation and refreshes.
- **Smooth, exact scrolling:** every line's height is known up front, so the scroll bar and text never jump.
- **Safari-style bottom bar:** shows the file name, collapses while you scroll down, and shows a thin loading line only while downloading. Liquid Glass on iOS 26+, the Safari 18 style on iOS 18.
- **Photos-style mode selector** under the bar: **Project** (coming later), **File** (the raw file) and **Symbols**.
- **Symbols:** every top-level function, type, macro and global as a card, like photos in Photos. Tap one to see only that symbol, swipe left and right to move between symbols, and swipe down to zoom back to the list. Symbols come from [tree-sitter](https://tree-sitter.github.io/) (C for now).

For now the app opens one hard-coded file (`gitty/App/Sources.swift`).

## Project

- iOS 18.0+, iPhone and iPad.
- `gitty/` is a synchronized folder, so any file you put in it joins the `gitty` target automatically.
- The default actor isolation is `MainActor`. Types that run off the main thread are marked `nonisolated`.

### Packages (one time, in Xcode)

Symbols mode uses tree-sitter. Choose File ▸ Add Package Dependencies… and add both to the `gitty` target:

| Package | Version | Product |
|---|---|---|
| `https://github.com/tree-sitter/swift-tree-sitter` | 0.25.0 | SwiftTreeSitter |
| `https://github.com/tree-sitter/tree-sitter-c` | 0.24.2 | TreeSitterC |

### Tests

The `gittyTests/` folder holds Swift Testing tests but has no target yet. To add one, choose File ▸ New ▸ Target ▸ Unit Testing Bundle and name it `gittyTests` (Swift Testing, testing `gitty`). Then replace the folder Xcode generates with the existing `gittyTests/` folder and press ⌘U.

## Adding a language to Symbols mode

1. Add the grammar's Swift package (for example `tree-sitter-python`) to the `gitty` target.
2. Add `gitty/Languages/symbols-<name>.scm`. Start from the grammar's own `queries/tags.scm` and use its conventions: capture the definition as `@definition.function`, `.method`, `.class`, `.type`, `.macro`, `.variable` or `.constant`, and its name as `@name`. You can also capture `@name.prefix`, which is shown before the name.
3. Add an entry to `SymbolLanguage.all`, with the file extensions and the node types that count as bodies (definitions inside them aren't top-level).

The engine is the same for every language. It keeps only the outermost definitions, attaches the comment directly above each one, and orders them as they appear in the file.

## Code map

| Path | What it does |
|---|---|
| `gitty/App/` | App entry point and the hard-coded source URL |
| `gitty/Core/DocumentStore.swift` | Saved copies on disk and the network fetch: never expires, conditional refresh |
| `gitty/Core/ReadingPositionStore.swift` | Saved reading position per file (UserDefaults) |
| `gitty/Core/SymbolIndexer.swift` | Generic symbol engine: runs a language's query, keeps top-level definitions |
| `gitty/Core/SymbolLanguage.swift` | Languages for Symbols mode: grammar, file extensions, query (C for now) |
| `gitty/Core/CMacroBlanking.swift` | C-only pass before parsing: blanks top-level macro calls such as `OPT_GENERIC(i64)` |
| `gitty/Languages/symbols-*.scm` | One symbols query per language (tags.scm conventions) |
| `gitty/Core/CodeSymbol.swift` | A symbol: name, kind, range (with its leading comment), line, preview |
| `gitty/Core/RawTextDecoder.swift` | Bytes to text, decoded the way Safari does it (BOM, charset, UTF-8, windows-1252) |
| `gitty/Viewer/RawTextStyle.swift` | Safari's raw-text style constants, taken from WebKit's source |
| `gitty/Viewer/CodeTextView.swift` | `UITextView` (TextKit 1, full layout), pull-to-refresh, scroll tracking for the bar |
| `gitty/Viewer/FileBar.swift` | Bottom bar, loading line and the bar + selector stack. Sizes in `FileBarMetrics` |
| `gitty/Viewer/ModeSelector.swift` | Project / File / Symbols selector |
| `gitty/Viewer/BarCollapseTracker.swift` | When the bar collapses while scrolling (shared by File and Symbols) |
| `gitty/Viewer/SymbolsView.swift` | The Symbols list and its cards |
| `gitty/Viewer/SymbolPager.swift` | One symbol at a time: paging, zoom back, read-only text view |
| `gitty/Viewer/CodeDocumentModel.swift` | Screen state: loading, refresh, progress, bar |
| `gitty/Viewer/CodeScreen.swift` | The screen: modes, bottom stack, navigation to the pager |
| `gittyTests/` | Decoder, document store, reading position and symbol indexer tests |
