import Foundation
import Testing
@testable import gitty

struct RawTextDecoderTests {
    @Test func decodesUTF8() {
        let text = "int main(void) { puts(\"한글 ✓ 🚀\"); }\n"
        #expect(RawTextDecoder.decode(Data(text.utf8), contentType: "text/plain; charset=utf-8") == text)
    }

    @Test func treatsUndeclaredTextAsUTF8() {
        let text = "naïve — café\n"
        #expect(RawTextDecoder.decode(Data(text.utf8), contentType: "text/plain") == text)
        #expect(RawTextDecoder.decode(Data(text.utf8), contentType: nil) == text)
    }

    @Test func usesDeclaredCharset() {
        let data = Data([0x68, 0xE9, 0x6C, 0x6C, 0x6F])  // "héllo" in Latin-1
        #expect(RawTextDecoder.decode(data, contentType: "text/plain; charset=\"ISO-8859-1\"") == "héllo")
    }

    @Test func latin1LabelMeansWindows1252() {
        // 0x93/0x94 are curly quotes in windows-1252 but C1 controls in strict Latin-1.
        let data = Data([0x93, 0x68, 0x69, 0x94])
        #expect(RawTextDecoder.decode(data, contentType: "text/plain; charset=iso-8859-1") == "\u{201C}hi\u{201D}")
    }

    @Test func fallsBackToWindows1252WhenNotUTF8() {
        let data = Data([0x93, 0x68, 0x69, 0x94, 0x80])
        #expect(RawTextDecoder.decode(data, contentType: nil) == "\u{201C}hi\u{201D}€")
    }

    @Test func invalidBytesInDeclaredUTF8BecomeReplacementCharacters() {
        let data = Data([0x61, 0xFF, 0x62])
        #expect(RawTextDecoder.decode(data, contentType: "text/plain; charset=utf-8") == "a\u{FFFD}b")
    }

    @Test func stripsUTF8ByteOrderMark() {
        let data = Data([0xEF, 0xBB, 0xBF]) + Data("abc".utf8)
        #expect(RawTextDecoder.decode(data, contentType: nil) == "abc")
    }

    @Test func byteOrderMarkWinsOverHeader() {
        let data = Data([0xFF, 0xFE]) + "hi".data(using: .utf16LittleEndian)!
        #expect(RawTextDecoder.decode(data, contentType: "text/plain; charset=utf-8") == "hi")
    }

    @Test func decodesUTF16BigEndian() {
        let data = Data([0xFE, 0xFF]) + "한".data(using: .utf16BigEndian)!
        #expect(RawTextDecoder.decode(data, contentType: nil) == "한")
    }

    @Test func keepsLineEndingsAndTabs() {
        let text = "a\r\n\tb\rc\n"
        #expect(RawTextDecoder.decode(Data(text.utf8), contentType: nil) == text)
    }

    @Test func parsesCharsetParameter() {
        #expect(RawTextDecoder.charset(from: "text/plain; charset=UTF-8") == "utf-8")
        #expect(RawTextDecoder.charset(from: "text/plain;format=flowed; Charset = 'utf-8'") == "utf-8")
        #expect(RawTextDecoder.charset(from: "text/plain") == nil)
        #expect(RawTextDecoder.charset(from: nil) == nil)
    }
}
