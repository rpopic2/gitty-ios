import Foundation
import Testing
@testable import gitty

struct FileFilterTests {
    @Test func anEmptyFilterLetsEverythingThrough() {
        #expect(FileFilter("").matches("a/b.png"))
        #expect(FileFilter("   ").isEmpty)
    }

    @Test func namePatternsMatchInAnyDirectory() {
        let filter = FileFilter("*.cs *.md")
        #expect(filter.matches("Program.cs"))
        #expect(filter.matches("src/App/Main.cs"))
        #expect(filter.matches("README.md"))
        #expect(!filter.matches("src/App/Main.csproj"))
        #expect(!filter.matches("cs/notes.txt"))
    }

    @Test func caseDoesNotMatter() {
        #expect(FileFilter("*.cs").matches("MAIN.CS"))
        #expect(FileFilter("readme*").matches("docs/README.md"))
    }

    @Test func aWordIsFoundAnywhereInThePath() {
        let filter = FileFilter("Scripts")
        #expect(filter.matches("Assets/Scripts/Player.cs"))  // a directory
        #expect(filter.matches("Tools/ScriptsRunner.cs"))  // a name
        #expect(filter.matches("assets/scripts/a.cs"))  // any case
        #expect(!filter.matches("Assets/Art/Script.png"))  // "Script" isn't "Scripts"
        #expect(!filter.matches("README.md"))
    }

    @Test func everyWordMustBeThere() {
        let filter = FileFilter("Scripts Editor")
        #expect(filter.matches("Assets/Scripts/Editor/Build.cs"))
        #expect(!filter.matches("Assets/Scripts/Player.cs"))
    }

    @Test func wordsAndPatternsNarrowTogether() {
        let filter = FileFilter("Scripts *.cs !Generated")
        #expect(filter.matches("Assets/Scripts/Player.cs"))
        #expect(!filter.matches("Assets/Scripts/notes.md"))  // not *.cs
        #expect(!filter.matches("Assets/Player.cs"))  // no Scripts
        #expect(!filter.matches("Assets/Scripts/Generated/Ids.cs"))  // left out
    }

    @Test func questionMarkIsOneCharacter() {
        let filter = FileFilter("?.c")
        #expect(filter.matches("a.c"))
        #expect(!filter.matches("ab.c"))
    }

    @Test func pathPatternsMatchFromTheTop() {
        let filter = FileFilter("src/*.swift")
        #expect(filter.matches("src/App.swift"))
        #expect(!filter.matches("src/Views/List.swift"))  // * stays within one directory
        #expect(!filter.matches("lib/src/App.swift"))
        #expect(FileFilter("/src/*.swift").matches("src/App.swift"))  // a leading / is the top
    }

    @Test func doubleStarCrossesDirectories() {
        let filter = FileFilter("src/**/*.c")
        #expect(filter.matches("src/a.c"))
        #expect(filter.matches("src/x/y/a.c"))
        #expect(!filter.matches("lib/a.c"))
    }

    @Test func aTrailingSlashMeansEverythingInTheDirectory() {
        let filter = FileFilter("Tests/")
        #expect(filter.matches("Tests/a.cs"))
        #expect(filter.matches("Tests/Unit/b.cs"))
        #expect(!filter.matches("Sources/Tests.cs"))
    }

    @Test func exclusionsWin() {
        let filter = FileFilter("*.cs !*Tests.cs !obj/")
        #expect(filter.matches("App.cs"))
        #expect(!filter.matches("AppTests.cs"))
        #expect(!filter.matches("obj/Debug/Gen.cs"))
        // Only exclusions: everything else passes.
        let onlyOut = FileFilter("!*.png")
        #expect(onlyOut.matches("a.c"))
        #expect(!onlyOut.matches("img/a.png"))
    }

    @Test func commasSeparateToo() {
        #expect(FileFilter("*.c,*.h").matches("x.h"))
    }

    @Test func eachProjectKeepsItsOwnFilter() {
        let defaults = UserDefaults(suiteName: "FileFilterTests")!
        defaults.removePersistentDomain(forName: "FileFilterTests")
        let store = ProjectFilterStore(defaults: defaults)
        store.save(" *.cs *.md ", for: "o/r")
        #expect(store.text(for: "o/r") == "*.cs *.md")
        #expect(store.text(for: "o/other") == "")
        store.save("", for: "o/r")
        #expect(store.text(for: "o/r") == "")
        store.save("*.c", for: "o/r")
        store.remove(for: "o/r")
        #expect(store.filter(for: "o/r").isEmpty)
    }
}
