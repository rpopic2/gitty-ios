# gitty

An iOS app for reading and reviewing code on the go: fast, light on the battery, and native-feeling, like Safari plus Photos for code.

## Features

- **Safari's raw-text look:** Courier 13pt, wrapped lines, Safari's margins, light and dark mode. The sidebar's **Code Font** section switches to JetBrains Mono (bundled, under the SIL Open Font License) and sets the size, for pages and the symbol levels.
- **Syntax highlighting** for C, C# and Swift, with each tree-sitter grammar's own highlights query: on pages, the Code level, card previews and the Files level's lines. Choose the colors in the sidebar's Code Font section: **GitHub** (the default), **Xcode**, **Subtle** or **Solarized**, each with light and dark colors, or **None** for Safari's plain raw text. Big files are colored in the background, and the Code level shows each block plain until it's colored.
- **Works offline, never expires:** downloaded files stay on the device and open without the network. They are downloaded again only when you pull to refresh, and an unchanged file costs just an HTTP 304.
- **Picks up where you left off:** a file's page (the whole file) saves its reading position when scrolling stops, and comes back to it. It is stored as a text position, so it survives rotation and refreshes. The symbol list remembers its place too: the symbol in the middle of the screen, found again by name after a refresh. A file you open starts at its own entry in Code.
- **Smooth, exact scrolling:** every line's height is known up front, so the scroll bar and text never jump.
- **Safari-style bottom bar:** shows the name of the file in view (the project's in Project), collapses while you scroll down, and shows a thin loading line only while downloading. Liquid Glass on iOS 26+, the Safari 18 style on iOS 18.
- **Photos-style zoom levels** under the bar, out to in: **Project** (the project's files), **Files** (the symbols as rows, grouped by file), **Symbols** (cards) and **Code** (every symbol's whole code). Tap the selector to move between them, like Photos' Years / Months / Days / All (pinching only closes a symbol's card or a diff).
- **Sidebar:** swipe left from the right edge of the screen to push the content off and show the full-screen sidebar: **Files**, your **Projects** and **Albums**, and **Settings** at the bottom. Choosing Files or a project shows it in the Project tab, where the bar shows the project's name; tapping it edits the repository's address. Moving on from there to Files, Symbols or Code shows that project too: if the open file is in another one, the project's file you opened last takes its place (or its first downloaded file, or else its README or first file). Swipe right on the sidebar to close it. (On a symbol's page that swipe pages instead.)
- **Projects:** enter, paste or share a GitHub repository link (`github.com/owner/repo`, or `…/tree/branch/folder`) to add it as a project and open it. The Project tab lists all of the open project's files, under a header for each directory, with code files first; tap a file for its details (path, size, last change, history, Open on GitHub) and **Open** at the top right to see its code (it downloads when you open it), or **Clone** the whole project with Git for offline reading and history: a shallow clone of its branch or tag (the latest commit only; the size shown beside it is the files', and the download is compressed). With a filter (or a project that's a folder of its repository), Clone offers **Clone Filtered Files**: Git still downloads every file (libgit2 can't leave any out of a fetch, so images still come down, compressed), but only the files the filter shows are checked out on the device, and when you change the filter the clone checks out what it shows now (no download). A cloned project's files are read from the clone, and the ones downloaded one by one are deleted; its button's menu has **Delete Clone**. Swipe left on a file downloaded on its own to delete its download (it stays in the list). Under the filter, the **branch row** lists the repository's branches and tags; choosing one lists the files there (a clone fetches that branch or tag's latest commit and checks it out). The **History** button at its end lists the branch's commits, newest first (from the clone: **Clone to See History** if there's none; a fresh clone fetches the next 100 commits right away, **Load More History** fetches 100 more, and pull to refresh fetches the latest); tap a commit for its message, author, date, hash and the files it changed, and a file for its diff. Under it, tap the filter to narrow the project to some files, such as `*.cs *.md`: space-separated patterns on the file name, or on the path when they have a `/` (`src/*.swift`, `src/**/*.c`, or `Tests/` for a whole directory), with `!` to leave files out (`!*Tests.cs`). The filter applies to the list and the project-wide Symbols and search (a clone has every file) (the open file always shows its own), and each project keeps its own. The file list comes from GitHub's trees API, fetched when the project is added and again only on pull to refresh. For a private repository, sign in to GitHub when it fails to load (see below). The sort button left of the mode selector lists the files by name (under directory headers) or by when you last opened them (one flat list, each file's folder after its name; files never opened come after, by name), either way reversible. Each project keeps its own order, for the Project tab and for Symbols.
- **Albums,** like Photos': the symbols, whole files and lines of one project you want to see together. Touch and hold a card, a Files-level row or file header, a Code-level title, or a file in the Project tab, and choose **Add to Album** (a checkmark shows the albums that have it; choosing one of those takes it out), or **New Album…** to make one with it. On a page, select some lines and choose **Add to Album** in the text menu to keep just those lines, as an entry of their own named after their first line. At the Symbols level, choose **Select** in a card's menu to tap several cards, then add them all from the bar. Albums are listed in the sidebar under the projects (swipe one to rename or delete it; **New Album** asks which project it's of). Choosing an album shows its project with only what's in the album at Files, Symbols and Code, in the project's order, and the bar shows the album's name; search looks only through the album. A symbol is kept by its kind and name, so it's still there after its file changes (the nearest one, when several share a name), and a whole file brings all its symbols, new ones too. A file added from Project is downloaded first. Deleting a project deletes its albums.
- **Files:** every file you've opened or saved that isn't in a project, recent first, with an icon on files that open offline. Tap one to open it, or swipe one to delete it and its saved copy. With no file open, the start page shows the open project or Files, with the address bar ready.
- **Code review:** select code on a file's or a symbol's page and choose **Comment**. A review opens like a new message in Mail, with the file and lines filled in (`alc/main.c:12-14: `) and the cursor ready. It's one plain text you can edit anywhere. Comment again and it's added at the end. Swipe the review down to set it aside: it waits above the bar (and on a full-screen card or diff, above its caption), and a tap brings it back. **Share** sends the raw text anywhere (an AI chat, Messages, Notes); once it's shared, the review is done. In Settings you can switch comments to Markdown, with a heading and the selected code. Comments carry what an LLM needs to act on them without asking: the first comment on a repository adds a heading once (`Review of owner/repo (branch main, at 3f2a9c1)`), and a cloned file's comments name the commit it's at (`alc/main.c@3f2a9c1:12-14: `). You can also comment on lines of a **diff**: the comment names the file at the commit and the lines before and after the change (`src/parse.c@3f2a9c1 (before 40-42, after 40-44): `); in Markdown it adds the commit's full hash and message, and the selected change in a `diff` block with its `+` and `-` marks. The review opens over the diff.
- **Settings:** your GitHub account (sign in, choose repositories, sign out), the review's comment format, how much space saved files take (with Delete All Saved Files) and how much the clones take, the version, and open-source licenses.
- **Symbols:** every definition, like photos in Photos, each file's symbols after an entry for the file itself: the open file's first, then those of every other downloaded text file in its project (files in other projects or opened by URL show just their own). A file without symbols (a README, a web page, another language) is just its entry. Tap a file's entry to read the whole file on its page, where File used to be: select text for Comment and Search, pull to refresh it, and it comes back where you left off. **Tap a page's caption** for its file's info: its path, size and lines, **Open on GitHub**, its last change and its **history**. History comes from the project's clone (**Clone to See History** if there's none); a fresh shallow clone fetches a little more history until the file's last change shows up, and **Load More History** fetches 100 more commits at a time. Tap a commit for what it changed: a unified diff, full screen like a symbol's card, on the same text view as a page (select, copy, Highlight), added lines on green and removed lines on red across the whole width, with syntax colors, opening on this file; swipe sideways for the commit's other files. A caption at the bottom names the file, the author and date, and which of the commit's files it is; pull down past the top of a diff, or pinch, to close it. On any page or diff, and at the Code level, **swipe in from the left edge and hold** to peek at the line numbers: the page (at the Code level, the whole list, titles too) slides right and each line's number shows beside it (a diff's are the file's). The Code level's titles don't show line numbers: peek instead. **Double tap an identifier** on a page or diff to highlight it, or to remove its highlight; a double tap anywhere else selects a word as usual. Pull to refresh on a cloned file pulls its project: the branch or tag's latest commit is fetched and checked out. Search finds files by name too, and a symbol's page from another file names that file in its caption. For C that's top-level functions, types, macros and globals. For C# and Swift, each type (and Swift extension) is followed by its members, named `Type.Member`. Tap a card to see only that symbol, swipe left and right to move between symbols, and pinch or swipe down to close it. At the Files level, the search finds files by name instead (fuzzy, like symbol search; the field says Search Files), each listed with all its symbols. Each file lists its symbols' declarations like a C header (each one's first line, with its kind's icon), under a sticky header with its symbol count (search results put the file with the best match first): tap a header to fold that file (it stays folded), its open button to show its code, or a line to go to its card. At the Code level, every symbol shows its whole code (a type, such as a class, up to its first member, since its members follow as their own blocks), edge to edge in the raw-text style, laid out by Core Text in the background in pieces of 100 lines and drawn from those layouts, so scrolling never measures or shapes text on the main thread (other files' code prepared in the background, the symbols on screen first and the next few ahead of time), under a slim title that sticks while you read it (a file is just a title line before its symbols); tap a symbol's code to open its page at the lines you were reading (the line you tapped stays where it was on screen, and the page fades in over the code; code that fits on the page isn't scrolled), its title to open the page at the top, and a file's title to read the whole file. The zoom level is kept. The sort button left of the mode selector orders the project's files by name or by when you last opened them (files you've never opened come after, by name), and can reverse the order; the open file's symbols always come first, and each file's symbols stay in file order. Select some text on a page and choose **Search** to search symbols for it, with the search field focused. Select an identifier (or just part of it) and choose **Highlight** to mark it on every page, until you choose **Remove Highlight** on one of its occurrences; highlighting another replaces it. Tree-sitter finds the occurrences: identifiers only, never comments or strings, and of the same kind (the type `Point` doesn't mark a variable named `Point`; in C# every name is the same kind). Pages in another language mark identifiers with the same name, and pages without a grammar mark whole words, exact case. At the symbol levels the bar searches symbols; the address is edited from Project. Symbol search uses fuzzy matching like Xcode's Open Quickly ("crdr" finds `Circle.draw`) and lists the best matches first. It runs in the background, so typing never waits: on a big project the matches fill in as they're found, the open file's first. To close the search field, press Search on the keyboard, swipe down on it, or swipe on the list; that swipe only closes it. The search stays until you clear it (clearing it brings the list back to where it was), and swiping in a symbol opened from the results goes through the matches only. Symbols come from [tree-sitter](https://tree-sitter.github.io/).

- **Open any file by URL:** tap the bar and enter a URL, like in Safari. A `github.com/…/blob/…` link opens as the raw file. Other URLs load as typed, and a web page shows its HTML source, with a banner (and a long-press menu item) to open it in the default browser instead. The last file reopens on launch. You can also share a page from Safari to gitty, or use **Paste and Go**: long-press the bar, or pick it from the field's edit menu.

## Project

- iOS 18.0+, iPhone and iPad.
- `gitty/` is a synchronized folder, so any file you put in it joins the `gitty` target automatically.
- The default actor isolation is `MainActor`. Types that run off the main thread are marked `nonisolated`.

### Packages (one time, in Xcode)

Symbols mode and syntax highlighting use tree-sitter, and Clone, history and diffs use libgit2. Choose File ▸ Add Package Dependencies… and add these to the `gitty` target:

| Package | Version | Product |
|---|---|---|
| `https://github.com/tree-sitter/swift-tree-sitter` | 0.25.0 | SwiftTreeSitter |
| `https://github.com/tree-sitter/tree-sitter-c` | 0.24.2 | TreeSitterC |
| `https://github.com/tree-sitter/tree-sitter-c-sharp` | 0.23.5 | TreeSitterCSharp |
| `https://github.com/alex-pinkus/tree-sitter-swift` | 0.7.4-with-generated-files (exact) | TreeSitterSwift |
| `https://github.com/ibrahimcetin/libgit2` | 1.9.2 (exact) | libgit2 |

The libgit2 package builds libgit2 from source for iOS (HTTPS through Apple's Security framework), the same package SwiftGitX uses. gitty calls its C API directly, through `gitty/Core/Git.swift`.

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

To sign in, open a private repository (**Sign In to GitHub** appears under the error), or use Settings. Sign out in Settings. Saved files stay on the device. To revoke the token, use github.com ▸ Settings ▸ Applications.

### Tests

The `gittyTests/` folder holds Swift Testing tests but has no target yet. To add one, choose File ▸ New ▸ Target ▸ Unit Testing Bundle and name it `gittyTests` (Swift Testing, testing `gitty`). Then replace the folder Xcode generates with the existing `gittyTests/` folder and press ⌘U.

## Adding a language to Symbols mode

1. Add the grammar's Swift package (for example `tree-sitter-python`) to the `gitty` target.
2. Copy the grammar's `queries/highlights.scm` to `gitty/Languages/highlights-<name>.scm` (its captures map to colors in `SyntaxCategory`), and add `gitty/Languages/symbols-<name>.scm`. Start from the grammar's own `queries/tags.scm` and use its conventions: capture the definition as `@definition.function`, `.method`, `.class`, `.type`, `.macro`, `.variable` or `.constant`, and its name as `@name`. You can also capture `@name.prefix`, which is shown before the name.
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
| `gitty/Core/Review.swift` | Review text: comment formats (compact, Markdown), line numbers, file names |
| `gitty/Core/ProjectSymbolIndex.swift` | Symbols of a project's downloaded files, indexed on demand and kept in memory |
| `gitty/Core/IdentifierHighlight.swift` | Highlight: the identifiers on a page (tree-sitter) and where one occurs |
| `gitty/Core/ProjectStartFile.swift` | Which file to open when you leave a project chosen in the sidebar for the symbol levels |
| `gitty/Core/SymbolSearch.swift` | Fuzzy symbol search and ranking |
| `gitty/Core/WebPageDetector.swift` | Whether a download is a web page (served as HTML) |
| `gitty/Viewer/AddressEditor.swift` | Editing the address: URL field above the keyboard, Paste and Go |
| `gitty/Core/DocumentStore.swift` | Saved copies on disk and the network fetch: never expires, conditional refresh |
| `gitty/Core/ReadingPositionStore.swift` | Saved reading position per file page, and the symbol list's place (UserDefaults) |
| `gitty/Core/SymbolIndexer.swift` | Generic symbol engine: runs a language's query, keeps top-level definitions |
| `gitty/Core/SymbolLanguage.swift` | Languages for Symbols mode: grammar, file extensions, query, body and container node types (C, C#, Swift) |
| `gitty/Core/CMacroBlanking.swift` | C-only pass before parsing: blanks top-level macro calls such as `OPT_GENERIC(i64)` |
| `gitty/Languages/symbols-*.scm` | One symbols query per language (tags.scm conventions) |
| `gitty/Languages/highlights-*.scm` | Each grammar's own highlights query, copied from its repository, for syntax highlighting |
| `gitty/Core/SyntaxHighlighter.swift` | Syntax highlighting: the code as runs, each with its category (keyword, string, comment…) |
| `gitty/Viewer/SyntaxTheme.swift` | The color themes, and coloring text for pages and SwiftUI |
| `gitty/Core/CodeSymbol.swift` | A symbol: name, kind, range (with its leading comment), line, preview |
| `gitty/Core/RawTextDecoder.swift` | Bytes to text, decoded the way Safari does it (BOM, charset, UTF-8, windows-1252) |
| `gitty/Viewer/RawTextStyle.swift` | Safari's raw-text style constants, taken from WebKit's source, and the chosen code font (`CodeTextStyle`) |
| `gitty/Fonts/` | JetBrains Mono Regular and its license (registered at launch) |
| `gitty/Viewer/FileBar.swift` | Bottom bar, loading line and the bar + selector stack. Sizes in `FileBarMetrics` |
| `gitty/Viewer/ModeSelector.swift` | The zoom levels (Project / Files / Symbols / Code) and their selector |
| `gitty/Viewer/ProjectFilesView.swift` | The open project's files by directory, the filter, the branch row, Clone, sign-in when a repository isn't found |
| `gitty/Core/Git.swift` | A thin Swift layer over libgit2: fetch one branch or tag (shallow, with the GitHub token), check out, a file's history, a commit's changes and patches |
| `gitty/Core/CloneStore.swift` | Cloned projects: cloning, switching branch or tag, more history, and reading their files in place of downloads (`CloneIndex`) |
| `gitty/Core/CodePieces.swift` | Long code cut into pieces of 100 lines for the Code level |
| `gitty/Viewer/LineDecorations.swift` | Whole-line backgrounds (diffs) and the line-number peek on pages |
| `gitty/Viewer/CodePeek.swift` | The Code level's line-number peek |
| `gitty/Viewer/CodeLayout.swift` | The Code level's code, laid out by Core Text off the main thread and drawn from that layout (with the peek's numbers) |
| `gitty/Core/UnifiedDiff.swift` | A unified diff as lines to draw, with line numbers |
| `gitty/Core/ProjectFileLocation.swift` | A file address's project and path in the repository, and its page on github.com |
| `gitty/Viewer/FileInfoView.swift` | A file's info panel: path, size, last change, history, Open on GitHub, Clone |
| `gitty/Viewer/CommitDiffView.swift` | A commit's changes, full screen, one file per page, as colored unified diffs |
| `gitty/Viewer/BranchHistoryView.swift` | The branch's history (the branch row's History), and a commit's changed files |
| `gitty/Core/Album.swift` | Albums: what's in them, which entries of the list they show (symbols found again by name, lines), and saving them |
| `gitty/Viewer/AlbumViews.swift` | Add to Album menus, naming an album, and Select at the Symbols level |
| `gitty/Core/SymbolGroups.swift` | Symbols grouped by file for the zoomed-out view, and which files are folded |
| `gitty/Core/ListSorting.swift` | Name or recently opened order, saved per project, and when each file was last opened |
| `gitty/Core/FileFilter.swift` | Project filters (`*.cs *.md !Tests/`): matching, and saving one per project |
| `gitty/Viewer/SideBar.swift` | The right sidebar: full screen, edge swipe to open and swipe right to close, Files / projects / albums / Settings |
| `gitty/Viewer/ReviewComposer.swift` | The review draft, its Mail-style sheet and docked bar, and sharing |
| `gitty/Viewer/SettingsView.swift` | Settings: GitHub account, storage, about and licenses |
| `gitty/Viewer/GitHubSignInView.swift` | The sign-in sheet: the code to enter on GitHub, and waiting for it |
| `gitty/Viewer/ProjectView.swift` | Project mode and start page: the open project, or Files (recent and saved files outside projects) |
| `gitty/Viewer/BarCollapseTracker.swift` | When the bar collapses while scrolling |
| `gitty/Viewer/SymbolsView.swift` | The symbol levels: rows grouped by file, cards, whole code |
| `gitty/Viewer/SymbolPager.swift` | One symbol (or whole file) at a time: paging, closing with a pinch or swipe down, the page text view with its reading position and pull to refresh |
| `gitty/Viewer/CodeDocumentModel.swift` | Screen state: loading, refresh, progress, bar |
| `gitty/Viewer/CodeScreen.swift` | The screen: zoom levels, bottom stack, navigation to the pager |
| `gittyShare/` | Share Extension: hands a shared URL to the app as `gitty://open?url=…` |
| `gittyTests/` | Decoder, document store, reading position, symbol indexer, symbol search, address, GitHub project and sign-in tests |
