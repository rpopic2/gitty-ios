import Foundation
import Testing
@testable import gitty

struct SymbolIndexerTests {
    let source = """
    #include <stdio.h>
    #define MAX 16
    #define SQUARE(x) ((x) * (x))

    int counter = 0;
    static const char *names[MAX];

    int add(int a, int b);

    struct point {
        int x, y;
    };

    typedef struct {
        int w, h;
    } Size;

    enum color { RED, GREEN };

    // Adds two numbers.
    // Second line of the comment.
    int add(int a, int b) {
        return a + b;
    }

    static char *copy_name(const char *name) {
        return 0;
    }

    void (*handler)(int);

    #ifdef DEBUG
    void debug_log(const char *message) { puts(message); }
    #endif
    """

    private func symbols() throws -> [CodeSymbol] {
        guard case .symbols(let symbols) = SymbolIndexer.index(source, fileExtension: "c") else {
            Issue.record("expected symbols")
            return []
        }
        return symbols
    }

    @Test func findsTopLevelDefinitionsInFileOrder() throws {
        let found = try symbols().map { "\($0.kind.rawValue) \($0.name)" }
        #expect(found == [
            "macro MAX",
            "macro SQUARE",
            "global counter",
            "global names",
            "type struct point",
            "type Size",
            "type enum color",
            "function add",
            "function copy_name",
            "global handler",
            "function debug_log",
        ])
    }

    @Test func skipsPrototypes() throws {
        #expect(try symbols().filter { $0.name == "add" }.count == 1)
    }

    @Test func includesLeadingCommentInRange() throws {
        let add = try #require(try symbols().first { $0.name == "add" })
        let text = (source as NSString).substring(with: add.range)
        #expect(text.hasPrefix("// Adds two numbers."))
        #expect(text.hasSuffix("}"))
        #expect(add.line == 22)  // the definition, not the comment
    }

    @Test func macroRangeHasNoTrailingNewline() throws {
        let max = try #require(try symbols().first { $0.name == "MAX" })
        #expect((source as NSString).substring(with: max.range) == "#define MAX 16")
    }

    @Test func previewStartsAtDefinition() throws {
        let point = try #require(try symbols().first { $0.name == "struct point" })
        #expect(point.preview == "struct point {\n    int x, y;\n}")
    }

    /// From main.c: top-level macro calls without `;` used to swallow the rest of the file.
    @Test func topLevelMacroCallsDontSwallowTheFile() {
        let source = """
        #define LIST(x) x
        OPT_GENERIC(i64)
        enum inclusive {INCL, EXCL};

        HASHMAP_GENERIC(symbol_t, 1024, hash_fnv_1a)
        HASHMAP_GENERIC(type_t, 128, hash_fnv_1a)

        int count = 0;

        char first(const char *s)
        {
            if_opt(i64, value, = parse(s)) {
                return 0;
            }
            return s[0];
        }

        void last(void) {}
        """
        guard case .symbols(let symbols) = SymbolIndexer.index(source, fileExtension: "c") else {
            Issue.record("expected symbols")
            return
        }
        #expect(symbols.map { "\($0.kind.rawValue) \($0.name)" } == [
            "macro LIST",
            "type enum inclusive",
            "global count",
            "function first",
            "function last",
        ])
        #expect(symbols.first { $0.name == "first" }?.line == 10)
    }

    @Test func blankingKeepsLengthAndOnlyTouchesMacroCalls() {
        let source = "OPT_GENERIC(i64)\nint x;\nstatic int\nfoo(int x);\nbar(a)\n{\n}\n" as NSString
        let blanked = SymbolIndexer.blankingTopLevelMacroCalls(in: source)
        #expect((blanked as NSString).length == source.length)
        #expect(blanked == "                \nint x;\nstatic int\nfoo(int x);\nbar(a)\n{\n}\n")
    }

    @Test func otherLanguagesAreUnsupported() {
        guard case .unsupportedLanguage = SymbolIndexer.index("fn main() {}", fileExtension: "rs") else {
            Issue.record("expected unsupportedLanguage")
            return
        }
    }
}
