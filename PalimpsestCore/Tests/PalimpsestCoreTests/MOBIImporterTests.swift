import Testing
import Foundation
@testable import PalimpsestCore

@Test func decodesUncompressedTextRecord() throws {
    let bytes = SyntheticMOBI(
        name: "TestBook",
        author: nil,
        text: "Hello world. This is a synthetic MOBI used for round-trip testing."
    ).build()

    let book = try MOBIImporter().decode(bytes)

    #expect(book.title == "TestBook")
    #expect(book.author == "Unknown")
    #expect(book.segments.count == 1)
    #expect(book.segments[0].text.contains("Hello world"))
}

@Test func decodesAuthorFromEXTH() throws {
    let bytes = SyntheticMOBI(
        name: "Anothertest",
        author: "Test Author",
        text: "Body text."
    ).build()

    let book = try MOBIImporter().decode(bytes)

    #expect(book.author == "Test Author")
    #expect(book.segments[0].text.contains("Body text"))
}

@Test func rejectsDRMProtected() {
    var bytes = SyntheticMOBI(name: "Locked", author: nil, text: "x").build()
    // PalmDOC encryption field is at offset (recordTableEnd + 12)..<+14.
    // Record table is 78-bytes header + 2 entries × 8 bytes = 94 bytes,
    // so record 0 starts at offset 94 and encryption is at 94 + 12.
    bytes[94 + 12] = 0
    bytes[94 + 13] = 2 // any nonzero encryption flag

    #expect(throws: ImporterError.self) {
        _ = try MOBIImporter().decode(bytes)
    }
}

@Test func palmDOCInflateRoundTripsBackReference() {
    // "abcabc" — last 3 bytes can be encoded as a length-3 back-reference
    // pointing 3 bytes back. We feed the encoded form directly so the
    // inflater is the unit under test, not the encoder.
    var encoded = Data()
    encoded.append(contentsOf: [UInt8]("abc".utf8)) // three literal ASCII
    // Back-reference: top 2 bits "10", 11-bit distance = 3, 3-bit length-3 = 0
    // pair = (10 << 14) | (3 << 3) | 0 = 0x8018
    encoded.append(0x80)
    encoded.append(0x18)

    let out = MOBITextReader.palmdocInflate(encoded)
    #expect(out == Data("abcabc".utf8))
}

// MARK: - Synthetic MOBI builder

private struct SyntheticMOBI {
    let name: String
    let author: String?
    let text: String

    func build() -> Data {
        let textBytes = Data(text.utf8)
        let rec0 = buildRec0(textLength: textBytes.count)
        let pdbHeaderSize = 78
        let recordEntrySize = 8
        let recordCount = 2

        // Offsets of record bodies.
        let tableEnd = pdbHeaderSize + recordCount * recordEntrySize
        let rec0Offset = tableEnd
        let rec1Offset = rec0Offset + rec0.count

        var out = Data(count: pdbHeaderSize)
        // Name field (32 bytes, NUL-padded).
        let nameData = Data(name.utf8).prefix(31)
        for (i, b) in nameData.enumerated() { out[i] = b }
        // Type = "BOOK" at offset 60.
        for (i, b) in "BOOK".utf8.enumerated() { out[60 + i] = b }
        // Creator = "MOBI" at offset 64.
        for (i, b) in "MOBI".utf8.enumerated() { out[64 + i] = b }
        // recordCount (uint16 BE) at offset 76.
        writeUInt16BE(UInt16(recordCount), into: &out, at: 76)

        // Record table.
        appendUInt32BE(UInt32(rec0Offset), to: &out)
        appendUInt16BE(0, to: &out) // attrs+uniqueID (4 bytes total, 0 is fine)
        appendUInt16BE(0, to: &out)
        appendUInt32BE(UInt32(rec1Offset), to: &out)
        appendUInt16BE(0, to: &out)
        appendUInt16BE(0, to: &out)

        out.append(rec0)
        out.append(textBytes)
        return out
    }

    private func buildRec0(textLength: Int) -> Data {
        // Decide whether to attach an EXTH block.
        let exthBytes: Data = author.map(makeEXTH) ?? Data()
        let mobiHeaderBodyLength = 224 // tunable; must cover all referenced fields
        let mobiHeaderLength = mobiHeaderBodyLength // value stored at offset 20

        var rec0 = Data()
        // PalmDOC header (16 bytes). compression=1 (no compression).
        appendUInt16BE(1, to: &rec0)
        appendUInt16BE(0, to: &rec0)
        appendUInt32BE(UInt32(textLength), to: &rec0)
        appendUInt16BE(1, to: &rec0) // text record count
        appendUInt16BE(4096, to: &rec0)
        appendUInt16BE(0, to: &rec0) // encryption
        appendUInt16BE(0, to: &rec0)

        // MOBI header. 16 bytes consumed; absolute offsets are from rec0[0].
        // Pad to offset 16, write magic, then build out by index.
        var mobi = Data(count: mobiHeaderBodyLength)
        // "MOBI" magic at offset 0 of this block (= offset 16 of rec0).
        for (i, b) in "MOBI".utf8.enumerated() { mobi[i] = b }
        writeUInt32BE(UInt32(mobiHeaderLength), into: &mobi, at: 4)   // headerLength (abs 20)
        writeUInt32BE(2, into: &mobi, at: 8)                          // mobi type (abs 24)
        writeUInt32BE(65001, into: &mobi, at: 12)                     // text encoding (abs 28)
        writeUInt32BE(2, into: &mobi, at: 64)                         // firstNonBookIndex (abs 80)
        // fullNameOffset / fullNameLength = 0 (skip — title comes from PDB name).
        writeUInt32BE(0, into: &mobi, at: 92)                         // firstImageRecord (abs 108)
        let exthFlags: UInt32 = exthBytes.isEmpty ? 0 : 0x40
        writeUInt32BE(exthFlags, into: &mobi, at: 112)                // exthFlags (abs 128)
        // extraDataFlags at abs 242 = mobi offset 226 (uint16). We left it
        // zero by construction.

        rec0.append(mobi)
        rec0.append(exthBytes)
        return rec0
    }

    private func makeEXTH(author: String) -> Data {
        let authorBytes = Data(author.utf8)
        let recordSize = 8 + authorBytes.count // type(4) + len(4) + payload
        let totalLength = 12 + recordSize       // "EXTH"(4) + headerLen(4) + count(4) + records

        var out = Data()
        for b in "EXTH".utf8 { out.append(b) }
        appendUInt32BE(UInt32(totalLength), to: &out) // headerLength includes magic
        appendUInt32BE(1, to: &out)                   // record count
        appendUInt32BE(100, to: &out)                 // type 100 = author
        appendUInt32BE(UInt32(recordSize), to: &out)  // record length
        out.append(authorBytes)
        return out
    }
}

private func appendUInt16BE(_ v: UInt16, to data: inout Data) {
    data.append(UInt8((v >> 8) & 0xFF))
    data.append(UInt8(v & 0xFF))
}

private func appendUInt32BE(_ v: UInt32, to data: inout Data) {
    data.append(UInt8((v >> 24) & 0xFF))
    data.append(UInt8((v >> 16) & 0xFF))
    data.append(UInt8((v >> 8) & 0xFF))
    data.append(UInt8(v & 0xFF))
}

private func writeUInt16BE(_ v: UInt16, into data: inout Data, at offset: Int) {
    data[offset] = UInt8((v >> 8) & 0xFF)
    data[offset + 1] = UInt8(v & 0xFF)
}

private func writeUInt32BE(_ v: UInt32, into data: inout Data, at offset: Int) {
    data[offset] = UInt8((v >> 24) & 0xFF)
    data[offset + 1] = UInt8((v >> 16) & 0xFF)
    data[offset + 2] = UInt8((v >> 8) & 0xFF)
    data[offset + 3] = UInt8(v & 0xFF)
}
