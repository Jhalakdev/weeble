import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../api/client.dart';
import '../security/embedded_keys.dart';
import '../services/secure_storage.dart';

const _kTokenKey = 'weeber_token';
const _kRefreshKey = 'weeber_refresh';
const _kAccountIdKey = 'weeber_account_id';

final apiProvider = Provider<WeeberApi>((ref) {
  return WeeberApi(baseUrl: EmbeddedSecrets.apiUrl);
});

final secureStorageProvider = Provider<SecureStorage>((_) => SecureStorage());

class AuthState {
  AuthState({this.token, this.refreshToken, this.accountId, this.plan, this.status});
  final String? token;          // short-lived access token (≤1 h)
  final String? refreshToken;   // rotating 90-day refresh (wr_…)
  final String? accountId;
  final String? plan;
  final String? status;

  bool get isLoggedIn => token != null;
}

class AuthNotifier extends StateNotifier<AuthState> {
  AuthNotifier(this._api, this._storage) : super(AuthState());

  final WeeberApi _api;
  final SecureStorage _storage;

  Future<void> bootstrap() async {
    final token = await _storage.read(key: _kTokenKey);
    final refresh = await _storage.read(key: _kRefreshKey);
    final accountId = await _storage.read(key: _kAccountIdKey);
    if (token == null) return;

    // Try the current access token first. If it's expired, fall back
    // to the refresh token before giving up and forcing re-login.
    try {
      final s = await _api.billingStatus(token);
      state = AuthState(
        token: token, refreshToken: refresh,
        accountId: accountId, plan: s.plan, status: s.status,
      );
      return;
    } on ApiException catch (e) {
      if (e.statusCode != 401) return;
    }

    if (refresh != null) {
      final fresh = await _api.refreshPair(refresh);
      if (fresh != null) {
        await _storage.write(key: _kTokenKey, value: fresh.accessToken);
        await _storage.write(key: _kRefreshKey, value: fresh.refreshToken);
        try {
          final s = await _api.billingStatus(fresh.accessToken);
          state = AuthState(
            token: fresh.accessToken, refreshToken: fresh.refreshToken,
            accountId: accountId, plan: s.plan, status: s.status,
          );
          return;
        } catch (_) { /* fall through to logout */ }
      }
    }
    await logout();
  }

  Future<void> login(String email, String password) async {
    final r = await _api.login(email, password);
    await _storage.write(key: _kTokenKey, value: r.token);
    if (r.refreshToken != null) {
      await _storage.write(key: _kRefreshKey, value: r.refreshToken!);
    }
    await _storage.write(key: _kAccountIdKey, value: r.accountId);
    state = AuthState(
      token: r.token, refreshToken: r.refreshToken,
      accountId: r.accountId, plan: r.plan, status: r.status,
    );
  }

  Future<void> register(String email, String password) async {
    await _api.register(email, password);
    await login(email, password);
  }

  Future<void> logout() async {
    // Best-effort server-side revoke so the refresh token can't be
    // reused even if it leaked. Network failure is non-fatal.
    final refresh = state.refreshToken ?? await _storage.read(key: _kRefreshKey);
    if (refresh != null) {
      // ignore: unawaited_futures
      _api.logout(refresh);
    }
    await _storage.delete(key: _kTokenKey);
    await _storage.delete(key: _kRefreshKey);
    await _storage.delete(key: _kAccountIdKey);
    state = AuthState();
  }

  Future<void> replaceToken(String token, {String? refreshToken}) async {
    await _storage.write(key: _kTokenKey, value: token);
    if (refreshToken != null) {
      await _storage.write(key: _kRefreshKey, value: refreshToken);
    }
    state = AuthState(
      token: token,
      refreshToken: refreshToken ?? state.refreshToken,
      accountId: state.accountId, plan: state.plan, status: state.status,
    );
  }

  /// Attempts an auto-refresh using the stored refresh token. Updates
  /// state + storage on success, returns the new access token.
  /// Returns null (and triggers logout) if refresh is rejected.
  Future<String?> refreshIfNeeded() async {
    final refresh = state.refreshToken ?? await _storage.read(key: _kRefreshKey);
    if (refresh == null) return null;
    final fresh = await _api.refreshPair(refresh);
    if (fresh == null) {
      await logout();
      return null;
    }
    await replaceToken(fresh.accessToken, refreshToken: fresh.refreshToken);
    return fresh.accessToken;
  }
}

final authProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  return AuthNotifier(ref.watch(apiProvider), ref.watch(secureStorageProvider));
});
