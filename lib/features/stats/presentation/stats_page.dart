import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../library/data/book_repository.dart';

/// 阅读统计页（t5）：今日 / 本周 / 总时长 + 按书籍分类明细
class StatsPage extends ConsumerStatefulWidget {
  const StatsPage({super.key});

  @override
  ConsumerState<StatsPage> createState() => _StatsPageState();
}

enum _Range { today, week, all }

class _StatsPageState extends ConsumerState<StatsPage> {
  _Range _range = _Range.week;
  List<ReadingStatRow> _rows = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final repo = ref.read(bookRepositoryProvider);
    String? fromDay;
    final today = DateTime.now();
    switch (_range) {
      case _Range.today:
        fromDay = BookRepository.dayOf(today);
        break;
      case _Range.week:
        fromDay = BookRepository.dayOf(today.subtract(const Duration(days: 6)));
        break;
      case _Range.all:
        fromDay = null;
        break;
    }
    final rows = await repo.readingStats(fromDay: fromDay);
    if (!mounted) return;
    setState(() {
      _rows = rows;
      _loading = false;
    });
  }

  int get _totalSeconds => _rows.fold(0, (a, b) => a + b.seconds);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('阅读统计')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                // 总览卡片
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: cs.primary.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    children: [
                      Icon(
                        Icons.timer_outlined,
                        size: 32,
                        color: cs.primary,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        formatDuration(_totalSeconds),
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w700,
                          color: cs.primary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        switch (_range) {
                          _Range.today => '今日阅读时长',
                          _Range.week => '近 7 天阅读时长',
                          _Range.all => '累计阅读时长',
                        },
                        style: TextStyle(fontSize: 12, color: cs.outline),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                // 范围切换
                SegmentedButton<_Range>(
                  segments: const [
                    ButtonSegment(value: _Range.today, label: Text('今日')),
                    ButtonSegment(value: _Range.week, label: Text('本周')),
                    ButtonSegment(value: _Range.all, label: Text('全部')),
                  ],
                  selected: {_range},
                  onSelectionChanged: (s) {
                    setState(() => _range = s.first);
                    _load();
                  },
                ),
                const SizedBox(height: 16),
                // 按书籍分类
                if (_rows.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 48),
                    child: Column(
                      children: [
                        Icon(
                          Icons.menu_book_outlined,
                          size: 48,
                          color: cs.outline.withValues(alpha: 0.5),
                        ),
                        const SizedBox(height: 12),
                        Text('还没有阅读记录', style: TextStyle(color: cs.outline)),
                      ],
                    ),
                  )
                else
                  ..._rows.map((r) {
                    final frac = _totalSeconds > 0
                        ? r.seconds / _totalSeconds
                        : 0.0;
                    return Card(
                      elevation: 0,
                      margin: const EdgeInsets.only(bottom: 10),
                      color: cs.surfaceContainerHighest.withValues(alpha: 0.4),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    r.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  formatDuration(r.seconds),
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: cs.primary,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            // 占比条
                            ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: LinearProgressIndicator(
                                value: frac,
                                minHeight: 5,
                                backgroundColor: cs.outline.withValues(
                                  alpha: 0.15,
                                ),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '占比 ${(frac * 100).toStringAsFixed(0)}%',
                              style: TextStyle(
                                fontSize: 11,
                                color: cs.outline,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }),
              ],
            ),
    );
  }
}
