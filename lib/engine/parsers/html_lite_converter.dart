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
    for (final node in body.nodes) {
      _walkBlock(node, ctx, quoteDepth: 0);
    }
    return ctx.blocks;
  }

  List<Block> convertDocument(dom.Document doc) {
    final body = doc.body;
    if (body == null) return const [];
    final ctx = _Ctx();
    for (final node in body.nodes) {
      _walkBlock(node, ctx, quoteDepth: 0);
    }
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

void _walkBlock(
  dom.Node node,
  _Ctx ctx, {
  required int quoteDepth,
  int listDepth = 0,
}) {
  if (node is dom.Text) {
    final text = node.text.replaceAll('\u00a0', ' ').trim();
    if (text.isNotEmpty) {
      ctx.blocks.add(_paragraphOf([InlineRun(text)], 0));
    }
    return;
  }
  if (node is! dom.Element) return;

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
      for (final child in node.nodes) {
        _walkBlock(child, ctx, quoteDepth: quoteDepth + 1);
      }
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
      for (final child in node.nodes) {
        _walkBlock(child, ctx, quoteDepth: quoteDepth, listDepth: listDepth);
      }
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
    for (final child in node.nodes) {
      _walkBlock(child, ctx, quoteDepth: quoteDepth, listDepth: listDepth);
    }
    return;
  }

  // 行内标签包裹的直接文本（如 <a><p>…）兜底
  final text = _inlineText(node);
  if (text.trim().isNotEmpty) {
    ctx.blocks.add(_paragraphOf([InlineRun(text)], quoteDepth));
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
    final run = _walkInline(child);
    if (run.text.isNotEmpty || child is dom.Element) {
      inlineRuns.add(run);
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

InlineRun _walkInline(dom.Node node) {
  if (node is dom.Text) {
    return InlineRun(node.text.replaceAll('\u00a0', ' '));
  }
  if (node is! dom.Element) return const InlineRun('');
  final tag = node.localName ?? '';
  if (tag == 'br') return const InlineRun(' ');
  if (tag == 'img' || tag == 'image') {
    final src =
        node.attributes['src'] ??
        node.attributes['xlink:href'] ??
        node.attributes['href'];
    return InlineRun(src != null ? '［图］' : '');
  }
  // 嵌套行内标签，取全部文本（样式降级）
  return InlineRun(_inlineText(node));
}

/// 解析相对路径，剥离锚点
String? _resolveSrc(String src) {
  if (src.startsWith('data:')) return null; // data URI 暂不支持
  final i = src.indexOf('#');
  return (i > 0 ? src.substring(0, i) : src).trim();
}
