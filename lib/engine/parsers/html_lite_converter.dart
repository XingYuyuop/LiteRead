import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../ir/book_document.dart';

/// HTML → HTML-lite（白名单降级，计划书 §3.3）。
///
/// 只保留 p/h1-h6/img/em/strong/b/i/blockquote/ul/ol/li/pre/code/hr/br/a
/// 等语义标签；其余降级为纯文本。CSS 颜色一律丢弃，映射到当前主题。
class HtmlLiteConverter {
  const HtmlLiteConverter();

  /// 解析 HTML 字符串并提取块序列
  List<Block> convert(String html) {
    final doc = html_parser.parse(utf8.decode(utf8.encode(html)));
    final body = doc.body;
    if (body == null) return const [];
    final ctx = _Ctx();
    _walkChildren(body.nodes, ctx, quoteDepth: 0);
    return ctx.blocks;
  }

  List<Block> convertDocument(dom.Document doc) {
    final body = doc.body;
    if (body == null) return const [];
    final ctx = _Ctx();
    _walkChildren(body.nodes, ctx, quoteDepth: 0);
    return ctx.blocks;
  }
}

class _Ctx {
  final List<Block> blocks = [];
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
      runs.add(InlineRun(t, flags: f.flags, ruby: f.ruby));
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
      _walkBlock(child, ctx, quoteDepth: quoteDepth, listDepth: listDepth);
    } else {
      pending.addAll(_inlineRuns(child));
    }
  }
  flush();
}

void _walkBlock(
  dom.Element node,
  _Ctx ctx, {
  required int quoteDepth,
  int listDepth = 0,
}) {
  final tag = node.localName?.toLowerCase() ?? '';

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

/// 递归提取行内 runs：保留 ruby 注音（EPUB 振假名），
/// 其余行内标签样式降级为纯文本。
List<InlineRun> _inlineRuns(dom.Node node) {
  if (node is dom.Text) {
    final t = node.text.replaceAll('\u00a0', ' ');
    return t.isEmpty ? const [] : [InlineRun(t)];
  }
  if (node is! dom.Element) return const [];
  final tag = node.localName ?? '';
  if (tag == 'br') return const [InlineRun(' ')];
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
