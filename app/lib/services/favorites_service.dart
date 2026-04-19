import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Per-device favorites list (file IDs the user has starred).
///
/// Local-only for v1 — no backend column. Each device has its own
/// favorites because the use case is "files I want quick access to from
/// THIS phone/computer", not a synced collection. Backed by
/// SharedPreferences so it survives app restart.
///
/// If we later want cross-device sync, add a `favorited_at` column on
/// the host's FileIndex and a /v1/relay/files/:id/favorite endpoint —
/// the in-memory `_ids` set just becomes a cache layer.
class FavoritesService {
  FavoritesService();

  static const _prefsKey = 'weeber.favorites.v1';
  Set<String>? _ids;

  Future<Set<String>> _load() async {
    if (_ids != null) return _ids!;
    final prefs = await SharedPreferences.getInstance();
    _ids = (prefs.getStringList(_prefsKey) ?? []).toSet();
    return _ids!;
  }

  Future<bool> isFavorite(String fileId) async {
    final s = await _load();
    return s.contains(fileId);
  }

  Future<Set<String>> all() => _load();

  Future<void> add(String fileId) async {
    final s = await _load();
    if (s.add(fileId)) await _save();
  }

  Future<void> remove(String fileId) async {
    final s = await _load();
    if (s.remove(fileId)) await _save();
  }

  Future<void> toggle(String fileId) async {
    final s = await _load();
    if (s.contains(fileId)) {
      s.remove(fileId);
    } else {
      s.add(fileId);
    }
    await _save();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_prefsKey, (_ids ?? {}).toList());
  }
}

final favoritesServiceProvider = Provider<FavoritesService>((_) => FavoritesService());
