import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class FileEntry {
  FileEntry({
    required this.id,
    required this.name,
    required this.parentId,
    required this.size,
    required this.mime,
    required this.createdAt,
    this.deletedAt,
  });

  final String id;
  final String name;
  final String? parentId;
  final int size;
  final String mime;
  final int createdAt;
  final int? deletedAt;

  bool get isFolder => mime == 'inode/directory';

  Map<String, Object?> toMap() => {
        'id': id,
        'name': name,
        'parent_id': parentId,
        'size': size,
        'mime': mime,
        'created_at': createdAt,
        'deleted_at': deletedAt,
      };

  factory FileEntry.fromMap(Map<String, Object?> m) => FileEntry(
        id: m['id'] as String,
        name: m['name'] as String,
        parentId: m['parent_id'] as String?,
        size: (m['size'] as int?) ?? 0,
        mime: (m['mime'] as String?) ?? 'application/octet-stream',
        createdAt: m['created_at'] as int,
        deletedAt: m['deleted_at'] as int?,
      );
}

/// SQLite-backed index of files stored under the host's storage root.
/// Lives at <storageRoot>/.weeber.db.
class FileIndex {
  FileIndex._(this._db);
  final Database _db;

  static Future<FileIndex> open(String storageRoot) async {
    if (Platform.isWindows || Platform.isLinux) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    final dbPath = p.join(storageRoot, '.weeber.db');
    final db = await openDatabase(
      dbPath,
      version: 2,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE files (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            parent_id TEXT,
            size INTEGER NOT NULL,
            mime TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            deleted_at INTEGER
          )
        ''');
        await db.execute('CREATE INDEX idx_files_parent ON files(parent_id, deleted_at)');
        await db.execute('''
          CREATE TABLE storage_history (
            day INTEGER PRIMARY KEY,
            used_bytes INTEGER NOT NULL
          )
        ''');
      },
      onUpgrade: (db, from, to) async {
        if (from < 2) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS storage_history (
              day INTEGER PRIMARY KEY,
              used_bytes INTEGER NOT NULL
            )
          ''');
        }
      },
    );
    return FileIndex._(db);
  }

  /// Records today's used-bytes total. Idempotent per UTC day — calling it
  /// twice in the same day just overwrites the previous value with the
  /// latest. Cheap (single SUM + single UPSERT).
  Future<void> recordStorageSnapshot() async {
    final used = await totalSize();
    final today = _utcDayKey(DateTime.now());
    await _db.insert(
      'storage_history',
      {'day': today, 'used_bytes': used},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Returns at most [days] of history, most recent first. Each entry is
  /// `{day: <YYYYMMDD as int>, used_bytes: <int>}`.
  Future<List<Map<String, Object?>>> storageHistory({int days = 30}) async {
    final rows = await _db.query(
      'storage_history',
      orderBy: 'day DESC',
      limit: days,
    );
    return rows;
  }

  static int _utcDayKey(DateTime t) {
    final u = t.toUtc();
    return u.year * 10000 + u.month * 100 + u.day;
  }

  Future<void> insert(FileEntry e) async {
    await _db.insert('files', e.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<FileEntry?> get(String id) async {
    final rows = await _db.query('files', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : FileEntry.fromMap(rows.first);
  }

  Future<List<FileEntry>> list({String? parentId, bool includeDeleted = false}) async {
    final where = StringBuffer(parentId == null ? 'parent_id IS NULL' : 'parent_id = ?');
    final args = <Object?>[];
    if (parentId != null) args.add(parentId);
    if (!includeDeleted) where.write(' AND deleted_at IS NULL');
    final rows = await _db.query('files', where: where.toString(), whereArgs: args, orderBy: 'name COLLATE NOCASE');
    return rows.map(FileEntry.fromMap).toList();
  }

  Future<void> rename(String id, String newName) async {
    await _db.update('files', {'name': newName}, where: 'id = ?', whereArgs: [id]);
  }

  /// Soft-delete: marks [id] as deleted at the current time. Hard-delete of
  /// the underlying blob happens elsewhere.
  Future<void> softDelete(String id, {required int at}) async {
    await _db.update('files', {'deleted_at': at}, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> hardDelete(String id) async {
    await _db.delete('files', where: 'id = ?', whereArgs: [id]);
  }

  /// Bring a soft-deleted file back to the live list (Trash → My Drive).
  /// Note: only the index row is restored. The encrypted blob may already
  /// be gone from FileStorage if delete() ran — caller should handle that.
  Future<void> restore(String id) async {
    await _db.update('files', {'deleted_at': null}, where: 'id = ?', whereArgs: [id]);
  }

  Future<int> totalSize() async {
    final r = await _db.rawQuery('SELECT COALESCE(SUM(size), 0) AS total FROM files WHERE deleted_at IS NULL');
    return (r.first['total'] as int?) ?? 0;
  }

  Future<void> close() async => _db.close();
}
