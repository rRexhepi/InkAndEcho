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

    /// Numeric entities decode to their characters — they used to be
    /// stripped, so "don&#8217;t" became "dont" and every contraction fell
    /// out of the aligner's anchor matching.
    @Test func decodesNumericEntities() {
        #expect(stripHTML("<p>don&#8217;t</p>") == "don\u{2019}t")
        #expect(stripHTML("<p>don&#x2019;t</p>") == "don\u{2019}t")
        #expect(stripHTML("<p>A&#8212;B</p>") == "A\u{2014}B")
        // After the named table, so a double-escaped entity stays literal.
        #expect(stripHTML("<p>&#38;amp;</p>") == "&amp;")
        // Invalid references stay as-is instead of corrupting the text.
        #expect(stripHTML("<p>bad &#xD800; ref</p>") == "bad &#xD800; ref")
        #expect(stripHTML("<p>huge &#99999999999; ref</p>") == "huge &#99999999999; ref")
    }
}
