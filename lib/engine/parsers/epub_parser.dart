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
  Future<EpubParseResult> parse(List<int> bytes) async {
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
    for (final href in spineHrefs) {
      final data = manifestResource(href);
      if (data == null) {
        chapters.add(Chapter(id: href, title: '（缺失：$href）', blocks: const []));
        continue;
      }
      final html = _decodeText(data);
      final doc = html_parser.parse(html);
      final blocks = converter.convertDocument(doc);
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
      final chapterTitle = _firstHeading(doc) ?? _fileNameTitle(href);
      chapters.add(Chapter(id: href, title: chapterTitle, blocks: blocks));
    }

    // 6. 目录：EPUB3 nav → NCX → 兜底（每章一项目录）
    final toc = <TocEntry>[];
    if (navHref != null) {
      final navData = manifestResource(navHref);
      if (navData != null) {
        toc.addAll(_parseNav(_decodeText(navData), spineHrefs));
      }
    }
    if (toc.isEmpty && ncxHref != null) {
      final ncxData = manifestResource(ncxHref);
      if (ncxData != null) {
        toc.addAll(_parseNcx(_decodeText(ncxData), spineHrefs));
      }
    }
    if (toc.isEmpty) {
      for (var i = 0; i < chapters.length; i++) {
        toc.add(TocEntry(title: chapters[i].title, spineIndex: i));
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
  List<TocEntry> _parseNav(String html, List<String> spineHrefs) {
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
        final a = li.children
            .where((e) => e.localName == 'a')
            .firstOrNull;
        if (a != null) {
          final href = a.attributes['href'];
          final idx = _spineIndexOf(href, spineHrefs);
          if (idx >= 0) {
            entries.add(
              TocEntry(
                title: a.text.trim(),
                spineIndex: idx,
                charOffset: _charOffsetOf(href),
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
  List<TocEntry> _parseNcx(String xmlStr, List<String> spineHrefs) {
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
              charOffset: _charOffsetOf(src),
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

int _charOffsetOf(String? href) {
  if (href == null) return 0;
  final f = href.indexOf('#');
  if (f < 0) return 0;
  return 0; // M1：锚点统一落到章首（ID 级偏移在 M3 标注时精确化）
}

String _fileNameTitle(String href) {
  final name = href.split('/').last;
  return Uri.decodeComponent(
    name.replaceFirst(RegExp(r'\.[^.]+$'), '').replaceAll('_', ' '),
  );
}

String? _firstHeading(dom.Document doc) {
  for (final h in doc.body?.querySelectorAll('h1,h2,h3,h4,h5,h6') ?? const []) {
    final t = h.text.trim();
    if (t.isNotEmpty) return t;
  }
  return null;
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
