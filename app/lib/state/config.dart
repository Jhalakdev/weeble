import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Persistent app configuration. Stored as a single JSON file in the app
/// support directory. Anything secret (JWT, encryption key) lives in
/// flutter_secure_storage instead — never in this file.
class AppConfig {
  AppConfig({
    this.deviceId,
    this.storagePath,
    this.allocatedBytes,
    this.encryptionEnabled = false,
    this.onboardingComplete = false,
  });

  final String? deviceId;
  final String? storagePath;
  final int? allocatedBytes;
  final bool encryptionEnabled;
  final bool onboardingComplete;

  AppConfig copyWith({
    String? deviceId,
    String? storagePath,
    int? allocatedBytes,
    bool? encryptionEnabled,
    bool? onboardingComplete,
  }) {
    return AppConfig(
      deviceId: deviceId ?? this.deviceId,
      storagePath: storagePath ?? this.storagePath,
      allocatedBytes: allocatedBytes ?? this.allocatedBytes,
      encryptionEnabled: encryptionEnabled ?? this.encryptionEnabled,
      onboardingComplete: onboardingComplete ?? this.onboardingComplete,
    );
  }

  Map<String, dynamic> toJson() => {
        'device_id': deviceId,
        'storage_path': storagePath,
        'allocated_bytes': allocatedBytes,
        'encryption_enabled': encryptionEnabled,
        'onboarding_complete': onboardingComplete,
      };

  factory AppConfig.fromJson(Map<String, dynamic> json) => AppConfig(
        deviceId: json['device_id'] as String?,
        storagePath: json['storage_path'] as String?,
        allocatedBytes: (json['allocated_bytes'] as num?)?.toInt(),
        encryptionEnabled: json['encryption_enabled'] as bool? ?? false,
        onboardingComplete: json['onboarding_complete'] as bool? ?? false,
      );
}

class AppConfigStore {
  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File(p.join(dir.path, 'config.json'));
  }

  static Future<AppConfig> load() async {
    final f = await _file();
    if (!await f.exists()) return AppConfig();
    try {
      final raw = await f.readAsString();
      return AppConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      // Corrupt config — start fresh rather than crash.
      return AppConfig();
    }
  }

  static Future<void> save(AppConfig cfg) async {
    final f = await _file();
    await f.parent.create(recursive: true);
    await f.writeAsString(jsonEncode(cfg.toJson()));
  }
}

class AppConfigNotifier extends StateNotifier<AppConfig> {
  AppConfigNotifier() : super(AppConfig());

  Future<void> load() async {
    state = await AppConfigStore.load();
  }

  Future<void> update(AppConfig Function(AppConfig) f) async {
    state = f(state);
    await AppConfigStore.save(state);
  }
}

final appConfigProvider = StateNotifierProvider<AppConfigNotifier, AppConfig>((ref) {
  return AppConfigNotifier();
});
