import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:xml/xml.dart' as xml;

import '../ir/book_document.dart';
import 'html_lite_converter.dart';

/// EPUB 2/3 解析器（计划书 §3.5.1）。
///
/// zip → META-INF/container.xml → OPF → manifest/spine → 逐章 XHTML → IR。
/// 目录优先 EPUB3 nav.xhtml，回退 toc.ncx。加密 EPUB 提示不支持。
class EpubParser {
  const EpubParser();

  static const magicAscii = [0x50, 0x4B]; // 'PK'

  /// 解析 [bytes]，返回文档与封面字节。
  ///
  /// [bookCss] 开启后提取原书 text-align 对齐（见 HtmlLiteConverter）。
  Future<EpubParseResult> parse(List<int> bytes, {bool bookCss = false}) async {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (e) {
      throw BookParseException('EPUB 文件损坏，无法解压（$e）');
    }

    final entries = <String, ArchiveFile>{
      for (final f in archive.files)
        if (f.isFile) _norm(f.name): f,
    };

    // 加密检测（META-INF/encryption.xml 存在即可能加密）
    if (entries.containsKey('META-INF/encryption.xml')) {
      throw const BookParseException('该 EPUB 包含加密内容（DRM/LCP），暂不支持');
    }

    // 1. container.xml → OPF 路径
    final container = entries['META-INF/container.xml'];
    if (container == null) {
      throw const BookParseException('无效的 EPUB：缺少 META-INF/container.xml');
    }
    final containerDoc = _parseXml(await _readText(container));
    final opfPath = containerDoc
        .findAllElements('rootfile')
        .map((e) => e.getAttribute('full-path'))
        .firstWhere((p) => p != null && p.isNotEmpty, orElse: () => null);
    if (opfPath == null) {
      throw const BookParseException('无效的 EPUB：container.xml 中未找到 OPF');
    }
    final opfDir = _dirOf(opfPath);

    // 2. 解析 OPF
    final opfFile = entries[_norm(opfPath)];
    if (opfFile == null) {
      throw BookParseException('无效的 EPUB：缺少 $opfPath');
    }
    final opf = _parseXml(await _readText(opfFile));

    final metaEl =
        opf.findAllElements('metadata').firstOrNull ??
        opf.findAllElements('opf:metadata').firstOrNull;
    String? title;
    String? author;
    String? language;
    String? description;
    String? coverId;
    if (metaEl != null) {
      title =
          metaEl.findElements('dc:title').firstOrNull?.innerText ??
          metaEl.findElements('title').firstOrNull?.innerText;
      author =
          metaEl.findElements('dc:creator').firstOrNull?.innerText ??
          metaEl.findElements('creator').firstOrNull?.innerText;
      language =
          metaEl.findElements('dc:language').firstOrNull?.innerText ??
          metaEl.findElements('language').firstOrNull?.innerText;
      description =
          metaEl.findElements('dc:description').firstOrNull?.innerText ??
          metaEl.findElements('description').firstOrNull?.innerText;
      // EPUB2 cover 声明：<meta name="cover" content="cover-id"/>
      for (final m in metaEl.findElements('meta')) {
        if (m.getAttribute('name') == 'cover') {
          coverId = m.getAttribute('content');
        }
      }
    }

    // 3. manifest
    final manifestEl = opf.findAllElements('manifest').firstOrNull;
    if (manifestEl == null) {
      throw const BookParseException('无效的 EPUB：缺少 manifest');
    }
    final items = <String, _ManifestItem>{};
    String? navHref; // EPUB3 nav
    String? ncxHref; // EPUB2 NCX
    String? coverHref;
    for (final el in manifestEl.findElements('item')) {
      final id = el.getAttribute('id');
      final href = el.getAttribute('href');
      if (id == null || href == null) continue;
      final mediaType = el.getAttribute('media-type') ?? '';
      final props = el.getAttribute('properties') ?? '';
      items[id] = _ManifestItem(
        id: id,
        href: href,
        mediaType: mediaType,
        properties: props,
      );
      if (props.split(RegExp(r'\s+')).contains('nav')) navHref = href;
      if (props.split(RegExp(r'\s+')).contains('cover-image')) coverHref = href;
      if (mediaType == 'application/x-dtbncx+xml') ncxHref = href;
      if (coverId != null && id == coverId) coverHref = href;
    }

    // 4. spine
    final spineEl = opf.findAllElements('spine').firstOrNull;
    if (spineEl == null) {
      throw const BookParseException('无效的 EPUB：缺少 spine');
    }
    if (ncxHref == null) {
      final tocAttr = spineEl.getAttribute('toc');
      if (tocAttr != null && items[tocAttr] != null) {
        ncxHref = items[tocAttr]!.href;
      }
    }
    final spineHrefs = <String>[];
    for (final ir in spineEl.findElements('itemref')) {
      final idref = ir.getAttribute('idref');
      final item = idref == null ? null : items[idref];
      if (item == null) continue;
      final mt = item.mediaType;
      if (mt != 'application/xhtml+xml' && mt != 'text/html') continue;
      spineHrefs.add(item.href);
    }
    if (spineHrefs.isEmpty) {
      throw const BookParseException('无效的 EPUB：spine 为空');
    }

    final converter = const HtmlLiteConverter();

    /// zip 内绝对路径 → 资源字节（章节插图等）
    List<int>? entryBytes(String path) {
      final key = _norm(path);
      final f = entries[key] ?? entries[_decodeZipPath(key)];
      return f == null ? null : f.content as List<int>;
    }

    /// manifest href（相对 OPF 目录）→ 资源字节
    List<int>? manifestResource(String href) {
      final key = _norm(_join(opfDir, href));
      return entryBytes(key);
    }

    // 5. 逐章解析
    final chapters = <Chapter>[];
    // 无正文章节（纯插图页等）的 html `<title>`（目录解析完成后兜底回填）
    final noHeadingHtmlTitles = <int, String>{};
    // 每章的 id 锚点表（目录锚点 → 章内字符偏移；与 chapters 同序）
    final anchorMaps = <Map<String, (int, int)>>[];
    for (final href in spineHrefs) {
      final data = manifestResource(href);
      if (data == null) {
        chapters.add(Chapter(id: href, title: '（缺失：$href）', blocks: const []));
        anchorMaps.add(const {});
        continue;
      }
      final html = _decodeText(data);
      final doc = html_parser.parse(html);
      final anchors = <String, (int, int)>{};
      final footnotes = <String, Footnote>{};
      final blocks = converter.convertDocument(
        doc,
        anchors: anchors,
        footnotesOut: footnotes,
        bookCss: bookCss,
      );
      anchorMaps.add(anchors);
      // 关键修复：图片 src 相对「章节文件目录」而非 OPF 目录，
      // 统一解析为 zip 内绝对路径，否则插图资源全部 404。
      // 注意 spine href 是 OPF 相对路径，需先合并 OPF 目录得到章节的 zip 路径。
      final chapterDir = _dirOf(_norm(_join(opfDir, href)));
      for (var i = 0; i < blocks.length; i++) {
        final b = blocks[i];
        final src = b.imageSrc;
        if (b.type == BlockType.image && src != null && src.isNotEmpty) {
          blocks[i] = b.copyWith(
            imageSrc: _join(chapterDir, Uri.decodeComponent(src)),
          );
        }
      }
      // 目录标题兜底：不用 cover/section006 等原始文件名标识，
      // 首个标题块 → 「第 N 节」；纯插图页等无标题章节记录下来，
      // 待目录解析完成后回填目录标题（插图/序章等）
      final heading = _firstHeading(doc);
      if (heading != null) {
        chapters.add(
          Chapter(
            id: href,
            title: heading,
            blocks: blocks,
            footnotes: footnotes,
          ),
        );
      } else {
        noHeadingHtmlTitles[chapters.length] = _htmlTitle(doc) ?? '';
        chapters.add(
          Chapter(
            id: href,
            title: '第 ${chapters.length + 1} 节',
            blocks: blocks,
            footnotes: footnotes,
          ),
        );
      }
    }

    // 6. 目录：EPUB3 nav → NCX → 兜底（每章一项目录）
    final toc = <TocEntry>[];
    if (navHref != null) {
      final navData = manifestResource(navHref);
      if (navData != null) {
        toc.addAll(
          _parseNav(_decodeText(navData), spineHrefs, chapters, anchorMaps),
        );
      }
    }
    if (toc.isEmpty && ncxHref != null) {
      final ncxData = manifestResource(ncxHref);
      if (ncxData != null) {
        toc.addAll(
          _parseNcx(_decodeText(ncxData), spineHrefs, chapters, anchorMaps),
        );
      }
    }
    if (toc.isEmpty) {
      for (var i = 0; i < chapters.length; i++) {
        toc.add(TocEntry(title: chapters[i].title, spineIndex: i));
      }
    }

    // 章节标题回填：凡落到「第 N 节」兜底（无标题块，或标题块提取失败）
    // 的章节，优先取指向该章章首（charOffset == 0）的目录条目（如
    // 「插图」「序章」），其次该章第一条目录；仅当目录无条目时，无标题
    // 章节再退回 html `<title>`（如「Cover」）；目录与 html title 都没有
    // 时（轻小说正文章节间的插图页、后记续页等），继承前一章标题——
    // 这些页属于前一章的一部分，否则阅读页翻页跨过它们时左上角章节名
    // 会从「第一话」跳成「第 N 节」。
    // 修复阅读页章节名与目录名不一致（目录有名、章名仍显示第 N 节）的 bug
    final fallbackTitleRe = RegExp(r'^第 \d+ 节$');
    for (var i = 0; i < chapters.length; i++) {
      if (!fallbackTitleRe.hasMatch(chapters[i].title)) continue;
      TocEntry? best;
      for (final e in toc) {
        if (e.spineIndex != i) continue;
        if (e.charOffset == 0) {
          best = e;
          break;
        }
        best ??= e;
      }
      final tocTitle = best?.title.trim() ?? '';
      final htmlTitle = noHeadingHtmlTitles[i]?.trim() ?? '';
      var title = tocTitle.isNotEmpty ? tocTitle : htmlTitle;
      if (title.isEmpty && i > 0) {
        final prev = chapters[i - 1].title.trim();
        // 前一章自身仍是兜底标题时不继承（避免把「第 N 节」向前扩散）
        if (prev.isNotEmpty && !fallbackTitleRe.hasMatch(prev)) {
          title = prev;
        }
      }
      if (title.isNotEmpty) {
        chapters[i] = Chapter(
          id: chapters[i].id,
          title: title,
          blocks: chapters[i].blocks,
          footnotes: chapters[i].footnotes,
        );
      }
    }

    // 7. 资源存储（惰性；imageSrc 已是 zip 内绝对路径）
    final resources = ResourceStore((id) async => entryBytes(id));

    // 8. 封面
    List<int>? coverBytes;
    String? coverResource;
    if (coverHref != null) {
      coverBytes = manifestResource(coverHref);
      coverResource = coverHref;
    }

    return EpubParseResult(
      document: BookDocument(
        meta: BookMeta(
          title: (title?.trim().isNotEmpty ?? false) ? title!.trim() : '未命名',
          author: author?.trim(),
          language: language?.trim(),
          description: (description?.trim().isNotEmpty ?? false)
              ? description!.trim()
              : null,
          coverResource: coverResource,
        ),
        spine: chapters,
        toc: toc,
        resources: resources,
      ),
      coverBytes: coverBytes,
    );
  }

  // ---- 目录解析 ----

  /// EPUB3 nav.xhtml：<nav epub:type="toc"> 下的 ol/li/a
  List<TocEntry> _parseNav(
    String html,
    List<String> spineHrefs,
    List<Chapter> chapters,
    List<Map<String, (int, int)>> anchorMaps,
  ) {
    final doc = html_parser.parse(html);
    final entries = <TocEntry>[];
    dom.Element? tocNav;
    for (final nav in doc.querySelectorAll('nav')) {
      final type = nav.attributes['epub:type'] ?? nav.attributes['type'] ?? '';
      if (type.contains('toc')) {
        tocNav = nav;
        break;
      }
    }
    tocNav ??= doc.querySelector('nav');
    if (tocNav == null) return entries;

    void walk(dom.Element ol, int depth) {
      for (final li in ol.children.where((e) => e.localName == 'li')) {
        // html 包选择器引擎不支持 :scope 伪类（会抛 UnimplementedError），
        // 改用直接子元素过滤。
        final a = li.children.where((e) => e.localName == 'a').firstOrNull;
        if (a != null) {
          final href = a.attributes['href'];
          final title = a.text.trim();
          final idx = _spineIndexOf(href, spineHrefs);
          // 空标题条目回退为章标题（避免目录出现空白项）
          if (idx >= 0 && title.isNotEmpty) {
            entries.add(
              TocEntry(
                title: title,
                spineIndex: idx,
                charOffset: _anchorOffset(href, chapters, anchorMaps, idx),
                depth: depth,
              ),
            );
          }
        }
        final subOl = li.children.where((e) => e.localName == 'ol').firstOrNull;
        if (subOl != null) walk(subOl, depth + 1);
      }
    }

    final rootOl = tocNav.querySelector('ol');
    if (rootOl != null) walk(rootOl, 0);
    return entries;
  }

  /// EPUB2 toc.ncx：navMap/navPoint（可嵌套）
  List<TocEntry> _parseNcx(
    String xmlStr,
    List<String> spineHrefs,
    List<Chapter> chapters,
    List<Map<String, (int, int)>> anchorMaps,
  ) {
    final doc = _parseXml(xmlStr);
    final entries = <TocEntry>[];
    final navMap = doc.findAllElements('navMap').firstOrNull;
    if (navMap == null) return entries;

    void walk(xml.XmlElement parent, int depth) {
      for (final np in parent.findElements('navPoint')) {
        final label = np.findElements('navLabel').firstOrNull?.innerText.trim();
        final src = np.findElements('content').firstOrNull?.getAttribute('src');
        final idx = _spineIndexOf(src, spineHrefs);
        if (label != null && label.isNotEmpty && idx >= 0) {
          entries.add(
            TocEntry(
              title: label,
              spineIndex: idx,
              charOffset: _anchorOffset(src, chapters, anchorMaps, idx),
              depth: depth,
            ),
          );
        }
        walk(np, depth + 1);
      }
    }

    walk(navMap, 0);
    return entries;
  }

  /// 目录 href 锚点 → 章内字符偏移：有锚点记录时精确定位，
  /// 否则落章首。单文件整书 EPUB 的目录跳转由此恢复可用。
  int _anchorOffset(
    String? href,
    List<Chapter> chapters,
    List<Map<String, (int, int)>> anchorMaps,
    int spineIndex,
  ) {
    if (href == null || spineIndex < 0 || spineIndex >= chapters.length) {
      return 0;
    }
    final f = href.indexOf('#');
    if (f < 0) return 0;
    final id = Uri.decodeComponent(href.substring(f + 1));
    if (id.isEmpty) return 0;
    final a = anchorMaps[spineIndex][id];
    if (a == null) return 0;
    final (bi, ci) = a;
    final chapter = chapters[spineIndex];
    if (bi >= chapter.blocks.length) return 0;
    final offs = chapter.blockOffsets;
    final maxInBlock = chapter.blocks[bi].plainText.length;
    return offs[bi] + ci.clamp(0, maxInBlock);
  }
}

class EpubParseResult {
  const EpubParseResult({required this.document, this.coverBytes});

  final BookDocument document;
  final List<int>? coverBytes;
}

class _ManifestItem {
  const _ManifestItem({
    required this.id,
    required this.href,
    required this.mediaType,
    required this.properties,
  });

  final String id;
  final String href;
  final String mediaType;
  final String properties;
}

// ---- 工具函数 ----

/// 解析失败异常（带用户可读信息）
class BookParseException implements Exception {
  const BookParseException(this.message);

  final String message;

  @override
  String toString() => message;
}

String _norm(String path) =>
    path.replaceAll('\\', '/').replaceFirst(RegExp(r'^/'), '');

/// zip 条目名可能保留 URL 编码形式（如 `my%20image.png`），兜底解码查找
String _decodeZipPath(String path) {
  try {
    return Uri.decodeComponent(path);
  } catch (_) {
    return path;
  }
}

String _dirOf(String path) {
  final i = path.lastIndexOf('/');
  return i < 0 ? '' : path.substring(0, i);
}

/// 相对路径合并并归一化（处理 ../）
String _join(String base, String ref) {
  if (ref.startsWith('/')) return _norm(ref);
  final parts = <String>[];
  if (base.isNotEmpty) parts.addAll(base.split('/'));
  for (final seg in ref.split('/')) {
    if (seg == '' || seg == '.') continue;
    if (seg == '..') {
      if (parts.isNotEmpty) parts.removeLast();
    } else {
      parts.add(seg);
    }
  }
  return parts.join('/');
}

/// spine href 匹配：忽略锚点与查询串
int _spineIndexOf(String? href, List<String> spineHrefs) {
  if (href == null) return -1;
  final clean = _stripFragment(href);
  final idx = spineHrefs.indexOf(clean);
  if (idx >= 0) return idx;
  // 大小写/编码差异兜底
  final lower = clean.toLowerCase();
  for (var i = 0; i < spineHrefs.length; i++) {
    if (spineHrefs[i].toLowerCase() == lower) return i;
  }
  return -1;
}

String _stripFragment(String href) {
  var h = href;
  final q = h.indexOf('?');
  if (q >= 0) h = h.substring(0, q);
  final f = h.indexOf('#');
  if (f >= 0) h = h.substring(0, f);
  return _norm(Uri.decodeComponent(h));
}

String? _firstHeading(dom.Document doc) {
  for (final h in doc.body?.querySelectorAll('h1,h2,h3,h4,h5,h6') ?? const []) {
    final t = h.text.trim();
    if (t.isNotEmpty) return t;
  }
  return null;
}

/// html `<title>` 兜底（目录无条目的封面页等使用，如「Cover」）
String? _htmlTitle(dom.Document doc) {
  final t = doc.head?.querySelector('title')?.text.trim() ?? '';
  return t.isEmpty ? null : t;
}

Future<String> _readText(ArchiveFile f) async =>
    _decodeText(f.content as List<int>);

/// 智能文本解码：UTF-8 优先，失败回退 Latin-1（保字节不崩）
String _decodeText(List<int> data) {
  try {
    return utf8.decode(data, allowMalformed: false);
  } on FormatException {
    try {
      return utf8.decode(data, allowMalformed: true);
    } catch (_) {
      return latin1.decode(data, allowInvalid: true);
    }
  }
}

xml.XmlDocument _parseXml(String src) {
  try {
    return xml.XmlDocument.parse(src);
  } catch (e) {
    throw BookParseException('XML 解析失败（$e）');
  }
}

extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull => isEmpty ? null : first;
}
