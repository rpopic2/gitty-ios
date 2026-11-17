import Foundation
import Testing
@testable import gitty

struct SymbolIndexerCSharpTests {
    let source = """
    using System;
    namespace Demo.App
    {
        /// <summary>A point.</summary>
        public record Point(int X, int Y);
        public enum Color { Red, Green = 2 }
        public delegate void Handler(int code);
        public interface IShape { double Area { get; } void Draw(); }
        public class Circle : IShape
        {
            public const double Pi = 3.14, Tau = 6.28;
            private double radius;
            public event EventHandler Changed;
            public Circle(double radius) { this.radius = radius; }
            ~Circle() { }
            public double Area => Pi * radius * radius;
            public double this[int i] => i;
            public void Draw() { void Helper() { } var x = 1; }
            public static Circle operator +(Circle a, Circle b) => a;
            public static implicit operator double(Circle c) => c.radius;
            public class Inner { public int Value { get; set; } }
        }
    }
    """

    private func symbols(_ source: String) -> [CodeSymbol] {
        guard case .symbols(let symbols) = SymbolIndexer.index(source, fileExtension: "cs") else {
            Issue.record("expected symbols")
            return []
        }
        return symbols
    }

    @Test func typesThenTheirMembersInFileOrder() {
        #expect(symbols(source).map { "\($0.kind.rawValue) \($0.name)" } == [
            "type Point",
            "type Color",
            "enumMember Color.Red",
            "enumMember Color.Green",
            "type Handler",
            "type IShape",
            "property IShape.Area",
            "method IShape.Draw",
            "type Circle",
            "field Circle.Pi, Tau",
            "field Circle.radius",
            "field Circle.Changed",
            "method Circle.Circle",
            "method Circle.~Circle",
            "property Circle.Area",
            "property Circle.this",
            "method Circle.Draw",
            "method Circle.operator +",
            "method Circle.operator double",
            "type Circle.Inner",
            "property Circle.Inner.Value",
        ])
    }

    @Test func nothingFromInsideBodies() {
        let names = symbols(source).map(\.name)
        #expect(!names.contains { $0.hasSuffix("Helper") || $0.hasSuffix(".x") })
    }

    @Test func docCommentIsPartOfTheRange() throws {
        let point = try #require(symbols(source).first { $0.name == "Point" })
        let text = (source as NSString).substring(with: point.range)
        #expect(text.hasPrefix("/// <summary>A point.</summary>"))
        #expect(point.line == 5)
    }

    @Test func typeCardCoversTheWholeType() throws {
        let circle = try #require(symbols(source).first { $0.name == "Circle" })
        let text = (source as NSString).substring(with: circle.range)
        #expect(text.hasPrefix("public class Circle"))
        #expect(text.hasSuffix("}"))
        #expect(text.contains("class Inner"))
    }

    @Test func explicitInterfaceImplementationsKeepTheInterface() {
        let source = """
        class Bag : ICollection<int>, IEnumerable
        {
            bool ICollection<int>.IsReadOnly => false;
            IEnumerator IEnumerable.GetEnumerator() => null;
        }
        """
        #expect(symbols(source).map(\.name) == [
            "Bag",
            "Bag.ICollection<int>.IsReadOnly",
            "Bag.IEnumerable.GetEnumerator",
        ])
    }

    @Test func fileScopedNamespace() {
        let source = """
        namespace Demo;

        public static class Util
        {
            public static int Twice(int x) => x * 2;
        }
        """
        #expect(symbols(source).map(\.name) == ["Util", "Util.Twice"])
    }
}
