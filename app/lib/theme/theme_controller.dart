import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum WeeberThemeMode { light, dark, system }

class ThemeController extends StateNotifier<WeeberThemeMode> {
  ThemeController() : super(WeeberThemeMode.system);
  static const _key = 'weeber_theme_mode';

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    final v = p.getString(_key);
    state = switch (v) {
      'light' => WeeberThemeMode.light,
      'dark' => WeeberThemeMode.dark,
      _ => WeeberThemeMode.system,
    };
  }

  Future<void> setMode(WeeberThemeMode mode) async {
    state = mode;
    final p = await SharedPreferences.getInstance();
    await p.setString(_key, mode.name);
  }

  ThemeMode get materialMode => switch (state) {
        WeeberThemeMode.light => ThemeMode.light,
        WeeberThemeMode.dark => ThemeMode.dark,
        WeeberThemeMode.system => ThemeMode.system,
      };
}

final themeControllerProvider = StateNotifierProvider<ThemeController, WeeberThemeMode>((ref) {
  return ThemeController();
});
