import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

part 'app_database.g.dart';

/// 书库表（计划书 §3.7）
class Books extends Table {
  /// sha256(文件内容)，天然去重 + 同步标识
  TextColumn get id => text()();

  TextColumn get title => text()();
  TextColumn get author => text().nullable()();
  TextColumn get language => text().nullable()();
  TextColumn get format => text()(); // EPUB|MOBI|AZW3|PDF|MD|TXT
  TextColumn get filePath => text()();
  IntColumn get fileSize => integer().nullable()();
  TextColumn get coverPath => text().nullable()();
  IntColumn get addedAt => integer()();
  IntColumn get lastReadAt => integer().nullable()();
  TextColumn get metaJson => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 阅读进度表
class Progress extends Table {
  TextColumn get bookId => text()();
  TextColumn get locatorJson => text()();
  RealColumn get percent => real()();
  IntColumn get updatedAt => integer()();
  TextColumn get deviceId => text().withDefault(const Constant('local'))();

  @override
  Set<Column> get primaryKey => {bookId};
}

/// 标注表（高亮/笔记）
class Highlights extends Table {
  TextColumn get id => text()();
  TextColumn get bookId => text()();
  TextColumn get locatorJson => text()();
  TextColumn get selectedText => text()();
  IntColumn get colorIndex => integer()();
  TextColumn get note => text().nullable()();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

/// 书签表
class Bookmarks extends Table {
  TextColumn get id => text()();
  TextColumn get bookId => text()();
  TextColumn get locatorJson => text()();
  TextColumn get title => text().nullable()();
  IntColumn get createdAt => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 书籍标签
class BookTags extends Table {
  TextColumn get bookId => text()();
  TextColumn get tag => text()();

  @override
  Set<Column> get primaryKey => {bookId, tag};
}

/// 设置键值表
class SettingsKv extends Table {
  TextColumn get key => text()();
  TextColumn get valueJson => text()();

  @override
  Set<Column> get primaryKey => {key};
}

@DriftDatabase(
  tables: [Books, Progress, Highlights, Bookmarks, BookTags, SettingsKv],
)
class AppDatabase extends _$AppDatabase {
  /// [executor] 供测试注入内存数据库；生产环境用应用支持目录
  AppDatabase({QueryExecutor? executor}) : super(executor ?? _open());

  @override
  int get schemaVersion => 1;

  static QueryExecutor _open() {
    return driftDatabase(
      name: 'literead',
      native: const DriftNativeOptions(
        databaseDirectory: getApplicationSupportDirectory,
      ),
    );
  }

  /// 设置读写
  Future<String?> getSetting(String key) async {
    final row = await (select(
      settingsKv,
    )..where((t) => t.key.equals(key))).getSingleOrNull();
    return row?.valueJson;
  }

  Future<void> setSetting(String key, String valueJson) async {
    await into(settingsKv).insertOnConflictUpdate(
      SettingsKvCompanion.insert(key: key, valueJson: valueJson),
    );
  }
}

/// 应用文件目录布局：
///   `library/<id>.<ext>` 书籍文件托管副本
///   `covers/<id>.png`    封面
class AppDirs {
  static Directory? _root;

  static Future<Directory> root() async {
    if (_root != null) return _root!;
    final support = await getApplicationSupportDirectory();
    _root = Directory(p.join(support.path, 'literead'));
    await _root!.create(recursive: true);
    return _root!;
  }

  static Future<Directory> library() async =>
      (await root()).createSub('library');

  static Future<Directory> covers() async => (await root()).createSub('covers');
}

extension on Directory {
  Future<Directory> createSub(String name) async {
    final d = Directory(p.join(path, name));
    await d.create(recursive: true);
    return d;
  }
}
