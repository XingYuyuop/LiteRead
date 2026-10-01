import 'package:markdown/markdown.dart' as md;

import '../ir/book_document.dart';
import 'html_lite_converter.dart';

/// Markdown 解析器（计划书 §3.5.2）。
///
/// CommonMark + GFM（表格/任务列表/删除线）→ HTML → 复用 HTML-lite 管线，
/// 从此 MD 与 EPUB 共用全部排版/主题/标注能力。
class MdParser {
  const MdParser();

  static final _document = md.Document(
    extensionSet: md.ExtensionSet.gitHubFlavored,
  );

  Future<MdParseResult> parse(String source, {String title = ''}) async {
    final html = md.markdownToHtml(
      source,
      blockSyntaxes: _document.blockSyntaxes,
      inlineSyntaxes: _document.inlineSyntaxes,
      extensionSet: md.ExtensionSet.gitHubFlavored,
    );
    final blocks = const HtmlLiteConverter().convert(html);

    // 标题：显式指定 > 第一个 h1 > "未命名"
    String docTitle = title;
    if (docTitle.isEmpty) {
      for (final b in blocks) {
        if (b.type == BlockType.heading && b.headingLevel == 1) {
          docTitle = b.plainText;
          break;
        }
      }
    }

    // 目录：所有标题
    final toc = <TocEntry>[];
    var charOffset = 0;
    for (final b in blocks) {
      if (b.type == BlockType.heading) {
        toc.add(
          TocEntry(
            title: b.plainText,
            spineIndex: 0,
            charOffset: charOffset,
            depth: b.headingLevel - 1,
          ),
        );
      }
      charOffset += b.plainText.length + 1;
    }

    final doc = BookDocument(
      meta: BookMeta(title: docTitle.isEmpty ? '未命名文档' : docTitle),
      spine: [Chapter(id: 'md', title: docTitle, blocks: blocks)],
      toc: toc.isEmpty ? [const TocEntry(title: '正文', spineIndex: 0)] : toc,
      resources: ResourceStore((_) async => null),
    );
    return MdParseResult(document: doc);
  }
}

class MdParseResult {
  const MdParseResult({required this.document});

  final BookDocument document;
}
