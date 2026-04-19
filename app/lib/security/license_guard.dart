import 'dart:async';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import '../api/client.dart';
import '../state/auth.dart';
import 'embedded_keys.dart';
import 'fingerprint.dart';
import 'receipt.dart';

/// State of the local license guard.
enum LicenseStatus {
  /// Guard hasn't run yet (app is still bootstrapping).
  unknown,

  /// Verified, valid receipt cached. App can be used.
  active,

  /// No receipt cached. Need to call activate().
  needsActivation,

  /// Receipt failed verification (tampered / expired / fingerprint mismatch).
  /// App must re-activate from scratch.
  invalid,

  /// Server told us the license is revoked or abuse-flagged. App is dead.
  revoked,

  /// Couldn't reach the server. We allow a short grace window before forcing revoked.
  offline,
}

class LicenseState {
  LicenseState({required this.status, this.receipt, this.message});
  final LicenseStatus status;
  final ReceiptPayload? receipt;
  final String? message;
}

class LicenseGuard extends StateNotifier<LicenseState> {
  LicenseGuard({
    required this.api,
    required this.store,
    required this.authNotifier,
  }) : super(LicenseState(status: LicenseStatus.unknown));

  final WeeberApi api;
  final ReceiptStore store;
  final AuthNotifier authNotifier;

  Timer? _heartbeatTimer;

  /// Called from app bootstrap. Verifies any cached receipt; if absent or
  /// invalid, attempts a fresh activation against the server.
  Future<void> bootstrap() async {
    final fp = await HardwareFingerprint.compute();
    final cached = await store.load();
    if (cached != null) {
      try {
        final p = await store.verify(cached, expectedFingerprint: fp);
        state = LicenseState(status: LicenseStatus.active, receipt: p);
        if (p.nearExpiry) {
          await heartbeat();
        }
        _scheduleHeartbeat(p.expiresAt);
        return;
      } on ReceiptVerificationException catch (e) {
        // Clear the corrupt receipt and fall through to re-activate. Don't
        // hard-block the user — we can recover.
        await store.clear();
        // Remember the failure reason for telemetry but don't set state
        // to invalid yet — the activate() below may succeed fresh.
        // If it doesn't, activate() will set the appropriate state.
        // ignore: avoid_print
        print('[license] stored receipt failed verify: ${e.reason} — re-activating');
      }
    }
    // No (or cleared) receipt → try to activate if we already have an
    // authenticated session. If the user hasn't registered a device yet
    // (no_device_binding), that's a "needs onboarding" state, not an
    // "invalid license" state — do NOT block them from reaching onboarding.
    if (authNotifier.state.token != null) {
      await activate();
    } else {
      state = LicenseState(status: LicenseStatus.needsActivation);
    }
  }

  Future<void> activate() async {
    final token = authNotifier.state.token;
    if (token == null) {
      state = LicenseState(status: LicenseStatus.needsActivation);
      return;
    }
    final fp = await HardwareFingerprint.compute();
    try {
      final res = await _post('/v1/licenses/activate', token: token, body: {
        'hardware_fingerprint': fp,
        'platform': HardwareFingerprint.platform,
      });
      final receipt = res['receipt'] as String;
      final payload = await store.verify(receipt, expectedFingerprint: fp);
      await store.save(receipt);
      state = LicenseState(status: LicenseStatus.active, receipt: payload);
      _scheduleHeartbeat(payload.expiresAt);
    } on _ApiError catch (e) {
      // The ONLY statuses that hard-block the user are explicit server signals
      // that the license is bad. Every other error (network, expired JWT,
      // device not yet registered, receipt briefly failed to verify) is
      // recoverable — set needsActivation and let the UI keep working.
      if (e.code == 'abuse_detected' || e.code == 'license_revoked') {
        state = LicenseState(status: LicenseStatus.revoked, message: e.code);
      } else {
        state = LicenseState(status: LicenseStatus.needsActivation, message: e.code);
      }
    } on ReceiptVerificationException catch (e) {
      // Server returned a receipt that doesn't verify against our embedded
      // pubkey. Previously we treated this as "invalid" and locked the user
      // out — but in practice it's usually a transient sync issue (e.g. we
      // wiped the server key during dev). Fall back to needsActivation so
      // the app stays usable.
      state = LicenseState(status: LicenseStatus.needsActivation, message: 'server_not_trusted:${e.reason}');
    } catch (_) {
      state = LicenseState(status: LicenseStatus.offline);
    }
  }

  Future<void> heartbeat() async {
    final token = authNotifier.state.token;
    final cached = await store.load();
    if (token == null || cached == null) return;
    final fp = await HardwareFingerprint.compute();
    try {
      final res = await _post('/v1/licenses/heartbeat', token: token, body: {
        'receipt': cached,
        'hardware_fingerprint': fp,
      });
      final receipt = res['receipt'] as String;
      final payload = await store.verify(receipt, expectedFingerprint: fp);
      await store.save(receipt);
      state = LicenseState(status: LicenseStatus.active, receipt: payload);
      _scheduleHeartbeat(payload.expiresAt);
    } on _ApiError catch (e) {
      if (e.code == 'revoked' || e.code == 'license_revoked' || e.code == 'fingerprint_mismatch') {
        await store.clear();
        state = LicenseState(status: LicenseStatus.revoked, message: e.code);
      } else if (e.code == 'invalid_receipt') {
        await store.clear();
        state = LicenseState(status: LicenseStatus.invalid, message: e.code);
      }
      // Other errors → leave state alone, treat as offline.
    } catch (_) {
      // Offline. Don't kill the app — but if expired and offline, we will block.
      final p = state.receipt;
      if (p != null && p.isExpired) {
        state = LicenseState(status: LicenseStatus.offline, receipt: p);
      }
    }
  }

  void _scheduleHeartbeat(DateTime expiresAt) {
    _heartbeatTimer?.cancel();
    final wait = expiresAt.subtract(const Duration(hours: 6)).difference(DateTime.now());
    final delay = wait.isNegative ? const Duration(minutes: 1) : wait;
    _heartbeatTimer = Timer(delay, heartbeat);
  }

  @override
  void dispose() {
    _heartbeatTimer?.cancel();
    super.dispose();
  }

  // Inline POST helper instead of using the WeeberApi (which doesn't know
  // about license endpoints). Centralised here so all license traffic
  // goes through the same place — handy if we add cert pinning here later.
  Future<Map<String, dynamic>> _post(String path, {required String token, required Map<String, dynamic> body}) async {
    final res = await http.post(
      Uri.parse('${EmbeddedSecrets.apiUrl}$path'),
      headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $token'},
      body: jsonEncode(body),
    );
    final decoded = res.body.isEmpty ? <String, dynamic>{} : jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode >= 400) {
      throw _ApiError(decoded['error']?.toString() ?? 'http_${res.statusCode}', res.statusCode);
    }
    return decoded;
  }
}

class _ApiError implements Exception {
  _ApiError(this.code, this.statusCode);
  final String code;
  final int statusCode;
}

final receiptStoreProvider = Provider<ReceiptStore>((ref) {
  return ReceiptStore(ref.watch(secureStorageProvider));
});

final licenseGuardProvider = StateNotifierProvider<LicenseGuard, LicenseState>((ref) {
  return LicenseGuard(
    api: ref.watch(apiProvider),
    store: ref.watch(receiptStoreProvider),
    authNotifier: ref.watch(authProvider.notifier),
  );
});
