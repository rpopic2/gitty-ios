import Foundation
import Testing
@testable import gitty

struct WebPageDetectorTests {
    private let html = Data("<!DOCTYPE html>\n<html><body>hi</body></html>".utf8)

    @Test func htmlContentTypeIsAWebPage() {
        #expect(WebPageDetector.isWebPage(contentType: "text/html; charset=utf-8", data: Data("x".utf8)))
        #expect(WebPageDetector.isWebPage(contentType: "application/xhtml+xml", data: Data()))
    }

    @Test func htmlSourceServedAsTextIsNot() {
        // raw.githubusercontent.com serves .html files as text/plain.
        #expect(!WebPageDetector.isWebPage(contentType: "text/plain; charset=utf-8", data: html))
    }

    @Test func withoutContentTypeTheStartDecides() {
        #expect(WebPageDetector.isWebPage(contentType: nil, data: html))
        #expect(WebPageDetector.isWebPage(contentType: nil, data: Data("  \n<HTML lang=\"en\">".utf8)))
        #expect(!WebPageDetector.isWebPage(contentType: nil, data: Data("int main(void) {}".utf8)))
    }
}
