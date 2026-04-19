import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../api/client.dart';
import 'auth.dart';
import 'config.dart';

/// State of *this device's* role on its account.
enum HostRole {
  /// We're not the active host (or we're a client device).
  notHost,

  /// We are the active host for this account.
  active,

  /// We were the host, but another machine took over. UI should offer
  /// "Take it back" → call takeOver().
  demoted,

  /// We tried to register but the server hasn't responded yet.
  unknown,
}

class HostRoleState {
  HostRoleState({required this.role, this.activeHostDeviceId, this.lastError});
  final HostRole role;
  final String? activeHostDeviceId;
  final String? lastError;
}

class HostRoleNotifier extends StateNotifier<HostRoleState> {
  HostRoleNotifier({required this.api, required this.authNotifier, required this.cfgNotifier})
      : super(HostRoleState(role: HostRole.unknown));

  final WeeberApi api;
  final AuthNotifier authNotifier;
  final AppConfigNotifier cfgNotifier;
  Timer? _heartbeatTimer;

  /// Announce ourselves to the registry. If [takeOver] is false (default), and
  /// another host is already active, we get demoted and we set state accordingly.
  /// Pass [takeOver]=true when the user explicitly clicks "make this machine my server".
  Future<void> announce({
    required String publicIp,
    required int port,
    required String reachability,
    required String certFingerprint,
    bool takeOver = false,
  }) async {
    final token = authNotifier.state.token;
    if (token == null) return;
    try {
      await api.announce(
        token: token,
        publicIp: publicIp,
        port: port,
        reachability: reachability,
        certFingerprint: certFingerprint,
        takeOver: takeOver,
      );
      state = HostRoleState(role: HostRole.active, activeHostDeviceId: cfgNotifier.state.deviceId);
    } on ApiException catch (e) {
      if (e.code == 'not_active_host') {
        state = HostRoleState(role: HostRole.demoted, lastError: e.code);
      } else {
        state = HostRoleState(role: HostRole.notHost, lastError: e.code);
      }
    }
  }

  /// Set the role without calling the server. Used by the bootstrap path to
  /// say "we know another device on this account is the active host, so
  /// don't even start HostLifecycle on this machine — run as a client."
  /// No network call: the source of truth is GET /v1/accounts/me/active-host
  /// which the caller has already checked.
  void setClientOnly({String? activeHostDeviceId}) {
    state = HostRoleState(role: HostRole.notHost, activeHostDeviceId: activeHostDeviceId);
  }

  /// Same idea — caller has already verified that we ARE the active host
  /// (or there is no active host yet and we're going to claim it).
  void setActive() {
    state = HostRoleState(role: HostRole.active, activeHostDeviceId: cfgNotifier.state.deviceId);
  }

  /// We were the active host but the server says someone else is now.
  /// Used when /v1/accounts/me/active-host returns a different device_id
  /// at bootstrap (= we got demoted while we were offline).
  void setDemoted({required String otherDeviceId}) {
    state = HostRoleState(role: HostRole.demoted, activeHostDeviceId: otherDeviceId);
  }

  /// Convenience: re-announce with takeOver=true. Called when user clicks the
  /// "Take it back" button on the demoted screen.
  Future<void> takeOver({
    required String publicIp,
    required int port,
    required String reachability,
    required String certFingerprint,
  }) {
    return announce(
      publicIp: publicIp,
      port: port,
      reachability: reachability,
      certFingerprint: certFingerprint,
      takeOver: true,
    );
  }

  /// Periodic heartbeat. Re-announces (without take_over) so the server keeps
  /// knowing our endpoint AND so we discover if we've been demoted.
  void startHeartbeat({required Future<({String publicIp, int port, String reachability, String certFingerprint})> Function() endpointSource}) {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(minutes: 30), (_) async {
      try {
        final ep = await endpointSource();
        await announce(
          publicIp: ep.publicIp,
          port: ep.port,
          reachability: ep.reachability,
          certFingerprint: ep.certFingerprint,
          takeOver: false,
        );
      } catch (_) {/* offline; try again next tick */}
    });
  }

  @override
  void dispose() {
    _heartbeatTimer?.cancel();
    super.dispose();
  }
}

final hostRoleProvider = StateNotifierProvider<HostRoleNotifier, HostRoleState>((ref) {
  return HostRoleNotifier(
    api: ref.watch(apiProvider),
    authNotifier: ref.watch(authProvider.notifier),
    cfgNotifier: ref.watch(appConfigProvider.notifier),
  );
});
