import Testing
@testable import InkAndEchoCore

@Suite("stripHTML")
struct StripHTMLTests {
    /// `<head>` content must vanish entirely — its `<title>` text used to
    /// survive tag-stripping and prepend itself to every chapter that
    /// titles its own xhtml file ("Chapter ThreeChapter Three").
    @Test func dropsHeadAndTitleText() {
        let html = """
        <?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml">\
        <head><title>Chapter Three</title><style>p { color: red }</style></head>\
        <body><h1>Chapter Three</h1><p>In the weeks that followed.</p></body></html>
        """
        let out = stripHTML(html)
        #expect(out == "Chapter Three\n\nIn the weeks that followed.")
    }

    @Test func keepsParagraphBreaksAndEntities() {
        let out = stripHTML("<body><p>One &amp; two.</p><p>Three.</p></body>")
        #expect(out == "One & two.\n\nThree.")
    }
}
