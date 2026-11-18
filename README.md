# gitty

An iOS app for reading and reviewing code on the go: fast, light on the battery, and native-feeling, like Safari plus Photos for code.

## Features

- **Safari's raw-text look:** Courier 13pt, wrapped lines, Safari's margins, light and dark mode.
- **Works offline, never expires:** downloaded files stay on the device and open without the network. They are downloaded again only when you pull to refresh, and an unchanged file costs just an HTTP 304.
- **Picks up where you left off:** the reading position of each file is saved when scrolling stops and when the app goes to the background. It is stored as a text position, so it survives rotation and refreshes. The Symbols list remembers its place too: the card in the middle of the screen, found again by name after a refresh.
- **Smooth, exact scrolling:** every line's height is known up front, so the scroll bar and text never jump.
- **Safari-style bottom bar:** shows the file name, collapses while you scroll down, and shows a thin loading line only while downloading. Liquid Glass on iOS 26+, the Safari 18 style on iOS 18.
- **Photos-style mode selector** under the bar: **Project**, **File** (the raw file) and **Symbols**.
- **Projects:** enter, paste or share a GitHub repository link (`github.com/owner/repo`, or `…/tree/branch/folder`) to add it as a project. Browse its folders like the Files app, with code files first; a file downloads when you open it, and **Download All** saves a folder for offline reading. The file list comes from GitHub's trees API, fetched when the project is added and again only on pull to refresh. For a private repository, sign in to GitHub when it fails to load (see below).
- **Project:** every file you've opened or saved, recent first, with an icon on files that open offline. Tap one to open it in File mode, or swipe one to delete it and its saved copy. With no file open, the start page shows this list with the address bar ready.
- **Symbols:** every definition as a card, like photos in Photos. For C that's top-level functions, types, macros and globals. For C# and Swift, each type (and Swift extension) is followed by its members, named `Type.Member`. Tap a card to see only that symbol, swipe left and right to move between symbols, and swipe down to zoom back to the list. Select or double-tap a name, in File or in a symbol's page, and choose **Jump to Definition** to search symbols for it, with the search field focused. In a symbol's page, tap the caption at the bottom to see it in the file. In File and Symbols mode the bar searches symbols (in File, the matches are listed above the field and open the symbol's page). The address is edited from Project, or anywhere a file has no symbols. Symbol search uses fuzzy matching like Xcode's Open Quickly ("crdr" finds `Circle.draw`) and lists the best matches first. The search stays until you clear it, and swiping in a symbol opened from the results goes through the matches only. Symbols come from [tree-sitter](https://tree-sitter.github.io/).

- **Open any file by URL:** tap the bar and enter a URL, like in Safari. A `github.com/…/blob/…` link opens as the raw file. Other URLs load as typed, and a web page shows its HTML source, with a banner (and a long-press menu item) to open it in the default browser instead. The last file reopens on launch. You can also share a page from Safari to gitty, or use **Paste and Go**: long-press the bar, or pick it from the field's edit menu.

## Project

- iOS 18.0+, iPhone and iPad.
- `gitty/` is a synchronized folder, so any file you put in it joins the `gitty` target automatically.
- The default actor isolation is `MainActor`. Types that run off the main thread are marked `nonisolated`.

### Packages (one time, in Xcode)

Symbols mode uses tree-sitter. Choose File ▸ Add Package Dependencies… and add these to the `gitty` target:

| Package | Version | Product |
|---|---|---|
| `https://github.com/tree-sitter/swift-tree-sitter` | 0.25.0 | SwiftTreeSitter |
| `https://github.com/tree-sitter/tree-sitter-c` | 0.24.2 | TreeSitterC |
| `https://github.com/tree-sitter/tree-sitter-c-sharp` | 0.23.5 | TreeSitterCSharp |
| `https://github.com/alex-pinkus/tree-sitter-swift` | 0.7.4-with-generated-files (exact) | TreeSitterSwift |

### Opening links from Safari (one time, in Xcode)

The `gittyShare/` folder is a Share Extension: Safari ▸ Share ▸ gitty opens the page in gitty, exactly as if it had been typed into the bar.

1. **Link scheme:** select the `gitty` target ▸ Info ▸ URL Types ▸ +, and set URL Schemes to `gitty`.
2. **Extension target:** File ▸ New ▸ Target ▸ Share Extension, with Product Name `gittyShare`, embedded in `gitty`. If Xcode asks to activate a scheme, either answer is fine.
3. Xcode writes its template files into `gittyShare/`. Put ours back with `git checkout -- gittyShare`, then delete `gittyShare/Base.lproj/MainInterface.storyboard` (or `MainInterface.storyboard`). The extension has no storyboard.
4. In the `gittyShare` target, set the iOS deployment target to **18.0**, the same as the app.

Apple has no API for a share extension to open its own app. The extension uses the common workaround: it finds the `UIApplication` in the responder chain and calls `open` through the Objective-C runtime.

### Private repositories: gitty's GitHub App (one time, on github.com)

gitty signs in with GitHub's device flow: it shows a code, you enter it on github.com in Safari, and gitty gets a token. No password is typed into gitty and no server is involved. The token belongs to a GitHub App, so it can only **read** the repositories you install the app on. It's kept in the Keychain (this device only) and sent only to `api.github.com` and `raw.githubusercontent.com`. The same token works as the password for `git clone` over HTTPS, for a future Git client.

1. Go to github.com ▸ Settings ▸ Developer settings ▸ GitHub Apps ▸ **New GitHub App** (github.com/settings/apps/new).
2. **Name:** anything unique, such as `gitty-reader-<you>`. **Homepage URL:** this repository's URL. Leave **Callback URL** empty.
3. Check **Enable Device Flow**. Under **Webhook**, uncheck **Active**.
4. **Repository permissions:** set **Contents** to **Read-only**. Metadata becomes read-only by itself.
5. **Where can this GitHub App be installed?** Only on this account. Then **Create GitHub App**.
6. On the app's **Optional features** page, opt out of **User-to-server token expiration**. Otherwise tokens expire after 8 hours. gitty tries to refresh them, and if GitHub won't refresh without the app's secret (which an app can't keep), you'd sign in again.
7. **Install App** on your account, and choose the private repositories gitty may read. Change the list any time from **Choose Repositories** in gitty, or from the app's page on GitHub.
8. Put the app's **Client ID** (`Iv23…`) and its URL name (the part after `github.com/apps/`) in `GitHubAppConfig` in `gitty/Core/GitHubAuth.swift`. Neither is a secret.

To sign in, open a private repository: **Sign In to GitHub** appears under the error. To sign out, long-press a project ▸ **Sign Out of GitHub**. Saved files stay on the device. To revoke the token, use github.com ▸ Settings ▸ Applications.

### Tests

The `gittyTests/` folder holds Swift Testing tests but has no target yet. To add one, choose File ▸ New ▸ Target ▸ Unit Testing Bundle and name it `gittyTests` (Swift Testing, testing `gitty`). Then replace the folder Xcode generates with the existing `gittyTests/` folder and press ⌘U.

## Adding a language to Symbols mode

1. Add the grammar's Swift package (for example `tree-sitter-python`) to the `gitty` target.
2. Add `gitty/Languages/symbols-<name>.scm`. Start from the grammar's own `queries/tags.scm` and use its conventions: capture the definition as `@definition.function`, `.method`, `.class`, `.type`, `.macro`, `.variable` or `.constant`, and its name as `@name`. You can also capture `@name.prefix`, which is shown before the name.
3. Add an entry to `SymbolLanguage.all`, with the file extensions, the node types that count as bodies (definitions inside them are skipped), and the container node types whose members get their own cards (such as classes).

The engine is the same for every language. It keeps top-level definitions plus the members of containers (named `Container.Member`), attaches the comment directly above each one, and orders them as they appear in the file.

## Code map

| Path | What it does |
|---|---|
| `gitty/App/` | App entry point, and the root view that picks the start page or the open file |
| `gitty/Core/AddressParser.swift` | What was typed → the URL to load (https only, GitHub links → raw) |
| `gitty/Core/GitHubProject.swift` | Repository links, projects and their file lists (GitHub trees API) |
| `gitty/Core/GitHubAuth.swift` | Sign in with GitHub (device flow), the token in the Keychain, and which hosts get it |
| `gitty/Core/RecentFilesStore.swift` | Recently opened URLs (UserDefaults) |
| `gitty/Core/SymbolSearch.swift` | Fuzzy symbol search and ranking |
| `gitty/Core/WebPageDetector.swift` | Whether a download is a web page (served as HTML) |
| `gitty/Viewer/AddressEditor.swift` | Editing the address: URL field above the keyboard, Paste and Go |
| `gitty/Core/DocumentStore.swift` | Saved copies on disk and the network fetch: never expires, conditional refresh |
| `gitty/Core/ReadingPositionStore.swift` | Saved reading position per file, in File and the Symbols list (UserDefaults) |
| `gitty/Core/SymbolIndexer.swift` | Generic symbol engine: runs a language's query, keeps top-level definitions |
| `gitty/Core/SymbolLanguage.swift` | Languages for Symbols mode: grammar, file extensions, query, body and container node types (C, C#, Swift) |
| `gitty/Core/CMacroBlanking.swift` | C-only pass before parsing: blanks top-level macro calls such as `OPT_GENERIC(i64)` |
| `gitty/Languages/symbols-*.scm` | One symbols query per language (tags.scm conventions) |
| `gitty/Core/CodeSymbol.swift` | A symbol: name, kind, range (with its leading comment), line, preview |
| `gitty/Core/RawTextDecoder.swift` | Bytes to text, decoded the way Safari does it (BOM, charset, UTF-8, windows-1252) |
| `gitty/Viewer/RawTextStyle.swift` | Safari's raw-text style constants, taken from WebKit's source |
| `gitty/Viewer/CodeTextView.swift` | `UITextView` (TextKit 1, full layout), pull-to-refresh, scroll tracking for the bar |
| `gitty/Viewer/FileBar.swift` | Bottom bar, loading line and the bar + selector stack. Sizes in `FileBarMetrics` |
| `gitty/Viewer/ModeSelector.swift` | Project / File / Symbols selector |
| `gitty/Viewer/ProjectFolderView.swift` | Browsing a project's folders, Download All, sign-in when a repository isn't found |
| `gitty/Viewer/GitHubSignInView.swift` | The sign-in sheet: the code to enter on GitHub, and waiting for it |
| `gitty/Viewer/ProjectView.swift` | Project mode and start page: recent and saved files |
| `gitty/Viewer/BarCollapseTracker.swift` | When the bar collapses while scrolling (shared by File and Symbols) |
| `gitty/Viewer/SymbolsView.swift` | The Symbols list and its cards |
| `gitty/Viewer/SymbolPager.swift` | One symbol at a time: paging, zoom back, read-only text view |
| `gitty/Viewer/CodeDocumentModel.swift` | Screen state: loading, refresh, progress, bar |
| `gitty/Viewer/CodeScreen.swift` | The screen: modes, bottom stack, navigation to the pager |
| `gittyShare/` | Share Extension: hands a shared URL to the app as `gitty://open?url=…` |
| `gittyTests/` | Decoder, document store, reading position, symbol indexer, symbol search, address, GitHub project and sign-in tests |
