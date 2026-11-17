import Foundation
import Testing
@testable import gitty

struct SymbolIndexerSwiftTests {
    let source = """
    import Foundation

    let defaultRadius = 1.0
    var counter = 0, total = 0

    /// A shape.
    protocol Shape {
        associatedtype Unit
        var area: Double { get }
        func draw()
        init(size: Double)
    }

    typealias Handler = (Int) -> Void

    enum Color: String {
        case red, green
        case blue = "B"
        var isWarm: Bool { self == .red }
    }

    @MainActor
    final class Circle: Shape {
        typealias Unit = Double
        static let pi = 3.14
        private var radius: Double
        var area: Double { Circle.pi * radius * radius }

        init(size: Double) { radius = size }
        deinit { }

        func draw() {
            func helper() { }
            let local = 1
            _ = { (x: Int) in x }
        }

        subscript(index: Int) -> Double { radius }
        static func + (a: Circle, b: Circle) -> Circle { a }

        struct Inner { var value = 0 }
    }

    extension Circle: Hashable {
        func hash(into hasher: inout Hasher) { }
    }

    actor Counter { func next() -> Int { 0 } }

    func freeFunction() { }
    """

    private func symbols(_ source: String) -> [CodeSymbol] {
        guard case .symbols(let symbols) = SymbolIndexer.index(source, fileExtension: "swift") else {
            Issue.record("expected symbols")
            return []
        }
        return symbols
    }

    @Test func typesExtensionsAndMembersInFileOrder() {
        #expect(symbols(source).map { "\($0.kind.rawValue) \($0.name)" } == [
            "global defaultRadius",
            "global counter, total",
            "type Shape",
            "type Shape.Unit",
            "property Shape.area",
            "method Shape.draw",
            "method Shape.init",
            "type Handler",
            "type Color",
            "enumMember Color.red, green",
            "enumMember Color.blue",
            "property Color.isWarm",
            "type Circle",
            "type Circle.Unit",
            "property Circle.pi",
            "property Circle.radius",
            "property Circle.area",
            "method Circle.init",
            "method Circle.deinit",
            "method Circle.draw",
            "method Circle.subscript",
            "method Circle.+",
            "type Circle.Inner",
            "property Circle.Inner.value",
            "type extension Circle",
            "method Circle.hash",
            "type Counter",
            "method Counter.next",
            "function freeFunction",
        ])
    }

    @Test func nothingFromInsideBodies() {
        let names = symbols(source).map(\.name)
        #expect(!names.contains { $0.hasSuffix("helper") || $0.hasSuffix("local") })
    }

    @Test func docCommentAndAttributesArePartOfTheRange() throws {
        let symbols = symbols(source)
        let shape = try #require(symbols.first { $0.name == "Shape" })
        #expect((source as NSString).substring(with: shape.range).hasPrefix("/// A shape."))
        let circle = try #require(symbols.first { $0.name == "Circle" })
        #expect((source as NSString).substring(with: circle.range).hasPrefix("@MainActor"))
    }

    @Test func operatorAndTypealiasNamesSkipTheirTypes() {
        // This grammar also labels return types and aliased types `name`.
        let source = """
        struct C {
            static func == (a: C, b: C) -> Bool { true }
            func next() -> Int { 0 }
        }
        typealias Pair<T> = (T, T)
        """
        #expect(symbols(source).map(\.name) == ["C", "C.==", "C.next", "Pair"])
    }
}
