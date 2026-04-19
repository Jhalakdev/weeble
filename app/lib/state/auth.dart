import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../api/client.dart';
import '../security/embedded_keys.dart';
import '../services/secure_storage.dart';

const _kTokenKey = 'weeber_token';
const _kAccountIdKey = 'weeber_account_id';

final apiProvider = Provider<WeeberApi>((ref) {
  return WeeberApi(baseUrl: EmbeddedSecrets.apiUrl);
});

final secureStorageProvider = Provider<SecureStorage>((_) => SecureStorage());

class AuthState {
  AuthState({this.token, this.accountId, this.plan, this.status});
  final String? token;
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
    final accountId = await _storage.read(key: _kAccountIdKey);
    if (token != null) {
      try {
        final s = await _api.billingStatus(token);
        state = AuthState(token: token, accountId: accountId, plan: s.plan, status: s.status);
      } on ApiException catch (e) {
        if (e.statusCode == 401) {
          await logout();
        }
      }
    }
  }

  Future<void> login(String email, String password) async {
    final r = await _api.login(email, password);
    await _storage.write(key: _kTokenKey, value: r.token);
    await _storage.write(key: _kAccountIdKey, value: r.accountId);
    state = AuthState(token: r.token, accountId: r.accountId, plan: r.plan, status: r.status);
  }

  Future<void> register(String email, String password) async {
    await _api.register(email, password);
    await login(email, password);
  }

  Future<void> logout() async {
    await _storage.delete(key: _kTokenKey);
    await _storage.delete(key: _kAccountIdKey);
    state = AuthState();
  }

  Future<void> replaceToken(String token) async {
    await _storage.write(key: _kTokenKey, value: token);
    state = AuthState(token: token, accountId: state.accountId, plan: state.plan, status: state.status);
  }
}

final authProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  return AuthNotifier(ref.watch(apiProvider), ref.watch(secureStorageProvider));
});
