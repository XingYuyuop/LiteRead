import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../ir/book_document.dart';

/// HTML → HTML-lite（白名单降级，计划书 §3.3）。
///
/// 只保留 p/h1-h6/img/em/strong/b/i/blockquote/ul/ol/li/pre/code/hr/br/a
/// 等语义标签；其余降级为纯文本。CSS 颜色一律丢弃，映射到当前主题。
///
/// EPUB 附加能力：
/// - `<aside epub:type="footnote|rearnote|note" id>` 提取为脚注内容，不展开进正文；
/// - `<a epub:type="noteref" href="#fn1">` 标记为注标 run（refId）；
/// - 所有带 id 的元素记录锚点位置（目录锚点 → 章内字符偏移）。
class HtmlLiteConverter {
  const HtmlLiteConverter();

  /// 解析 HTML 字符串并提取块序列
  ///
  /// [anchors]: 元素 id → (块序号, 块内字符偏移)（可选输出）；
  /// [footnotesOut]: 脚注 id → 内容（可选输出）。
  List<Block> convert(String html, {Map<String, (int, int)>? anchors, Map<String, Footnote>? footnotesOut}) {
    final doc = html_parser.parse(utf8.decode(utf8.encode(html)));
    final body = doc.body;
    if (body == null) return const [];
    final ctx = _Ctx();
    _walkChildren(body.nodes, ctx, quoteDepth: 0);
    anchors?.addAll(ctx.anchors);
    footnotesOut?.addAll(ctx.footnotes);
    return ctx.blocks;
  }

  List<Block> convertDocument(
    dom.Document doc, {
    Map<String, (int, int)>? anchors,
    Map<String, Footnote>? footnotesOut,
  }) {
    final body = doc.body;
    if (body == null) return const [];
    final ctx = _Ctx();
    _walkChildren(body.nodes, ctx, quoteDepth: 0);
    anchors?.addAll(ctx.anchors);
    footnotesOut?.addAll(ctx.footnotes);
    return ctx.blocks;
  }
}

class _Ctx {
  final List<Block> blocks = [];

  /// 元素 id → (块序号, 块内字符偏移)
  final Map<String, (int, int)> anchors = {};

  /// 脚注 id → 内容
  final Map<String, Footnote> footnotes = {};
}

const _blockTags = {
  'p',
  'div',
  'section',
  'article',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'blockquote',
  'ul',
  'ol',
  'li',
  'pre',
  'hr',
  'table',
  'figure',
  'figcaption',
  'header',
  'footer',
  'main',
  'aside',
  'nav',
  'body',
  'dd',
  'dt',
  'dl',
  'tr',
  'td',
  'th',
  'tbody',
  'thead',
  'center',
};

/// 遍历块级容器的子节点：连续行内内容（文本/ruby/行内标签）缓冲合并为
/// 同一个段落，遇到块级子元素时先冲刷缓冲再递归处理。
/// 避免把 `<p><ruby>漢字<rt>…</rt></ruby>のテスト</p>` 拆成多个段落。
void _walkChildren(
  List<dom.Node> nodes,
  _Ctx ctx, {
  required int quoteDepth,
  int listDepth = 0,
}) {
  var pending = <InlineRun>[];

  void flush() {
    final runs = <InlineRun>[];
    for (var i = 0; i < pending.length; i++) {
      var t = pending[i].text;
      if (i == 0) t = t.trimLeft();
      if (i == pending.length - 1) t = t.trimRight();
      if (t.isEmpty) continue;
      final f = pending[i];
      runs.add(InlineRun(t, flags: f.flags, ruby: f.ruby, refId: f.refId));
    }
    pending = <InlineRun>[];
    if (runs.any((r) => r.text.trim().isNotEmpty)) {
      ctx.blocks.add(_paragraphOf(runs, quoteDepth));
    }
  }

  for (final child in nodes) {
    if (child is dom.Text) {
      final t = child.text.replaceAll('\u00a0', ' ');
      if (t.isEmpty) continue;
      // 纯空白节点：夹在行内元素之间时保留一个空格，其余丢弃
      if (t.trim().isEmpty) {
        if (pending.isNotEmpty && pending.last.text.isNotEmpty) {
          pending.add(const InlineRun(' '));
        }
        continue;
      }
      pending.add(InlineRun(t));
      continue;
    }
    if (child is! dom.Element) continue;
    final tag = child.localName?.toLowerCase() ?? '';
    final isBlock =
        _blockTags.contains(tag) ||
        const {'img', 'image', 'br', 'svg', 'script', 'style'}.contains(tag);
    if (isBlock) {
      flush();
      // 块级锚点：定位到该元素生成的下一个块（通常是它本身）的块首
      _recordAnchor(child, ctx, 0);
      _walkBlock(child, ctx, quoteDepth: quoteDepth, listDepth: listDepth);
    } else {
      // 行内锚点：定位到当前累积段落的块内偏移
      _recordAnchor(child, ctx, _pendingLen(pending));
      pending.addAll(_inlineRuns(child));
    }
  }
  flush();
}

/// 记录元素 id 锚点位置（首个出现者优先；id 应唯一）
void _recordAnchor(dom.Element el, _Ctx ctx, int charInBlock) {
  final id = el.attributes['id'];
  if (id == null || id.isEmpty || ctx.anchors.containsKey(id)) return;
  ctx.anchors[id] = (ctx.blocks.length, charInBlock);
}

int _pendingLen(List<InlineRun> pending) =>
    pending.fold(0, (s, r) => s + r.text.length);

void _walkBlock(
  dom.Element node,
  _Ctx ctx, {
  required int quoteDepth,
  int listDepth = 0,
}) {
  final tag = node.localName?.toLowerCase() ?? '';

  // EPUB3 脚注/尾注容器：提取为脚注内容，不展开进正文流
  // （否则注释文字会混入正文，且注标点击无内容可看）
  final epubType =
      (node.attributes['epub:type'] ?? node.attributes['type'] ?? '')
          .toLowerCase();
  final fid = node.attributes['id'];
  if (fid != null &&
      fid.isNotEmpty &&
      (tag == 'aside' || tag == 'div' || tag == 'section') &&
      (epubType.contains('footnote') ||
          epubType.contains('rearnote') ||
          epubType == 'note')) {
    final text = _footnoteText(node);
    if (text.isNotEmpty && !ctx.footnotes.containsKey(fid)) {
      ctx.footnotes[fid] = Footnote(id: fid, text: text);
    }
    return;
  }

  switch (tag) {
    case 'h1':
    case 'h2':
    case 'h3':
    case 'h4':
    case 'h5':
    case 'h6':
      final text = _inlineText(node).trim();
      if (text.isNotEmpty) {
        ctx.blocks.add(
          Block(
            type: BlockType.heading,
            spans: [InlineRun(text)],
            headingLevel: int.parse(tag.substring(1)),
          ),
        );
      }
      return;
    case 'img':
      final src = node.attributes['src'] ?? node.attributes['xlink:href'];
      if (src != null && src.isNotEmpty) {
        ctx.blocks.add(
          Block(
            type: BlockType.image,
            spans: const [],
            imageSrc: _resolveSrc(src),
          ),
        );
      }
      return;
    case 'image': // SVG 内嵌 image
      final href = node.attributes['href'] ?? node.attributes['xlink:href'];
      if (href != null && href.isNotEmpty) {
        ctx.blocks.add(
          Block(
            type: BlockType.image,
            spans: const [],
            imageSrc: _resolveSrc(href),
          ),
        );
      }
      return;
    case 'hr':
      ctx.blocks.add(const Block(type: BlockType.hr, spans: []));
      return;
    case 'br':
      // 行内换行在块级上下文当作段落边界
      return;
    case 'blockquote':
      _walkChildren(node.nodes, ctx, quoteDepth: quoteDepth + 1);
      return;
    case 'ul':
      var i = 0;
      for (final child in node.nodes) {
        if (child is dom.Element && child.localName == 'li') {
          _walkListItem(
            child,
            ctx,
            quoteDepth: quoteDepth,
            marker: -1,
            index: ++i,
            depth: listDepth,
          );
        }
      }
      return;
    case 'ol':
      var i = 0;
      for (final child in node.nodes) {
        if (child is dom.Element && child.localName == 'li') {
          _walkListItem(
            child,
            ctx,
            quoteDepth: quoteDepth,
            marker: ++i,
            index: i,
            depth: listDepth,
          );
        }
      }
      return;
    case 'li':
      // 直接出现的 li（不规范 HTML），按无序处理
      _walkListItem(
        node,
        ctx,
        quoteDepth: quoteDepth,
        marker: -1,
        index: 1,
        depth: listDepth,
      );
      return;
    case 'pre':
      final text = node.text;
      if (text.trim().isNotEmpty) {
        ctx.blocks.add(Block(type: BlockType.code, spans: [InlineRun(text)]));
      }
      return;
    case 'svg':
      // SVG 容器：不整体忽略，继续走子节点，
      // 内部 <image xlink:href="...">（EPUB 封面页常见）会被提取为图片块
      _walkChildren(
        node.nodes,
        ctx,
        quoteDepth: quoteDepth,
        listDepth: listDepth,
      );
      return;
    case 'script':
    case 'style':
    case 'head':
    case 'link':
    case 'meta':
      return;
    default:
      break;
  }

  if (_blockTags.contains(tag)) {
    _walkChildren(
      node.nodes,
      ctx,
      quoteDepth: quoteDepth,
      listDepth: listDepth,
    );
    return;
  }
}

void _walkListItem(
  dom.Element li,
  _Ctx ctx, {
  required int quoteDepth,
  required int marker,
  required int index,
  required int depth,
}) {
  // li 内可能还有嵌套列表/多段落
  var sawInline = false;
  final inlineRuns = <InlineRun>[];

  for (final child in li.nodes) {
    if (child is dom.Element) {
      final t = child.localName ?? '';
      if (t == 'ul' || t == 'ol') {
        if (inlineRuns.isNotEmpty) {
          ctx.blocks.add(
            _listItemBlock(inlineRuns, quoteDepth, marker, index, depth),
          );
          inlineRuns.clear();
          sawInline = false;
        }
        final isUl = t == 'ul';
        var i = 0;
        for (final sub in child.nodes) {
          if (sub is dom.Element && sub.localName == 'li') {
            if (isUl) {
              _walkListItem(
                sub,
                ctx,
                quoteDepth: quoteDepth,
                marker: -1,
                index: ++i,
                depth: depth + 1,
              );
            } else {
              _walkListItem(
                sub,
                ctx,
                quoteDepth: quoteDepth,
                marker: ++i,
                index: i,
                depth: depth + 1,
              );
            }
          }
        }
        continue;
      }
    }
    final runs = _inlineRuns(child);
    if (runs.any((r) => r.text.isNotEmpty || child is dom.Element)) {
      inlineRuns.addAll(runs);
      sawInline = true;
    }
  }
  if (sawInline && inlineRuns.isNotEmpty) {
    ctx.blocks.add(
      _listItemBlock(inlineRuns, quoteDepth, marker, index, depth),
    );
  }
}

Block _listItemBlock(
  List<InlineRun> runs,
  int quoteDepth,
  int marker,
  int index,
  int depth,
) {
  final merged = <InlineRun>[];
  if (depth > 0) {
    merged.add(InlineRun('  ' * depth));
  }
  for (final r in runs) {
    merged.add(r);
  }
  return Block(
    type: BlockType.listItem,
    spans: merged,
    listMarker: marker == -1 ? -1 : index,
    quoteDepth: quoteDepth,
  );
}

Block _paragraphOf(List<InlineRun> runs, int quoteDepth) =>
    Block(type: BlockType.paragraph, spans: runs, quoteDepth: quoteDepth);

/// `<a>` 是否为注标：epub:type="noteref" 或 class 含 noteref/fnref 标识。
/// 是则返回目标脚注 id（href 锚点，不含 #）；跨文件注标同样取其锚点，
/// 内容在阅读器侧全书范围解析。
String? _noterefTarget(dom.Element a) {
  final epubType =
      (a.attributes['epub:type'] ?? a.attributes['type'] ?? '').toLowerCase();
  final cls = (a.attributes['class'] ?? '').toLowerCase();
  final isNoteref =
      epubType.contains('noteref') ||
      cls.contains('noteref') ||
      cls.contains('fnref') ||
      cls.contains('footnote-ref') ||
      cls.contains('footnoteref');
  if (!isNoteref) return null;
  final href = a.attributes['href'] ?? '';
  final f = href.indexOf('#');
  if (f < 0) return null;
  final id = href.substring(f + 1).trim();
  return id.isEmpty ? null : id;
}

/// 脚注容器纯文本：块级子元素各占一行（多段落以 \n 连接），
/// 行内内容直接拼接。标签语义剥离，回链链接文本丢弃由纯文本合并承担。
String _footnoteText(dom.Element node) {
  final buf = StringBuffer();
  for (final child in node.nodes) {
    if (child is dom.Element &&
        _blockTags.contains(child.localName?.toLowerCase())) {
      final t = _inlineText(child).trim();
      if (t.isNotEmpty) buf.write('$t\n');
    } else if (child is dom.Text) {
      buf.write(child.text.replaceAll('\u00a0', ' '));
    }
  }
  return buf.toString().trim();
}

/// 递归提取行内文本（丢弃标签语义，保留文本）
String _inlineText(dom.Node node) {
  final buf = StringBuffer();
  void walk(dom.Node n) {
    if (n is dom.Text) {
      buf.write(n.text.replaceAll('\u00a0', ' '));
    } else if (n is dom.Element) {
      final tag = n.localName ?? '';
      if (tag == 'br') buf.write(' ');
      for (final c in n.nodes) {
        walk(c);
      }
    }
  }

  walk(node);
  return buf.toString();
}

/// 递归提取行内 runs：保留 ruby 注音（EPUB 振假名）与注标（noteref），
/// 其余行内标签样式降级为纯文本。
List<InlineRun> _inlineRuns(dom.Node node) {
  if (node is dom.Text) {
    final t = node.text.replaceAll('\u00a0', ' ');
    return t.isEmpty ? const [] : [InlineRun(t)];
  }
  if (node is! dom.Element) return const [];
  final tag = node.localName ?? '';
  if (tag == 'br') return const [InlineRun(' ')];
  if (tag == 'a') {
    // 注标：epub:type="noteref" 或 class 含 noteref/fnref 等
    final refId = _noterefTarget(node);
    if (refId != null) {
      final inner = <InlineRun>[];
      for (final c in node.nodes) {
        inner.addAll(_inlineRuns(c));
      }
      final marked = <InlineRun>[];
      for (final r in inner) {
        if (r.text.isEmpty) continue;
        marked.add(
          InlineRun(
            r.text,
            flags: {...r.flags, InlineFlag.noteref},
            ruby: r.ruby,
            refId: refId,
          ),
        );
      }
      // 空注标（标记由 CSS ::before 生成）：渲染占位符保证可点
      if (marked.isEmpty) {
        marked.add(InlineRun('*', flags: const {InlineFlag.noteref}, refId: refId));
      }
      return marked;
    }
  }
  if (tag == 'img' || tag == 'image') {
    final src =
        node.attributes['src'] ??
        node.attributes['xlink:href'] ??
        node.attributes['href'];
    return [InlineRun(src != null ? '［图］' : '')];
  }
  if (tag == 'ruby') {
    // <ruby>漢<rt>かん</rt></ruby>：base 文本 + rt 注音
    final base = StringBuffer();
    var rt = '';
    for (final c in node.nodes) {
      if (c is dom.Element) {
        final t = c.localName ?? '';
        if (t == 'rt') {
          rt += c.text;
          continue;
        }
        if (t == 'rp') continue; // 括号提示符丢弃
        if (t == 'rb') {
          base.write(c.text);
          continue;
        }
        // 嵌套行内（em/span 等）：递归取文本与注音
        final inner = _inlineRuns(c);
        for (final r in inner) {
          base.write(r.text);
          if (r.ruby != null) rt += r.ruby!;
        }
        continue;
      }
      if (c is dom.Text) {
        base.write(c.text);
      }
    }
    final baseText = base.toString().replaceAll('\u00a0', ' ');
    final rtText = rt.replaceAll('\u00a0', ' ').trim();
    if (baseText.isEmpty) return const [];
    if (rtText.isEmpty) return [InlineRun(baseText)];
    return [InlineRun(baseText, ruby: rtText)];
  }
  // 普通行内标签：递归展开子节点并合并
  final out = <InlineRun>[];
  for (final c in node.nodes) {
    out.addAll(_inlineRuns(c));
  }
  return out;
}

/// 解析相对路径，剥离锚点
String? _resolveSrc(String src) {
  if (src.startsWith('data:')) return null; // data URI 暂不支持
  final i = src.indexOf('#');
  return (i > 0 ? src.substring(0, i) : src).trim();
}
