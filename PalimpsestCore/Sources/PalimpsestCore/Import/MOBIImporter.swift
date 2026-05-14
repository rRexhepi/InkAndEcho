import Foundation

// Pure-Swift MOBI 6 / PalmDOC importer. Mirrors the in-tree Dart parser at
// xplatform/lib/import/mobi_importer.dart so the iOS / macOS surface gets
// the same coverage. App Store-safe: no subprocess, no GPL dependency.
//
// References:
//   - https://wiki.mobileread.com/wiki/MOBI
//   - https://wiki.mobileread.com/wiki/PDB
//
// KF8 (.azw3) and HUFF/CDIC compressed payloads throw rather than emitting
// garbage; the surface UI prompts the user to convert with Calibre on a
// machine that has it.

public struct MOBIImporter: EBookImporter {
    public init() {}

    public func importBook(from url: URL) async throws -> ImportedBook {
        let data = try Data(contentsOf: url)
        return try decode(data)
    }

    func decode(_ data: Data) throws -> ImportedBook {
        let db = try PalmDB.parse(data)
        guard db.type == "BOOK", db.creator == "MOBI" else {
            throw ImporterError.malformedMOBI(
                #"Not a MOBI file (PDB type="\#(db.type)", creator="\#(db.creator)")."#
            )
        }
        guard db.recordCount > 0 else {
            throw ImporterError.malformedMOBI("MOBI file has no records.")
        }

        let rec0 = db.recordBytes(0)
        let pdoc = try PalmDOCHeader.parse(rec0)
        if pdoc.encryption != 0 {
            throw ImporterError.drmProtected
        }
        let mobi = try MOBIHeader.parse(rec0)
        if pdoc.compression == MOBIConstants.huffCdicCompression {
            throw ImporterError.malformedMOBI(
                "HUFF/CDIC compression unsupported. Convert to EPUB with Calibre."
            )
        }
        if mobi.isKF8 {
            throw ImporterError.unsupportedKF8
        }

        let html = MOBITextReader.read(db: db, pdoc: pdoc, mobi: mobi)
        let exth = EXTHData.parse(rec0: rec0, mobi: mobi)
        let candidate = (exth.updatedTitle ?? MOBITextReader.readFullName(rec0: rec0, mobi: mobi) ?? db.name)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = candidate.isEmpty ? db.name : candidate
        let cover = MOBICover.find(db: db, mobi: mobi, exth: exth)

        return ImportedBook(
            title: title,
            author: exth.author ?? "Unknown",
            coverImageData: cover,
            segments: MOBIChapterSplitter.split(html: html),
            totalPages: 0
        )
    }
}

// MARK: - Constants

enum MOBIConstants {
    static let palmDocCompression = 2
    static let huffCdicCompression = 17480
}

// MARK: - PalmDB

struct PalmDB {
    let name: String
    let type: String
    let creator: String
    let recordOffsets: [Int]
    let bytes: Data

    var recordCount: Int { recordOffsets.count }

    static func parse(_ bytes: Data) throws -> PalmDB {
        guard bytes.count >= MOBIBytes.pdbHeaderSize else {
            throw ImporterError.malformedMOBI("File too short to be a PalmDB.")
        }
        let count = Int(MOBIBytes.readUInt16BE(bytes, at: MOBIBytes.pdbRecordCount))
        guard MOBIBytes.pdbHeaderSize + count * MOBIBytes.pdbRecordEntrySize <= bytes.count else {
            throw ImporterError.malformedMOBI("PalmDB record table truncated.")
        }
        var offsets: [Int] = []
        offsets.reserveCapacity(count)
        for i in 0..<count {
            let off = Int(MOBIBytes.readUInt32BE(
                bytes,
                at: MOBIBytes.pdbHeaderSize + i * MOBIBytes.pdbRecordEntrySize
            ))
            offsets.append(off)
        }
        return PalmDB(
            name: MOBIBytes.readCString(bytes, offset: MOBIBytes.pdbName, maxLen: MOBIBytes.pdbNameLength),
            type: MOBIBytes.latin1(bytes, range: MOBIBytes.pdbType..<(MOBIBytes.pdbType + 4)),
            creator: MOBIBytes.latin1(bytes, range: MOBIBytes.pdbCreator..<(MOBIBytes.pdbCreator + 4)),
            recordOffsets: offsets,
            bytes: bytes
        )
    }

    func recordBytes(_ idx: Int) -> Data {
        let start = recordOffsets[idx]
        let end = idx + 1 < recordOffsets.count ? recordOffsets[idx + 1] : bytes.count
        return bytes.subdata(in: start..<end)
    }
}

// MARK: - PalmDOC + MOBI headers

struct PalmDOCHeader {
    let compression: Int
    let recordCount: Int
    let encryption: Int

    static func parse(_ rec0: Data) throws -> PalmDOCHeader {
        guard rec0.count >= 16 else {
            throw ImporterError.malformedMOBI("Record 0 too short.")
        }
        return PalmDOCHeader(
            compression: Int(MOBIBytes.readUInt16BE(rec0, at: 0)),
            recordCount: Int(MOBIBytes.readUInt16BE(rec0, at: 8)),
            encryption: Int(MOBIBytes.readUInt16BE(rec0, at: 12))
        )
    }
}

struct MOBIHeader {
    let headerLength: Int
    let textEncoding: Int
    let firstNonBookIndex: Int
    let fullNameOffset: Int
    let fullNameLength: Int
    let firstImageRecord: Int
    let exthFlags: Int
    let extraDataFlags: Int
    let isKF8: Bool

    var hasEXTH: Bool { (exthFlags & 0x40) != 0 }

    static func parse(_ rec0: Data) throws -> MOBIHeader {
        guard rec0.count >= MOBIBytes.mobiMinLength,
              MOBIBytes.latin1(rec0, range: MOBIBytes.mobiMagic..<(MOBIBytes.mobiMagic + 4)) == "MOBI"
        else {
            throw ImporterError.malformedMOBI("MOBI header not found in record 0.")
        }
        func u32(_ o: Int) -> Int {
            o + 4 <= rec0.count ? Int(MOBIBytes.readUInt32BE(rec0, at: o)) : 0
        }
        let mobiType = u32(MOBIBytes.mobiType)
        let extra = rec0.count >= MOBIBytes.mobiExtraDataFlags + 2
            ? Int(MOBIBytes.readUInt16BE(rec0, at: MOBIBytes.mobiExtraDataFlags))
            : 0
        return MOBIHeader(
            headerLength: u32(MOBIBytes.mobiHeaderLength),
            textEncoding: u32(MOBIBytes.mobiTextEncoding),
            firstNonBookIndex: u32(MOBIBytes.mobiFirstNonBookIndex),
            fullNameOffset: u32(MOBIBytes.mobiFullNameOffset),
            fullNameLength: u32(MOBIBytes.mobiFullNameLength),
            firstImageRecord: u32(MOBIBytes.mobiFirstImageRecord),
            exthFlags: u32(MOBIBytes.mobiExthFlags),
            extraDataFlags: extra,
            // 248 / 257 are the Mobipocket type values for KF8-formatted files.
            isKF8: mobiType == 248 || mobiType == 257
        )
    }
}

// MARK: - EXTH metadata

struct EXTHData {
    let author: String?
    let updatedTitle: String?
    let coverIndex: Int?

    static func parse(rec0: Data, mobi: MOBIHeader) -> EXTHData {
        guard mobi.hasEXTH else { return EXTHData(author: nil, updatedTitle: nil, coverIndex: nil) }
        let base = 16 + mobi.headerLength
        guard base + 12 <= rec0.count,
              MOBIBytes.latin1(rec0, range: base..<(base + 4)) == "EXTH"
        else {
            return EXTHData(author: nil, updatedTitle: nil, coverIndex: nil)
        }

        let count = Int(MOBIBytes.readUInt32BE(rec0, at: base + 8))
        var cursor = base + 12
        var author: String?
        var updatedTitle: String?
        var coverIndex: Int?

        for _ in 0..<count {
            guard cursor + 8 <= rec0.count else { break }
            let type = Int(MOBIBytes.readUInt32BE(rec0, at: cursor))
            let length = Int(MOBIBytes.readUInt32BE(rec0, at: cursor + 4))
            guard length >= 8, cursor + length <= rec0.count else { break }
            let data = rec0.subdata(in: (cursor + 8)..<(cursor + length))
            switch type {
            case 100:
                if author == nil {
                    author = MOBIBytes.decode(data, encoding: mobi.textEncoding)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            case 201:
                if coverIndex == nil, data.count >= 4 {
                    coverIndex = Int(MOBIBytes.readUInt32BE(data, at: 0))
                }
            case 503:
                if updatedTitle == nil {
                    updatedTitle = MOBIBytes.decode(data, encoding: mobi.textEncoding)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            default:
                break
            }
            cursor += length
        }
        return EXTHData(author: author, updatedTitle: updatedTitle, coverIndex: coverIndex)
    }
}

// MARK: - Text assembly + PalmDOC decompression

enum MOBITextReader {
    static func read(db: PalmDB, pdoc: PalmDOCHeader, mobi: MOBIHeader) -> String {
        let lastText = mobi.firstNonBookIndex > 1 ? mobi.firstNonBookIndex - 1 : pdoc.recordCount
        var buf = Data()
        let upper = min(lastText, db.recordCount - 1)
        if upper >= 1 {
            for i in 1...upper {
                let raw = stripTrailers(db.recordBytes(i), flags: mobi.extraDataFlags)
                if pdoc.compression == MOBIConstants.palmDocCompression {
                    buf.append(palmdocInflate(raw))
                } else {
                    buf.append(raw)
                }
            }
        }
        return MOBIBytes.decode(buf, encoding: mobi.textEncoding)
    }

    static func readFullName(rec0: Data, mobi: MOBIHeader) -> String? {
        let start = mobi.fullNameOffset
        let len = mobi.fullNameLength
        guard start > 0, len > 0, start + len <= rec0.count else { return nil }
        return MOBIBytes.decode(rec0.subdata(in: start..<(start + len)), encoding: mobi.textEncoding)
    }

    // Each MOBI text record may carry trailing data (multibyte-char overflow,
    // index records, ...) appended after the compressed payload. Each bit of
    // extraDataFlags above bit 0 marks a variable-length trailer to peel off,
    // and bit 0 marks 1-3 multibyte-char overflow bytes whose count is encoded
    // in the low 2 bits of the final byte. Get this wrong and PalmDOC
    // decompression desynchronises mid-record.
    static func stripTrailers(_ record: Data, flags: Int) -> Data {
        var end = record.count
        var bit = 0x8000
        while bit > 1 {
            defer { bit >>= 1 }
            if flags & bit == 0 { continue }
            end = stripVlen(record, end: end)
            if end <= 0 { return Data() }
        }
        if flags & 1 != 0, end > 0 {
            let n = Int(record[end - 1] & 0x3) + 1
            end -= n
            if end < 0 { end = 0 }
        }
        return record.subdata(in: 0..<end)
    }

    static func stripVlen(_ record: Data, end: Int) -> Int {
        var len = 0
        var i = 0
        while i < 4, end - 1 - i >= 0 {
            let b = Int(record[end - 1 - i])
            len = (len << 7) | (b & 0x7F)
            if b & 0x80 != 0 { break }
            i += 1
        }
        let newEnd = end - len
        return newEnd < 0 ? 0 : (newEnd > end ? end : newEnd)
    }

    // PalmDOC compression: a byte-oriented LZ77 variant. Token byte meanings:
    //   0x00         literal NUL
    //   0x01..0x08   N literal bytes follow
    //   0x09..0x7F   literal ASCII byte
    //   0x80..0xBF   back-reference: top 2 bits "10", remaining 14 bits hold
    //                an 11-bit distance and a 3-bit length-3 in the second byte
    //   0xC0..0xFF   ' ' + (b XOR 0x80)
    static func palmdocInflate(_ input: Data) -> Data {
        var out = Data()
        var i = 0
        while i < input.count {
            let b = input[i]
            i += 1
            if b == 0 {
                out.append(0)
            } else if b <= 0x08 {
                let n = Int(b)
                if i + n > input.count { break }
                out.append(input.subdata(in: i..<(i + n)))
                i += n
            } else if b <= 0x7F {
                out.append(b)
            } else if b <= 0xBF {
                if i >= input.count { break }
                let pair = ((Int(b) << 8) | Int(input[i])) & 0x3FFF
                i += 1
                let distance = pair >> 3
                let length = (pair & 0x7) + 3
                let cur = out.count
                if distance == 0 || distance > cur { continue }
                for k in 0..<length {
                    out.append(out[cur + k - distance])
                }
            } else {
                out.append(0x20)
                out.append(b ^ 0x80)
            }
        }
        return out
    }
}

// MARK: - Cover

enum MOBICover {
    static func find(db: PalmDB, mobi: MOBIHeader, exth: EXTHData) -> Data? {
        if let idx = exth.coverIndex, let bytes = imageAt(db: db, mobi: mobi, coverIndex: idx) {
            return bytes
        }
        return firstImage(db: db, mobi: mobi)
    }

    static func imageAt(db: PalmDB, mobi: MOBIHeader, coverIndex: Int) -> Data? {
        guard mobi.firstImageRecord > 0 else { return nil }
        let rec = mobi.firstImageRecord + coverIndex
        guard rec >= 0, rec < db.recordCount else { return nil }
        let bytes = db.recordBytes(rec)
        return isImage(bytes) ? bytes : nil
    }

    static func firstImage(db: PalmDB, mobi: MOBIHeader) -> Data? {
        guard mobi.firstImageRecord > 0 else { return nil }
        let stop = min(mobi.firstImageRecord + 8, db.recordCount)
        if stop <= mobi.firstImageRecord { return nil }
        for i in mobi.firstImageRecord..<stop {
            let bytes = db.recordBytes(i)
            if isImage(bytes) { return bytes }
        }
        return nil
    }

    static func isImage(_ b: Data) -> Bool {
        guard b.count >= 4 else { return false }
        if b[0] == 0xFF, b[1] == 0xD8 { return true } // JPEG
        if b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return true } // PNG
        if b[0] == 0x47, b[1] == 0x49, b[2] == 0x46 { return true } // GIF
        return false
    }
}

// MARK: - Chapter splitting

// MOBI 6 has no TOC-anchor table like EPUB, so we lean on the publisher's
// own h1/h2 markup. If a book uses no headings we keep it as one segment
// rather than guessing.
enum MOBIChapterSplitter {
    private static let headingRegex: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: "<h([12])\\b[^>]*>([\\s\\S]*?)</h\\1>",
            options: .caseInsensitive
        )
    }()

    static func split(html: String) -> [TextSegment] {
        let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = headingRegex.matches(in: html, range: nsRange)
        if matches.isEmpty {
            let plain = stripHTML(html)
            return plain.isEmpty
                ? []
                : [TextSegment(id: "mobi-1", title: nil, text: plain)]
        }

        var out: [TextSegment] = []
        if let firstRange = Range(matches[0].range, in: html), firstRange.lowerBound > html.startIndex {
            let pre = stripHTML(String(html[html.startIndex..<firstRange.lowerBound]))
            if pre.count >= 200 {
                out.append(TextSegment(id: "mobi-pre", title: nil, text: pre))
            }
        }
        for (i, m) in matches.enumerated() {
            guard let mRange = Range(m.range, in: html) else { continue }
            let endIdx = i + 1 < matches.count
                ? Range(matches[i + 1].range, in: html)?.lowerBound ?? html.endIndex
                : html.endIndex
            let plain = stripHTML(String(html[mRange.lowerBound..<endIdx]))
            if plain.isEmpty { continue }
            var title: String? = nil
            if m.numberOfRanges > 2, let titleRange = Range(m.range(at: 2), in: html) {
                let t = stripHTML(String(html[titleRange]))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                title = t.isEmpty ? nil : t
            }
            out.append(TextSegment(id: "mobi-\(i + 1)", title: title, text: plain))
        }
        return out
    }
}

// MARK: - Byte / string helpers

enum MOBIBytes {
    // PalmDB layout
    static let pdbHeaderSize = 78
    static let pdbRecordEntrySize = 8
    static let pdbName = 0
    static let pdbNameLength = 32
    static let pdbType = 60
    static let pdbCreator = 64
    static let pdbRecordCount = 76

    // MOBI header offsets (absolute inside record 0; include the 16-byte
    // PalmDOC header preceding the MOBI magic).
    static let mobiMinLength = 24
    static let mobiMagic = 16
    static let mobiHeaderLength = 20
    static let mobiType = 24
    static let mobiTextEncoding = 28
    static let mobiFirstNonBookIndex = 80
    static let mobiFullNameOffset = 84
    static let mobiFullNameLength = 88
    static let mobiFirstImageRecord = 108
    static let mobiExthFlags = 128
    static let mobiExtraDataFlags = 242

    static func readUInt16BE(_ data: Data, at offset: Int) -> UInt16 {
        let hi = UInt16(data[offset])
        let lo = UInt16(data[offset + 1])
        return (hi << 8) | lo
    }

    static func readUInt32BE(_ data: Data, at offset: Int) -> UInt32 {
        let b0 = UInt32(data[offset])
        let b1 = UInt32(data[offset + 1])
        let b2 = UInt32(data[offset + 2])
        let b3 = UInt32(data[offset + 3])
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }

    static func latin1(_ data: Data, range: Range<Int>) -> String {
        let slice = data.subdata(in: range)
        return String(data: slice, encoding: .isoLatin1) ?? ""
    }

    static func readCString(_ data: Data, offset: Int, maxLen: Int) -> String {
        var stop = offset + maxLen
        var i = offset
        while i < offset + maxLen, i < data.count {
            if data[i] == 0 { stop = i; break }
            i += 1
        }
        return latin1(data, range: offset..<stop)
    }

    static func decode(_ data: Data, encoding: Int) -> String {
        // 65001 = UTF-8; 1252 (and absent) = Windows-1252 / latin1 fallback.
        if encoding == 65001 {
            return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        }
        return String(data: data, encoding: .windowsCP1252)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
    }
}
