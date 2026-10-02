import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../api/models.dart';
import 'changes.dart';

abstract interface class ChecklistCache {
  Future<String?> read();

  Future<void> write(String data);

  Future<void> clear();
}

class DeviceChecklistCache implements ChecklistCache {
  static const _key = 'checklist';

  final _prefs = SharedPreferencesAsync();

  @override
  Future<String?> read() => _prefs.getString(_key);

  @override
  Future<void> write(String data) => _prefs.setString(_key, data);

  @override
  Future<void> clear() => _prefs.remove(_key);
}

class CachedChecklist {
  const CachedChecklist({
    required this.server,
    required this.snapshot,
    required this.pending,
    required this.nextTempId,
    this.previews = const {},
  });

  // 2 added the category order and the previews; 1 still decodes, so an
  // upgrade keeps unsent changes. The deleted items, a delete's time and a
  // create's key kept 2: they are optional on decode, so a 2 without them
  // still reads.
  static const _version = 2;

  /// The base URL the data belongs to.
  final String server;

  /// Null until the first fetch succeeds.
  final Snapshot? snapshot;

  /// Oldest first.
  final List<Change> pending;
  final int nextTempId;

  /// By link.
  final Map<String, Preview> previews;

  String encode() => jsonEncode({
    'version': _version,
    'server': server,
    'snapshot': snapshot?.toJson(),
    'previews': {
      for (final MapEntry(:key, :value) in previews.entries)
        key: value.toJson(),
    },
    'pending': [for (final change in pending) change.toJson()],
    'next_temp_id': nextTempId,
  });

  /// Null for anything [encode] of this or an earlier version didn't write.
  static CachedChecklist? decode(String data) {
    try {
      final json = jsonDecode(data) as Map<String, dynamic>;
      final version = json['version'];
      if (version is! int || version < 1 || version > _version) return null;
      final snapshot = json['snapshot'] as Map<String, dynamic>?;
      final previews = json['previews'] as Map<String, dynamic>? ?? const {};
      return CachedChecklist(
        server: json['server'] as String,
        snapshot: snapshot == null ? null : Snapshot.fromJson(snapshot),
        pending: [
          for (final change in json['pending'] as List)
            Change.fromJson(change as Map<String, dynamic>),
        ],
        nextTempId: json['next_temp_id'] as int,
        previews: {
          for (final MapEntry(:key, :value) in previews.entries)
            key: Preview.fromJson(value as Map<String, dynamic>),
        },
      );
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }
}
