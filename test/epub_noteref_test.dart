import 'package:flutter_test/flutter_test.dart';

import 'package:literead/engine/ir/book_document.dart';
import 'package:literead/engine/parsers/html_lite_converter.dart';

/// 角标注释（EPUB noteref）回归测试。
///
/// 书源结构（果青等日轻 EPUB 常见）：
/// - 注标：`<a class="duokan-footnote" epub:type="noteref" href="#n1">`
///   内嵌角标图片 `<img src="note.png">`（转换为 \uFFFC 占位 run）；
/// - 注释内容：`<aside epub:type="footnote" id="n1"><ol><li>…</li></ol></aside>`。
void main() {
  test('noteref 注标与 aside 脚注提取（duokan 结构）', () {
    const html = '''
<html><body>
  <p>比念成「JYO-KYOUSHI」还得性感<a class="duokan-footnote no-d"
     epub:type="noteref" href="#n1" id="A_1"><img alt="note"
     class="footnote" src="../Images/note.png" /></a>。</p>
  <aside epub:type="footnote" id="n1">
    <ol class="duokan-footnote-content">
      <li class="duokan-footnote-item" id="n1" value="1">日文中，前者念法较为强调性别。</li>
    </ol>
  </aside>
</body></html>
''';
    final footnotes = <String, Footnote>{};
    final blocks = HtmlLiteConverter().convert(html, footnotesOut: footnotes);

    // 脚注内容提取（aside > ol > li）
    expect(footnotes['n1']?.text, '日文中，前者念法较为强调性别。');

    // 注标 run：\uFFFC 占位 + refId
    final refs = <InlineRun>[];
    for (final b in blocks) {
      for (final r in b.spans) {
        if (r.hasNoteref) refs.add(r);
      }
    }
    expect(refs, hasLength(1));
    expect(refs.first.refId, 'n1');
    expect(refs.first.text, '\uFFFC');
  });

  test('注标点击命中：占位符右半边点击映射到后一字符时回退前一字符恢复 refId', () {
    // 复现阅读器 _onTapProbe 的命中逻辑：
    // inlineRunAt(char) ?? inlineRunAt(char - 1)
    const html = '''
<html><body>
  <p>ABC<a epub:type="noteref" href="#fn1"><img src="note.png" /></a>DEF</p>
  <aside epub:type="footnote" id="fn1">
    <ol><li>测试注释内容。</li></ol>
  </aside>
</body></html>
''';
    final footnotes = <String, Footnote>{};
    final blocks = HtmlLiteConverter().convert(html, footnotesOut: footnotes);
    final chapter = Chapter(
      id: 'c',
      title: 't',
      blocks: blocks,
      footnotes: footnotes,
    );

    // 定位占位符在章内扁平文本中的偏移
    var refOffset = -1;
    var plain = 0;
    for (final b in blocks) {
      var pos = 0;
      for (final r in b.spans) {
        if (r.hasNoteref) {
          refOffset = plain + pos;
        }
        pos += r.text.length;
      }
      plain += b.plainText.length + 1; // 块间 '\n'
    }
    expect(refOffset, greaterThanOrEqualTo(0));

    // 命中占位符本身 → 直接拿到 refId（图片左半边点击）
    expect(chapter.inlineRunAt(refOffset)?.refId, 'fn1');
    // 命中占位符之后一个字符（图片右半边点击）→ 直查为 null，
    // 回退 char-1 必须恢复 refId
    final next = chapter.inlineRunAt(refOffset + 1);
    if (next?.refId == null) {
      expect(chapter.inlineRunAt(refOffset + 1 - 1)?.refId, 'fn1');
    } else {
      expect(next?.refId, 'fn1');
    }
    // 脚注内容可由 refId 解析
    expect(footnotes['fn1'], isNotNull);
  });
}
