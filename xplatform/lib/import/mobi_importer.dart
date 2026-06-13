import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../alignment/alignment_types.dart';
import 'ebook_importer.dart';

// References:
//   - https://wiki.mobileread.com/wiki/MOBI
//   - https://wiki.mobileread.com/wiki/PDB
// Only the MOBI 6 / PalmDOC subset is implemented; KF8 (.azw3) and
// HUFF/CDIC throw rather than silently producing garbage.
class MOBIImporter implements EBookImporter {
  const MOBIImporter();

  @override
  Future<ImportedBook> importBook(File file) async =>
      _decode(await file.readAsBytes());

  ImportedBook _decode(Uint8List bytes) {
    final db = _PalmDB.parse(bytes);
    if (db.type != 'BOOK' || db.creator != 'MOBI') {
      throw ImporterError(
          'Not a MOBI file (PDB type="${db.type}", creator="${db.creator}").');
    }
    if (db.recordCount == 0) {
      throw const ImporterError('MOBI file has no records.');
    }

    final rec0 = db.recordBytes(0);
    final pdoc = _PalmDOCHeader.parse(rec0);
    if (pdoc.encryption != 0) {
      throw const ImporterError('DRM-protected MOBI; cannot import.');
    }
    final mobi = _MOBIHeader.parse(rec0);
    if (pdoc.compression == _Compression.huffCdic) {
      throw const ImporterError(
          'HUFF/CDIC compression unsupported. Convert to EPUB with Calibre.');
    }
    if (mobi.isKF8) {
      throw const ImporterError(
          '.azw3 / KF8 unsupported. Convert to EPUB with Calibre.');
    }

    final html = _readBookText(db, pdoc, mobi);
    final exth = _EXTHData.parse(rec0, mobi);
    final title =
        (exth.updatedTitle ?? _readFullName(rec0, mobi) ?? db.name).trim();
    final cover = _findCover(db, mobi, exth);

    return ImportedBook(
      title: title.isEmpty ? db.name : title,
      author: exth.author ?? 'Unknown',
      coverImageData: cover,
      segments: _splitOnHeadings(html),
    );
  }
}

String _readBookText(_PalmDB db, _PalmDOCHeader pdoc, _MOBIHeader mobi) {
  final lastText = mobi.firstNonBookIndex > 1
      ? mobi.firstNonBookIndex - 1
      : pdoc.recordCount;
  final buf = BytesBuilder();
  for (var i = 1; i <= lastText && i < db.recordCount; i++) {
    final raw = _stripTrailers(db.recordBytes(i), mobi.extraDataFlags);
    buf.add(pdoc.compression == _Compression.palmDoc
        ? _palmdocInflate(raw)
        : raw);
  }
  return _decodeBytes(buf.toBytes(), mobi.textEncoding);
}

Uint8List? _findCover(_PalmDB db, _MOBIHeader mobi, _EXTHData exth) {
  final fromExth =
      exth.coverIndex != null ? _imageAt(db, mobi, exth.coverIndex!) : null;
  return fromExth ?? _firstImage(db, mobi);
}

abstract class _Compression {
  static const palmDoc = 2;
  static const huffCdic = 17480;
}

String _decodeBytes(Uint8List bytes, int encoding) =>
    encoding == 65001 // UTF-8; otherwise the only seen value is 1252 (cp1252).
        ? utf8.decode(bytes, allowMalformed: true)
        : latin1.decode(bytes);

class _PalmDB {
  _PalmDB._(
      this.name, this.type, this.creator, this.recordOffsets, this.bytes);

  final String name;
  final String type;
  final String creator;
  final List<int> recordOffsets;
  final Uint8List bytes;

  int get recordCount => recordOffsets.length;

  static _PalmDB parse(Uint8List bytes) {
    if (bytes.length < _Pdb.headerSize) {
      throw const ImporterError('File too short to be a PalmDB.');
    }
    final bd = ByteData.sublistView(bytes);
    final count = bd.getUint16(_Pdb.recordCount, Endian.big);
    if (_Pdb.headerSize + count * _Pdb.recordEntrySize > bytes.length) {
      throw const ImporterError('PalmDB record table truncated.');
    }
    final offsets = [
      for (var i = 0; i < count; i++)
        bd.getUint32(_Pdb.headerSize + i * _Pdb.recordEntrySize, Endian.big),
    ];
    return _PalmDB._(
      _readCString(bytes, _Pdb.name, _Pdb.nameLength),
      latin1.decode(bytes.sublist(_Pdb.type, _Pdb.type + 4)),
      latin1.decode(bytes.sublist(_Pdb.creator, _Pdb.creator + 4)),
      offsets,
      bytes,
    );
  }

  Uint8List recordBytes(int idx) {
    final start = recordOffsets[idx];
    final end =
        idx + 1 < recordOffsets.length ? recordOffsets[idx + 1] : bytes.length;
    return bytes.sublist(start, end);
  }
}

abstract class _Pdb {
  static const headerSize = 78;
  static const recordEntrySize = 8;
  static const name = 0;
  static const nameLength = 32;
  static const type = 60;
  static const creator = 64;
  static const recordCount = 76;
}

String _readCString(Uint8List bytes, int offset, int maxLen) {
  var stop = offset + maxLen;
  for (var i = offset; i < offset + maxLen; i++) {
    if (bytes[i] == 0) {
      stop = i;
      break;
    }
  }
  return latin1.decode(bytes.sublist(offset, stop));
}

class _PalmDOCHeader {
  _PalmDOCHeader(this.compression, this.recordCount, this.encryption);

  final int compression;
  final int recordCount;
  final int encryption;

  static _PalmDOCHeader parse(Uint8List rec0) {
    if (rec0.length < 16) {
      throw const ImporterError('Record 0 too short.');
    }
    final bd = ByteData.sublistView(rec0);
    return _PalmDOCHeader(
      bd.getUint16(0, Endian.big),
      bd.getUint16(8, Endian.big),
      bd.getUint16(12, Endian.big),
    );
  }
}

class _MOBIHeader {
  _MOBIHeader({
    required this.headerLength,
    required this.textEncoding,
    required this.firstNonBookIndex,
    required this.fullNameOffset,
    required this.fullNameLength,
    required this.firstImageRecord,
    required this.exthFlags,
    required this.extraDataFlags,
    required this.isKF8,
  });

  final int headerLength;
  final int textEncoding;
  final int firstNonBookIndex;
  final int fullNameOffset;
  final int fullNameLength;
  final int firstImageRecord;
  final int exthFlags;
  final int extraDataFlags;
  final bool isKF8;

  bool get hasEXTH => (exthFlags & 0x40) != 0;

  static _MOBIHeader parse(Uint8List rec0) {
    if (rec0.length < _Mobi.minLength ||
        latin1.decode(rec0.sublist(_Mobi.magic, _Mobi.magic + 4)) != 'MOBI') {
      throw const ImporterError('MOBI header not found in record 0.');
    }
    final bd = ByteData.sublistView(rec0);
    int u32(int o) => o + 4 <= rec0.length ? bd.getUint32(o, Endian.big) : 0;
    final mobiType = u32(_Mobi.mobiType);
    final headerLength = u32(_Mobi.headerLength);
    return _MOBIHeader(
      headerLength: headerLength,
      textEncoding: u32(_Mobi.textEncoding),
      firstNonBookIndex: u32(_Mobi.firstNonBookIndex),
      fullNameOffset: u32(_Mobi.fullNameOffset),
      fullNameLength: u32(_Mobi.fullNameLength),
      firstImageRecord: u32(_Mobi.firstImageRecord),
      exthFlags: u32(_Mobi.exthFlags),
      // extraDataFlags sits at MOBI-header offset 226 (abs 242) and only
      // exists in headers >= 228 bytes (the 0xE4 check Calibre/libmobi
      // use). Guarding on rec0.length alone is wrong: with a shorter
      // header plus an EXTH block, abs 242 lands inside EXTH and reads
      // its bytes as trailer flags — which then strip every text record
      // down to nothing.
      extraDataFlags:
          headerLength >= 228 && rec0.length >= _Mobi.extraDataFlags + 2
              ? bd.getUint16(_Mobi.extraDataFlags, Endian.big)
              : 0,
      // 248 / 257 are the Mobipocket type values for KF8-formatted files.
      isKF8: mobiType == 248 || mobiType == 257,
    );
  }
}

// Offsets are absolute inside record 0 (i.e. they include the 16-byte
// PalmDOC header preceding the MOBI magic).
abstract class _Mobi {
  static const minLength = 24;
  static const magic = 16;
  static const headerLength = 20;
  static const mobiType = 24;
  static const textEncoding = 28;
  static const firstNonBookIndex = 80;
  static const fullNameOffset = 84;
  static const fullNameLength = 88;
  static const firstImageRecord = 108;
  static const exthFlags = 128;
  static const extraDataFlags = 242;
}

String? _readFullName(Uint8List rec0, _MOBIHeader mobi) {
  final start = mobi.fullNameOffset;
  final len = mobi.fullNameLength;
  if (start == 0 || len == 0 || start + len > rec0.length) return null;
  return _decodeBytes(rec0.sublist(start, start + len), mobi.textEncoding);
}

class _EXTHData {
  _EXTHData({this.author, this.updatedTitle, this.coverIndex});
  final String? author;
  final String? updatedTitle;
  final int? coverIndex;

  static _EXTHData parse(Uint8List rec0, _MOBIHeader mobi) {
    if (!mobi.hasEXTH) return _EXTHData();
    final base = 16 + mobi.headerLength;
    if (base + 12 > rec0.length) return _EXTHData();
    if (latin1.decode(rec0.sublist(base, base + 4)) != 'EXTH') {
      return _EXTHData();
    }

    final bd = ByteData.sublistView(rec0);
    final count = bd.getUint32(base + 8, Endian.big);
    var cursor = base + 12;
    String? author;
    String? updatedTitle;
    int? coverIndex;

    for (var i = 0; i < count; i++) {
      if (cursor + 8 > rec0.length) break;
      final type = bd.getUint32(cursor, Endian.big);
      final length = bd.getUint32(cursor + 4, Endian.big);
      if (length < 8 || cursor + length > rec0.length) break;
      final data = rec0.sublist(cursor + 8, cursor + length);
      switch (type) {
        case 100:
          author ??= _decodeBytes(data, mobi.textEncoding).trim();
        case 201:
          if (data.length >= 4) {
            coverIndex ??= ByteData.sublistView(data).getUint32(0, Endian.big);
          }
        case 503:
          updatedTitle ??= _decodeBytes(data, mobi.textEncoding).trim();
      }
      cursor += length;
    }
    return _EXTHData(
      author: author,
      updatedTitle: updatedTitle,
      coverIndex: coverIndex,
    );
  }
}

// Each MOBI text record may carry trailing data (multibyte-char overflow,
// index records, ...) appended after the compressed payload. Each bit
// of extraDataFlags above bit 0 marks a variable-length trailer to peel
// off, and bit 0 marks 1-3 multibyte-char overflow bytes whose count is
// encoded in the low 2 bits of the final byte. Get this wrong and
// PalmDOC decompression desynchronises mid-record.
Uint8List _stripTrailers(Uint8List record, int flags) {
  var end = record.length;
  for (var bit = 0x8000; bit > 1; bit >>>= 1) {
    if ((flags & bit) == 0) continue;
    end = _stripVlen(record, end);
    if (end <= 0) return Uint8List(0);
  }
  if ((flags & 1) != 0 && end > 0) {
    end -= (record[end - 1] & 0x3) + 1;
    if (end < 0) end = 0;
  }
  return record.sublist(0, end);
}

int _stripVlen(Uint8List record, int end) {
  var len = 0;
  for (var i = 0; i < 4 && end - 1 - i >= 0; i++) {
    final b = record[end - 1 - i];
    len = (len << 7) | (b & 0x7F);
    if ((b & 0x80) != 0) break;
  }
  return (end - len).clamp(0, end);
}

// PalmDOC compression: a byte-oriented LZ77 variant. Token byte meanings:
//   0x00         literal NUL
//   0x01..0x08   N literal bytes follow
//   0x09..0x7F   literal ASCII byte
//   0x80..0xBF   back-reference: top 2 bits "10", remaining 14 bits hold
//                an 11-bit distance and a 3-bit length-3 in the second byte
//   0xC0..0xFF   ' ' + (b XOR 0x80)
Uint8List _palmdocInflate(Uint8List input) {
  final out = BytesBuilder();
  var i = 0;
  while (i < input.length) {
    final b = input[i++];
    if (b == 0) {
      out.addByte(0);
    } else if (b <= 0x08) {
      final n = b;
      if (i + n > input.length) break;
      for (var k = 0; k < n; k++) {
        out.addByte(input[i + k]);
      }
      i += n;
    } else if (b <= 0x7F) {
      out.addByte(b);
    } else if (b <= 0xBF) {
      if (i >= input.length) break;
      final pair = ((b << 8) | input[i++]) & 0x3FFF;
      final distance = pair >> 3;
      final length = (pair & 0x7) + 3;
      final cur = out.toBytes();
      if (distance == 0 || distance > cur.length) continue;
      for (var k = 0; k < length; k++) {
        out.addByte(out.toBytes()[cur.length + k - distance]);
      }
    } else {
      out.addByte(0x20);
      out.addByte(b ^ 0x80);
    }
  }
  return out.toBytes();
}

Uint8List? _imageAt(_PalmDB db, _MOBIHeader mobi, int coverIndex) {
  if (mobi.firstImageRecord == 0) return null;
  final rec = mobi.firstImageRecord + coverIndex;
  if (rec < 0 || rec >= db.recordCount) return null;
  final bytes = db.recordBytes(rec);
  return _isImage(bytes) ? bytes : null;
}

Uint8List? _firstImage(_PalmDB db, _MOBIHeader mobi) {
  if (mobi.firstImageRecord == 0) return null;
  final stop = (mobi.firstImageRecord + 8).clamp(0, db.recordCount).toInt();
  for (var i = mobi.firstImageRecord; i < stop; i++) {
    final bytes = db.recordBytes(i);
    if (_isImage(bytes)) return bytes;
  }
  return null;
}

bool _isImage(Uint8List b) {
  if (b.length < 4) return false;
  if (b[0] == 0xFF && b[1] == 0xD8) return true; // JPEG
  if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
    return true; // PNG
  }
  if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) return true; // GIF
  return false;
}

// MOBI 6 has no TOC-anchor table like EPUB, so we lean on the publisher's
// own h1/h2 markup. If a book uses no headings we keep it as one segment
// rather than guessing.
final RegExp _headingRe =
    RegExp(r'<h([12])\b[^>]*>([\s\S]*?)</h\1>', caseSensitive: false);

List<TextSegment> _splitOnHeadings(String html) {
  final matches = _headingRe.allMatches(html).toList();
  if (matches.isEmpty) {
    final plain = stripHTML(html);
    return plain.isEmpty
        ? const []
        : [TextSegment(id: 'mobi-1', title: null, text: plain)];
  }

  final out = <TextSegment>[];
  if (matches.first.start > 0) {
    final pre = stripHTML(html.substring(0, matches.first.start));
    if (pre.length >= 200) {
      out.add(TextSegment(id: 'mobi-pre', title: null, text: pre));
    }
  }
  for (var i = 0; i < matches.length; i++) {
    final m = matches[i];
    final next = i + 1 < matches.length ? matches[i + 1].start : html.length;
    final plain = stripHTML(html.substring(m.start, next));
    if (plain.isEmpty) continue;
    final title = stripHTML(m.group(2) ?? '').trim();
    out.add(TextSegment(
      id: 'mobi-${i + 1}',
      title: title.isEmpty ? null : title,
      text: plain,
    ));
  }
  return out;
}
