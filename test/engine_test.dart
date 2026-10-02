import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:flutter/painting.dart' show EdgeInsets, Offset;
import 'package:flutter_test/flutter_test.dart';
import 'package:literead/engine/ir/book_document.dart';
import 'package:literead/engine/pagination/text_paginator.dart';
import 'package:literead/engine/parsers/book_parser.dart';
import 'package:literead/engine/parsers/epub_parser.dart';
import 'package:literead/engine/parsers/md_parser.dart';
import 'package:literead/engine/parsers/txt_parser.dart';
import 'package:literead/features/reader/presentation/page_flow.dart'
    show PageCanvas;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Locator（ADR-005 位置标识）', () {
    test('JSON 序列化往返', () {
      final l = const Locator(
        spineIndex: 3,
        charOffset: 1234,
        chapterLength: 9999,
      );
      final restored = Locator.fromJson(l.toJson());
      expect(restored.spineIndex, 3);
      expect(restored.charOffset, 1234);
      expect(restored.chapterLength, 9999);
    });

    test('URI 编码往返', () {
      final l = const Locator(
        spineIndex: 7,
        charOffset: 42,
        chapterLength: 100,
      );
      expect(Locator.decode(l.encode()), l);
    });
  });

  group('TXT 解析器', () {
    test('UTF-8 中文分章', () async {
      final text = StringBuffer();
      text.writeln('第一章 初入江湖');
      text.writeln('少年提剑出鞘。');
      text.writeln('');
      for (var i = 0; i < 60; i++) {
        text.writeln('他一路向北，风雪兼程。');
      }
      text.writeln('第二章 再遇故人');
      text.writeln('故人相逢，百感交集。');
      final result = await const TxtParser().parse(
        utf8.encode(text.toString()),
      );
      expect(result.document.spine.length, 2);
      expect(result.document.spine[0].title, contains('第一章'));
      expect(result.document.spine[1].title, contains('第二章'));
    });

    test('无章节标记长文按长度切块', () async {
      final text = List.generate(3000, (_) => '这是一段没有章节标记的文本内容。').join('\n');
      final result = await const TxtParser().parse(text.codeUnits);
      expect(result.document.spine.length, greaterThanOrEqualTo(2));
    });

    test('GBK 编码不乱码', () {
      // "测试" 的 GBK 编码字节
      final gbkBytes = [0xB2, 0xE2, 0xCA, 0xD4];
      final result = const TxtParser().detectAndDecode(gbkBytes);
      expect(result.encoding, TxtEncoding.gbk);
      expect(result.text, contains('测'));
    });
  });

  group('Markdown 解析器', () {
    test('标题/段落/代码块', () async {
      const md = '''
# 我的第一篇文档

这是**加粗**段落，包含*斜体*。

```dart
void main() {}
```

- 列表项 A
- 列表项 B

1. 有序一
2. 有序二
''';
      final result = await const MdParser().parse(md);
      final doc = result.document;
      expect(doc.spine, hasLength(1));
      expect(doc.meta.title, '我的第一篇文档');
      final blocks = doc.spine.first.blocks;
      expect(
        blocks.any((b) => b.type == BlockType.heading && b.headingLevel == 1),
        isTrue,
      );
      expect(blocks.any((b) => b.type == BlockType.code), isTrue);
      expect(
        blocks.where((b) => b.type == BlockType.listItem).length,
        greaterThanOrEqualTo(4),
      );
      // 目录含标题锚点
      expect(doc.toc, isNotEmpty);
    });
  });

  group('EPUB 解析器', () {
    test('最小 EPUB：OPF + spine + NCX + 图片资源', () async {
      final bytes = _buildMinimalEpub();
      final result = await const EpubParser().parse(bytes);
      final doc = result.document;

      expect(doc.meta.title, '测试之书');
      expect(doc.meta.author, '某人');
      expect(doc.spine, hasLength(2));
      expect(
        doc.spine[0].blocks.any((b) => b.plainText.contains('第一章内容')),
        isTrue,
      );
      expect(doc.toc.first.title, '第一章 标题');

      // 章内插图：src 相对章节目录 → 解析为 zip 内绝对路径（插图不显示回归）
      final imageBlock = doc.spine[0].blocks
          .where((b) => b.type == BlockType.image)
          .toList();
      expect(imageBlock, isNotEmpty);
      expect(imageBlock.first.imageSrc, 'OEBPS/images/pic.png');
      final pic = await doc.resources.get(imageBlock.first.imageSrc!);
      expect(pic, isNotNull);
      expect(pic, hasLength(4));

      // 资源惰性加载（zip 绝对路径）
      final img = await doc.resources.get('OEBPS/images/cover.png');
      expect(img, isNotNull);
      expect(img, hasLength(4));
    });

    test('加密 EPUB 明确报错', () async {
      final archive = Archive();
      archive.addFile(
        ArchiveFile('mimetype', 20, 'application/epub+zip'.codeUnits),
      );
      archive.addFile(
        ArchiveFile('META-INF/encryption.xml', 100, '<encryption/>'.codeUnits),
      );
      final zip = ZipEncoder().encode(archive);
      expect(
        () => const EpubParser().parse(zip),
        throwsA(isA<BookParseException>()),
      );
    });

    test('EPUB3 nav.xhtml 目录：:scope 选择器回归（不抛 UnimplementedError）', () async {
      final bytes = _buildEpub3WithNav();
      final result = await const EpubParser().parse(bytes);
      final doc = result.document;

      expect(doc.meta.title, '导航测试');
      expect(doc.spine, hasLength(2));
      // nav.xhtml 目录正确解析（含嵌套层级）
      expect(doc.toc, hasLength(3));
      expect(doc.toc[0].title, '第一章');
      expect(doc.toc[0].spineIndex, 0);
      expect(doc.toc[1].title, '第一节');
      expect(doc.toc[1].depth, 1);
      expect(doc.toc[2].title, '第二章');
      expect(doc.toc[2].spineIndex, 1);
    });
  });

  group('日文振假名（EPUB ruby）', () {
    late LayoutStyleSet styles;

    setUp(() {
      const cfg = LayoutConfig(
        fontSize: 18,
        lineHeight: 1.6,
        letterSpacing: 0,
        paragraphSpacing: 0.5,
        contentWidth: 320,
        contentHeight: 560,
        indentChars: 2,
        justify: true,
      );
      styles = LayoutStyleSet(
        config: cfg,
        foreground: const ui.Color(0xFF1F2328),
        secondary: const ui.Color(0xFF6E7781),
        accent: const ui.Color(0xFF2F6FED),
      );
    });

    test('ruby 标签解析：rt 注音挂 InlineRun.ruby 且不计入正文', () async {
      final result = await const EpubParser().parse(_buildRubyEpub());
      final doc = result.document;
      final para = doc.spine.first.blocks
          .where(
            (b) =>
                b.type == BlockType.paragraph &&
                b.spans.any((s) => s.ruby != null),
          )
          .first;
      final run = para.spans.firstWhere((s) => s.ruby != null);
      expect(run.text, '漢字');
      expect(run.ruby, 'かんじ');
      // 注音不计入 plainText（Locator 坐标不受注音影响）
      expect(para.plainText, contains('漢字のテスト'));
      expect(para.plainText, isNot(contains('かんじ')));
    });

    test('平假名/片假名文本完整保留', () async {
      final result = await const EpubParser().parse(_buildRubyEpub());
      final text = result.document.spine.first.blocks
          .map((b) => b.plainText)
          .join();
      expect(text, contains('アイウエオ'));
      expect(text, contains('あいうえお'));
      expect(text, contains('のテスト'));
    });

    test('分页后 rubyRuns 携带块内区间与注音文本', () async {
      final result = await const EpubParser().parse(_buildRubyEpub());
      final chapter = result.document.spine.first;
      final laid = await const TextPaginator().paginate(
        chapter: chapter,
        spineIndex: 0,
        styles: styles,
      );
      final withRuby = laid.blocks
          .where((lb) => lb.rubyRuns.isNotEmpty)
          .toList();
      expect(withRuby, isNotEmpty);
      final (rs, re, rt) = withRuby.first.rubyRuns.first;
      expect(rt, 'かんじ');
      expect(rs, lessThan(re));
      expect(re, lessThanOrEqualTo(withRuby.first.block.plainText.length));
      // 注音区间正对正文中的被注音文本
      expect(withRuby.first.block.plainText.substring(rs, re), '漢字');
    });
  });

  group('格式探测', () {
    test('扩展名 → 格式', () {
      expect(formatFromExtension('a/b.epub'), BookFormat.epub);
      expect(formatFromExtension('b.MD'), BookFormat.md);
      expect(formatFromExtension('c.azw3'), BookFormat.azw3);
      expect(formatFromExtension('d.txt'), BookFormat.txt);
    });

    test('PK 魔数识别 EPUB', () {
      expect(
        detectFormat('book.md', [0x50, 0x4B, 3, 4, 0, 0]),
        BookFormat.epub,
      );
      expect(
        detectFormat('book.txt', [0x25, 0x50, 0x44, 0x46, 0x2D]),
        BookFormat.pdf,
      );
    });
  });

  group('分页引擎（M1 核心）', () {
    late LayoutStyleSet styles;

    setUp(() {
      const cfg = LayoutConfig(
        fontSize: 18,
        lineHeight: 1.6,
        letterSpacing: 0,
        paragraphSpacing: 0.5,
        contentWidth: 320,
        contentHeight: 560,
        indentChars: 2,
        justify: true,
      );
      styles = LayoutStyleSet(
        config: cfg,
        foreground: const ui.Color(0xFF1F2328),
        secondary: const ui.Color(0xFF6E7781),
        accent: const ui.Color(0xFF2F6FED),
      );
    });

    test('多段落分页：页数 > 1 且所有页覆盖全章', () async {
      final blocks = List.generate(60, (i) => _para('第$i段。' * 8));
      final chapter = Chapter(id: 'c1', title: '章一', blocks: blocks);
      final laid = await const TextPaginator().paginate(
        chapter: chapter,
        spineIndex: 0,
        styles: styles,
      );

      expect(laid.pages.length, greaterThan(1));
      // 第一页从 0 开始
      expect(laid.pages.first.startChar, 0);
      // 页起点单调不减
      for (var i = 1; i < laid.pages.length; i++) {
        expect(
          laid.pages[i].startChar,
          greaterThanOrEqualTo(laid.pages[i - 1].startChar),
        );
      }
      // 最后一页终点 = 章长
      expect(laid.pages.last.endChar, chapter.charLength);
    });

    test('Locator 映射：偏移 ↔ 页号 稳定（排版无关性验证）', () async {
      final blocks = List.generate(80, (i) => _para('段落内容$i。' * 10));
      final chapter = Chapter(id: 'c2', title: '章二', blocks: blocks);
      final paginator = const TextPaginator();

      // 两套排版参数（字号不同）下，同一 charOffset 都能定位
      final laidA = await paginator.paginate(
        chapter: chapter,
        spineIndex: 0,
        styles: styles,
      );
      final cfgB = LayoutConfig(
        fontSize: 24,
        lineHeight: 2.0,
        letterSpacing: 0,
        paragraphSpacing: 0.5,
        contentWidth: 300,
        contentHeight: 500,
        indentChars: 2,
        justify: false,
      );
      final laidB = await paginator.paginate(
        chapter: chapter,
        spineIndex: 0,
        styles: LayoutStyleSet(
          config: cfgB,
          foreground: const ui.Color(0xFF000000),
          secondary: const ui.Color(0xFF888888),
          accent: const ui.Color(0xFF2F6FED),
        ),
      );

      expect(laidA.pages.length, greaterThanOrEqualTo(1));
      expect(laidB.pages.length, greaterThanOrEqualTo(1));

      const probeOffset = 500;
      final pageA = laidA.pageIndexForChar(probeOffset);
      final pageB = laidB.pageIndexForChar(probeOffset);
      expect(pageA, greaterThanOrEqualTo(0));
      expect(pageB, greaterThanOrEqualTo(0));
      // 两套排版都能找到包含该偏移的页
      expect(laidA.pages[pageA].startChar, lessThanOrEqualTo(probeOffset));
      expect(laidB.pages[pageB].startChar, lessThanOrEqualTo(probeOffset));
    });

    test('超长单段按行切分', () async {
      final longText = List.generate(400, (i) => '超长段落第$i句。').join();
      final chapter = Chapter(id: 'c3', title: '章三', blocks: [_para(longText)]);
      final laid = await const TextPaginator().paginate(
        chapter: chapter,
        spineIndex: 0,
        styles: styles,
      );
      expect(laid.pages.length, greaterThan(3));
    });

    test('空章至少一页', () async {
      final chapter = Chapter(id: 'c4', title: '空章', blocks: const []);
      final laid = await const TextPaginator().paginate(
        chapter: chapter,
        spineIndex: 0,
        styles: styles,
      );
      expect(laid.pages.length, 1);
    });

    test('BookDocument 全局进度加权', () async {
      final c1 = Chapter(id: 'a', title: 'A', blocks: [_para('x' * 100)]);
      final c2 = Chapter(id: 'b', title: 'B', blocks: [_para('y' * 300)]);
      final doc = BookDocument(
        meta: const BookMeta(title: 'T'),
        spine: [c1, c2],
        toc: const [TocEntry(title: 'A', spineIndex: 0)],
        resources: ResourceStore((_) async => null),
      );
      expect(doc.totalChars, 400);
      expect(doc.globalCharsBefore(1), 100);
    });

    test('首行缩进对所有自然段生效（每段均带缩进前缀）', () async {
      // 回归 #14：缩进应作用于全部自然段，而非仅第一章第一段
      final blocks = List.generate(
        3,
        (i) => _para('这是第$i个自然段的内容，应当有首行缩进。' * 4),
      );
      final chapter = Chapter(id: 'c5', title: '章五', blocks: blocks);
      final laid = await const TextPaginator().paginate(
        chapter: chapter,
        spineIndex: 0,
        styles: styles,
      );
      final paras = laid.blocks.where((lb) => !lb.isImage).toList();
      expect(paras.length, 3);
      for (var i = 0; i < paras.length; i++) {
        expect(paras[i].prefixChars, 2, reason: '第${i + 1}个自然段缺少缩进前缀');
        // charBase 与 Chapter.blockOffsets 一致（批注坐标基准）
        expect(paras[i].charBase, chapter.blockOffsets[i]);
      }
    });

    test('hitTestChar：屏幕坐标 → 章内字符偏移往返', () async {
      final blocks = List.generate(
        3,
        (i) => _para('批注命中测试段落$i，长按选中这一段文字。' * 5),
      );
      final chapter = Chapter(id: 'c6', title: '章六', blocks: blocks);
      final laid = await const TextPaginator().paginate(
        chapter: chapter,
        spineIndex: 0,
        styles: styles,
      );
      final page = laid.pages.first;
      expect(page.units, isNotEmpty);
      final unit = page.units.first;
      final lb = laid.blocks[unit.blockIndex];
      // 页内第一个文本单元第一行中线（与绘制几何一致）
      final local = Offset(
        12,
        lb.lineTops[unit.firstLine] + lb.lineHeights[unit.firstLine] / 2,
      );
      final hit = PageCanvas.hitTestChar(laid, page, EdgeInsets.zero, local);
      expect(hit, isNotNull);
      expect(
        hit,
        inInclusiveRange(lb.charBase, lb.charBase + lb.block.plainText.length),
      );
      // 落点在首字符附近（x=12 < 一个字宽）→ 命中块首前 2 字符内
      expect(
        hit! - lb.charBase,
        lessThanOrEqualTo(2),
        reason: 'x=12 应命中该块行首附近',
      );
    });
  });

  group('后台 isolate 解析（文件打开性能优化）', () {
    test('EPUB 经 Isolate.run 解析：资源闭包跨 isolate 仍可用', () async {
      final tmp = await Directory.systemTemp.createTemp('literead_test');
      final f = File('${tmp.path}${Platform.pathSeparator}t.epub');
      await f.writeAsBytes(_buildMinimalEpub());
      try {
        final out = await const BookParser().parseFile(f.path);
        expect(out.document.meta.title, '测试之书');
        expect(out.format, BookFormat.epub);
        // ResourceStore 内含闭包，跨 isolate 传回后必须仍能读资源
        final img = await out.document.resources.get('OEBPS/images/cover.png');
        expect(img, isNotNull);
        expect(img, hasLength(4));
      } finally {
        await tmp.delete(recursive: true);
      }
    });
  });
}

Block _para(String text) =>
    Block(type: BlockType.paragraph, spans: [InlineRun(text)]);

/// 构造 EPUB3（带 nav.xhtml 嵌套目录）zip，用于 :scope 回归测试
List<int> _buildEpub3WithNav() {
  final archive = Archive();
  void add(String name, String content) => archive.addFile(
    ArchiveFile(name, utf8.encode(content).length, utf8.encode(content)),
  );

  add('mimetype', 'application/epub+zip');
  add('META-INF/container.xml', '''
<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>''');
  add('OEBPS/content.opf', '''
<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>导航测试</dc:title>
    <dc:creator>作者</dc:creator>
    <dc:language>zh</dc:language>
  </metadata>
  <manifest>
    <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
    <item id="c2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
  </manifest>
  <spine>
    <itemref idref="c1"/>
    <itemref idref="c2"/>
  </spine>
</package>''');
  add('OEBPS/ch1.xhtml', '<html><body><h1>第一章</h1><p>内容一。</p></body></html>');
  add('OEBPS/ch2.xhtml', '<html><body><h1>第二章</h1><p>内容二。</p></body></html>');
  add('OEBPS/nav.xhtml', '''
<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<body>
  <nav epub:type="toc">
    <ol>
      <li><a href="ch1.xhtml">第一章</a>
        <ol>
          <li><a href="ch1.xhtml#s1">第一节</a></li>
        </ol>
      </li>
      <li><a href="ch2.xhtml">第二章</a></li>
    </ol>
  </nav>
</body>
</html>''');

  return ZipEncoder().encode(archive);
}

/// 构造含 ruby 注音与平假名/片假名的最小 EPUB（振假名回归测试）
List<int> _buildRubyEpub() {
  final archive = Archive();
  void add(String name, String content) => archive.addFile(
    ArchiveFile(name, utf8.encode(content).length, utf8.encode(content)),
  );

  add('mimetype', 'application/epub+zip');
  add('META-INF/container.xml', '''
<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>''');
  add('OEBPS/content.opf', '''
<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="uid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>振假名测试</dc:title>
    <dc:language>ja</dc:language>
  </metadata>
  <manifest>
    <item id="c1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine>
    <itemref idref="c1"/>
  </spine>
</package>''');
  add(
    'OEBPS/chapter1.xhtml',
    '''
<html><body><p><ruby>漢字<rt>かんじ</rt></ruby>のテスト。カタカナ「アイウエオ」ひらがな「あいうえお」。</p></body></html>''',
  );

  return ZipEncoder().encode(archive);
}

/// 构造最小合法 EPUB（zip）：container.xml + OPF + 2 章 + NCX + PNG
List<int> _buildMinimalEpub() {
  final archive = Archive();
  void add(String name, String content) => archive.addFile(
    ArchiveFile(name, utf8.encode(content).length, utf8.encode(content)),
  );

  add('mimetype', 'application/epub+zip');
  add('META-INF/container.xml', '''
<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>''');
  add('OEBPS/content.opf', '''
<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="uid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>测试之书</dc:title>
    <dc:creator>某人</dc:creator>
    <dc:language>zh</dc:language>
    <meta name="cover" content="cover-img"/>
  </metadata>
  <manifest>
    <item id="c1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
    <item id="c2" href="chapter2.xhtml" media-type="application/xhtml+xml"/>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="cover-img" href="images/cover.png" media-type="image/png"/>
  </manifest>
  <spine toc="ncx">
    <itemref idref="c1"/>
    <itemref idref="c2"/>
  </spine>
</package>''');
  add(
    'OEBPS/chapter1.xhtml',
    '''
<html><body><h1>第一章 标题</h1><img src="images/pic.png"/><p>这是第一章内容。</p></body></html>''',
  );
  add('OEBPS/chapter2.xhtml', '''
<html><body><p>第二章内容继续。</p></body></html>''');
  add('OEBPS/toc.ncx', '''
<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <navMap>
    <navPoint id="n1" playOrder="1">
      <navLabel><text>第一章 标题</text></navLabel>
      <content src="chapter1.xhtml"/>
    </navPoint>
    <navPoint id="n2" playOrder="2">
      <navLabel><text>第二章 标题</text></navLabel>
      <content src="chapter2.xhtml"/>
    </navPoint>
  </navMap>
</ncx>''');
  // 假 PNG（4 字节头即可通过长度断言）
  archive.addFile(
    ArchiveFile('OEBPS/images/cover.png', 4, [0x89, 0x50, 0x4E, 0x47]),
  );
  archive.addFile(
    ArchiveFile('OEBPS/images/pic.png', 4, [0x89, 0x50, 0x4E, 0x47]),
  );

  return ZipEncoder().encode(archive);
}
