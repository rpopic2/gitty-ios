# gitty

Read and review code on iPhone and iPad: Safari's raw-text look, Photos-style browsing, and a review you can paste into any chat. Offline first: nothing is downloaded unless you ask.

## Features

- **Projects** from a GitHub link, or a **local folder** (Files, or Finder on a Mac), read where it is, uncommitted edits included.
- **Code level:** every symbol of the project under its folders and files, with its code. Tap a title to fold it (hold it for Collapse All or Expand All), tap the code for its full-screen card.
- **Cards:** swipe between symbols, search, find occurrences, and double tap a selection to grow it by syntax. Set a stack of cards aside and come back to it from the chip over the bar.
- **Albums:** the symbols, files and lines you want together. Swipe the bar to switch between them, or swipe it up for all of them.
- **Git** (libgit2): clone, branches, history, blame, and diffs between branches as albums.
- **Review:** select code and choose Comment. Comments name the file, lines and commit, in compact or Markdown form, then Share.
- **Syntax** for C, C#, Swift and Protocol Buffers (tree-sitter), with GitHub, Xcode, Subtle or Solarized colors.

## Building

- Xcode with the iOS 18 SDK or later. iOS 18.0+, iPhone and iPad, and Apple Silicon Macs (My Mac, Designed for iPad).
- Open `gitty.xcodeproj`. The Swift packages (tree-sitter grammars, libgit2) resolve by themselves.
- `gitty/` is a synchronized folder: new files join the target automatically. The default actor isolation is `MainActor`; code that runs off the main thread is `nonisolated`.
- **Private repositories** use gitty's GitHub App, signed in with the device flow. Its client ID and name are in `GitHubAppConfig` (`gitty/Core/GitHubAuth.swift`). For your own app, create a GitHub App with Device Flow on and read-only Contents, and put its values there.

## Adding a language

1. Add the grammar's Swift package to the `gitty` target.
2. Put its `highlights.scm` in `gitty/Languages/highlights-<name>.scm`, and a `symbols-<name>.scm` based on its `tags.scm` (`@definition.function`, `.method`, `.class`… with `@name`).
3. Add an entry to `SymbolLanguage.all`: file extensions, body node types, and container node types (whose members get their own entries).

## Layout

| Folder | What's in it |
|---|---|
| `gitty/App` | The app, and the root view |
| `gitty/Core` | Projects, local folders, Git (`Git.swift`, `CloneStore.swift`), documents, symbols, albums, reviews |
| `gitty/Viewer` | The screens: Code level (`SymbolsView`, `CodeTable`), cards (`SymbolPager`), bar, sidebar, albums |
| `gitty/Languages` | Tree-sitter queries for symbols and highlighting |
| `gittyShare` | Share extension: opens a link shared from Safari in gitty |
