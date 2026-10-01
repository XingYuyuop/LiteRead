import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:literead/engine/parsers/epub_parser.dart'
    show BookParseException;
import 'package:literead/engine/parsers/mobi_parser.dart';

/// 构造最小可用 MOBI 文件（PDB 头 + MOBI header + EXTH + 文本记录 + 封面记录）
Uint8List buildMobi({
  required String html,
  String title = '测试之书',
  String author = '测试作者',
  List<int>? cover,
  int textEncoding = 65001,
  int compression = 1,
}) {
  final textBytes = utf8.encode(html);

  // ---- record 0：PalmDOC header + MOBI header + EXTH + fullName ----
  final r0 = BytesBuilder();

  // PalmDOC header (16B)
  r0.add(_u16b(compression));
  r0.add(_u16b(0)); // unused
  r0.add(_u32b(textBytes.length)); // textLength
  r0.add(_u16b(1)); // textRecordCount
  r0.add(_u16b(4096)); // recordSize
  r0.add(_u16b(0)); // encryption
  r0.add(_u16b(0)); // 14-15: 保留

  // MOBI header（magic 从 record0 偏移 16 开始，headerLength 从 magic 起算）
  const headerLength = 232;
  r0.add(utf8.encode('MOBI')); // 16
  r0.add(_u32b(headerLength)); // 20
  r0.add(_u32b(2)); // 24: mobiType
  r0.add(_u32b(textEncoding)); // 28: textEncoding
  r0.add(_u32b(1)); // 32: uniqueID
  r0.add(_u32b(6)); // 36: fileVersion
  r0.add(Uint8List(40)); // 40..79: 索引区
  r0.add(_u32b(0xFFFFFFFF)); // 80: firstNonBookIndex
  final fullNameOffsetPos = r0.length;
  r0.add(_u32b(0)); // 84: fullNameOffset（回填）
  final fullNameLengthPos = r0.length;
  r0.add(_u32b(0)); // 88: fullNameLength（回填）
  r0.add(_u32b(9)); // 92: locale
  r0.add(_u32b(0)); // 96: inputLanguage
  r0.add(_u32b(0)); // 100: outputLanguage
  r0.add(_u32b(6)); // 104: minVersion
  r0.add(_u32b(2)); // 108: firstImageIndex（rec2 为第一张图）
  r0.add(_u32b(0)); // 112: huffman offset
  r0.add(_u32b(0)); // 116: huffman count
  r0.add(_u32b(0)); // 120: huffman table offset
  r0.add(_u32b(0)); // 124: huffman table length
  r0.add(_u32b(0x40)); // 128: EXTH flags
  // 132 起：保留字段填 0，凑齐 16 + headerLength = 248 字节
  r0.add(Uint8List(16 + headerLength - r0.length));

  // EXTH
  Uint8List exthRecord(int type, List<int> data) {
    final b = BytesBuilder();
    b.add(_u32b(type));
    b.add(_u32b(8 + data.length));
    b.add(data);
    return b.toBytes();
  }

  final entries = <int, List<int>>{
    100: utf8.encode(author), // author
    503: utf8.encode(title), // updated title
    201: _u32b(0), // coverOffset（firstImageIndex + 0）
  };
  final exthBody = BytesBuilder();
  for (final e in entries.entries) {
    exthBody.add(exthRecord(e.key, e.value));
  }
  r0.add(utf8.encode('EXTH'));
  r0.add(_u32b(12 + exthBody.length));
  r0.add(_u32b(entries.length));
  r0.add(exthBody.toBytes());

  // fullName（紧跟 EXTH，偏移相对 record 0）
  final fullNameOffset = r0.length;
  final fullNameBytes = utf8.encode(title);
  r0.add(fullNameBytes);

  final r0Bytes = r0.toBytes();
  _patchU32(r0Bytes, fullNameOffsetPos, fullNameOffset);
  _patchU32(r0Bytes, fullNameLengthPos, fullNameBytes.length);

  // ---- record 1：文本 / record 2：封面 ----
  final rec1 = compression == 2 ? palmDocCompressNaive(textBytes) : textBytes;
  final rec2 = cover ?? Uint8List(0);

  // ---- PDB 头（78B）+ 记录表（8B/条） ----
  final head = BytesBuilder();
  head.add(Uint8List(32)); // 0-31: name
  head.add(_u16b(0)); // 32: attributes
  head.add(_u16b(0)); // 34: version
  head.add(_u32b(0)); // 36: creation
  head.add(_u32b(0)); // 40: modification
  head.add(_u32b(0)); // 44: backup
  head.add(_u32b(0)); // 48: modnum
  head.add(Uint8List(4)); // 52: appInfoID
  head.add(Uint8List(4)); // 56: sortInfoID
  head.add(utf8.encode('BOOK')); // 60: type
  head.add(utf8.encode('MOBI')); // 64: creator
  head.add(_u32b(0)); // 68: uniqueIDseed
  head.add(_u32b(0)); // 72: uniqueIDchain
  head.add(_u16b(3)); // 76: numRecords
  final off0 = 78 + 8 * 3;
  final off1 = off0 + r0Bytes.length;
  final off2 = off1 + rec1.length;
  head.add(_u32b(off0));
  head.add(Uint8List(4));
  head.add(_u32b(off1));
  head.add(Uint8List(4));
  head.add(_u32b(off2));
  head.add(Uint8List(4));

  final out = BytesBuilder();
  out.add(head.toBytes());
  out.add(r0Bytes);
  out.add(rec1);
  out.add(rec2);
  return out.toBytes();
}

List<int> _u16b(int v) => [(v >> 8) & 0xFF, v & 0xFF];
List<int> _u32b(int v) => [
  (v >> 24) & 0xFF,
  (v >> 16) & 0xFF,
  (v >> 8) & 0xFF,
  v & 0xFF,
];
void _patchU32(Uint8List b, int offset, int v) {
  b[offset] = (v >> 24) & 0xFF;
  b[offset + 1] = (v >> 16) & 0xFF;
  b[offset + 2] = (v >> 8) & 0xFF;
  b[offset + 3] = v & 0xFF;
}

/// 朴素 PalmDOC 压缩（仅字面量路径，用于验证解压往返）
Uint8List palmDocCompressNaive(List<int> data) {
  final out = <int>[];
  var i = 0;
  while (i < data.length) {
    final b = data[i];
    if (b >= 0x09 && b < 0x80 && b != 0x00) {
      out.add(b);
      i++;
    } else {
      final n = [for (var j = i; j < i + 8 && j < data.length; j++) data[j]];
      out.add(n.length);
      out.addAll(n);
      i += n.length;
    }
  }
  return Uint8List.fromList(out);
}

int _u32At(Uint8List b, int o) =>
    (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const html = '''
<html><body>
<h1>第一章 起点</h1>
<p>这是第一章的内容。</p>
<mbp:pagebreak/>
<h1>第二章 转折</h1>
<p>这是第二章的内容，包含<b>加粗</b>文本。</p>
<img src="recindex:00001"/>
</body></html>
''';

  test('MOBI：元数据 / 分章 / 目录 / 封面全链路解析', () async {
    final cover = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A]);
    final bytes = buildMobi(html: html, cover: cover);

    final result = await const MobiParser().parse(bytes);
    final doc = result.document;

    expect(doc.meta.title, '测试之书');
    expect(doc.meta.author, '测试作者');
    expect(doc.spine.length, 2, reason: 'mbp:pagebreak 应分出两章');
    expect(doc.spine[0].title, '第一章 起点');
    expect(doc.spine[0].plainText, contains('这是第一章的内容'));
    expect(doc.spine[1].plainText, contains('加粗'));
    expect(result.coverBytes, cover);

    // 目录：两章各一条标题条目
    expect(doc.toc.length, 2);
    expect(doc.toc[0].title, '第一章 起点');
    expect(doc.toc[0].spineIndex, 0);
    expect(doc.toc[1].title, '第二章 转折');
    expect(doc.toc[1].spineIndex, 1);

    // 图片资源：recindex:00001 → 第一张图片记录
    final img = await doc.resources.get('recindex:00001');
    expect(img, isNotNull);
    expect(img!.first, 0x89);

    // 进度加权
    expect(doc.totalChars, doc.spine[0].charLength + doc.spine[1].charLength);
  });

  test('MOBI：PalmDOC 压缩（compression=2）解压往返', () async {
    final bytes = buildMobi(
      html: html,
      compression: 2,
      title: '压缩之书',
      author: '作者甲',
    );
    final result = await const MobiParser().parse(bytes);
    expect(result.document.meta.title, '压缩之书');
    expect(result.document.spine.length, 2);
    expect(result.document.spine[1].plainText, contains('第二章的内容'));
  });

  test('MOBI：Latin-1（CP1252）编码正文解码', () async {
    final latinHtml = '<html><body><p>Hola MOBI</p></body></html>';
    final bytes = buildMobi(html: latinHtml, textEncoding: 1252);
    final result = await const MobiParser().parse(bytes);
    expect(result.document.spine[0].plainText, contains('Hola MOBI'));
  });

  test('MOBI：DRM 加密明确拒绝', () async {
    final bytes = buildMobi(html: html);
    final rec0Off = _u32At(bytes, 78);
    bytes[rec0Off + 12] = 0;
    bytes[rec0Off + 13] = 2; // encryption = 2
    await expectLater(
      const MobiParser().parse(bytes),
      throwsA(
        isA<BookParseException>().having(
          (e) => e.message,
          'message',
          contains('DRM'),
        ),
      ),
    );
  });

  test('MOBI：HUFF/CDIC 压缩明确提示不支持', () async {
    final bytes = buildMobi(html: html);
    final rec0Off = _u32At(bytes, 78);
    bytes[rec0Off] = (17480 >> 8) & 0xFF;
    bytes[rec0Off + 1] = 17480 & 0xFF;
    await expectLater(
      const MobiParser().parse(bytes),
      throwsA(
        isA<BookParseException>().having(
          (e) => e.message,
          'message',
          contains('HUFF/CDIC'),
        ),
      ),
    );
  });

  test('MOBI：非 PDB 文件报错', () async {
    await expectLater(
      const MobiParser().parse(List.filled(100, 0)),
      throwsA(isA<BookParseException>()),
    );
  });

  test('PalmDOC 解压：重叠回引（RLE 风格）正确展开', () {
    // 先字面量输出 "ab"，再 pair(distance=2, length=8) → "ab" 重复 5 次
    const dist = 2, len = 8;
    final pair = (dist << 3) | (len - 3);
    final data = <int>[
      0x61, // 'a'
      0x62, // 'b'
      0x80 | (pair >> 8), // 0x80-0xBF 区间首字节
      pair & 0xFF,
    ];
    final out = MobiParser.palmDocDecompress(data);
    expect(utf8.decode(out), 'ab' * 5);
  });

  test('PalmDOC 解压：0xC0-0xFF 区间展开为空格 + 字面量', () {
    // 0xE1 ^ 0xC0 = 0x21 = '!'
    final out = MobiParser.palmDocDecompress([0xE1]);
    expect(utf8.decode(out), ' !');
  });
}
