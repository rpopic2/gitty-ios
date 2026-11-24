import Foundation
import Testing
@testable import gitty

struct SymbolIndexerProtoTests {
    let source = """
    syntax = "proto3";
    package demo.v1;

    import "google/protobuf/descriptor.proto";

    // A person.
    message Person {
      string name = 1;
      map<string, int32> scores = 2;
      oneof contact {
        string email = 3;
        string phone = 4;
      }
      message Address {
        string street = 1;
      }
      enum Kind {
        KIND_UNSPECIFIED = 0;
      }
    }

    enum Status {
      STATUS_UNKNOWN = 0;
      STATUS_OK = 1;
    }

    service People {
      rpc Get(Person) returns (Person);
      rpc List(Person) returns (stream Person) {
        option deprecated = true;
      }
    }

    extend google.protobuf.FieldOptions {
      string label = 50000;
    }
    """

    private func symbols(_ source: String) -> [CodeSymbol] {
        guard case .symbols(let symbols) = SymbolIndexer.index(source, fileExtension: "proto") else {
            Issue.record("expected symbols")
            return []
        }
        return symbols
    }

    @Test func messagesEnumsAndServicesThenTheirMembers() {
        #expect(symbols(source).map { "\($0.kind.rawValue) \($0.name)" } == [
            "type Person",
            "field Person.name",
            "field Person.scores",
            "field Person.email",  // a oneof's fields are the message's
            "field Person.phone",
            "type Person.Address",
            "field Person.Address.street",
            "type Person.Kind",
            "enumMember Person.Kind.KIND_UNSPECIFIED",
            "type Status",
            "enumMember Status.STATUS_UNKNOWN",
            "enumMember Status.STATUS_OK",
            "type People",
            "method People.Get",
            "method People.List",
            "type extend google.protobuf.FieldOptions",
            "field google.protobuf.FieldOptions.label",
        ])
    }

    @Test func aMessageKeepsTheCommentAboveIt() throws {
        let person = try #require(symbols(source).first)
        #expect((source as NSString).substring(with: person.range).hasPrefix("// A person.\nmessage Person {"))
        #expect(person.line == 7)
    }

    @Test func protoFilesAreHighlighted() throws {
        let runs = try #require(SyntaxHighlighter.runs(in: source, fileExtension: "proto"))
        let text = source as NSString
        let keyword = runs.first { text.substring(with: $0.range) == "message" }
        #expect(keyword?.category == .keyword)
        let comment = runs.first { text.substring(with: $0.range) == "// A person." }
        #expect(comment?.category == .comment)
    }
}
