import 'dart:async';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import '../api/client.dart';
import '../state/auth.dart';
import '../state/config.dart';
import '../state/host_role.dart';
import '../state/host_runtime.dart';
import 'cert.dart';
import 'host_server.dart';
import 'keypair.dart';
import 'upnp.dart';

/// Host-side runtime: device registration, TLS cert, UPnP, HTTPS server,
/// and periodic IP announce. Highly defensive — every step is wrapped so
/// a failure in one doesn't silently kill the rest. Writes a detailed
/// timestamped log file to <storagePath>/.weeber-debug.log so the user
/// can share it when something goes wrong.
class HostLifecycle {
  HostLifecycle({required this.ref});
  final Ref ref;

  HostServer? _server;
  Timer? _heartbeat;
  Timer? _retry;
  HostCertificate? _cert;
  int? _externalPort;
  int? _localPort;
  bool _isStarting = false;
  String _reachability = 'unknown';
  String? _lastError;
  File? _logFile;

  bool get isRunning => _server != null;
  String? get lastError => _lastError;
  String? get debugLogPath => _logFile?.path;

  Future<void> ensureRunning({bool forceTakeOver = false}) async {
    if (!_isDesktop) return;
    if (_isStarting) return;
    _isStarting = true;
    try {
      await _run(forceTakeOver: forceTakeOver);
    } finally {
      _isStarting = false;
    }
  }

  Future<void> _run({required bool forceTakeOver}) async {
    final cfg = ref.read(appConfigProvider);
    final auth = ref.read(authProvider);
    final runtime = await ref.read(hostRuntimeProvider.future);

    await _openLog(cfg.storagePath);
    _log('═══ ensureRunning ═══');
    _log('storagePath=${cfg.storagePath} onboardingComplete=${cfg.onboardingComplete} '
        'deviceId=${cfg.deviceId} hasToken=${auth.token != null} hasRuntime=${runtime != null}');

    if (cfg.storagePath == null || !cfg.onboardingComplete) {
      _log('SKIP: onboarding not complete');
      return;
    }
    if (auth.token == null) {
      _log('SKIP: not logged in');
      return;
    }
    if (runtime == null) {
      _log('SKIP: runtime not ready');
      return;
    }

    // STEP 1 — register device if needed
    if (cfg.deviceId == null) {
      _log('STEP 1/5: registering this device as a host…');
      try {
        final api = ref.read(apiProvider);
        final keyPair = await DeviceKeypair.getOrCreate(ref.read(secureStorageProvider));
        final reg = await api.registerDevice(
          token: auth.token!,
          kind: 'host',
          name: _localDeviceName(),
          pubkey: keyPair.publicKeyB64,
        );
        await ref.read(authProvider.notifier).replaceToken(reg.token);
        await ref.read(appConfigProvider.notifier).update((c) => c.copyWith(deviceId: reg.deviceId));
        _log('STEP 1/5 OK: deviceId=${reg.deviceId}');
      } catch (e, st) {
        _log('STEP 1/5 FAILED: $e\n$st');
        _lastError = 'register_failed: $e';
        _scheduleRetry();
        return;
      }
    } else {
      _log('STEP 1/5 SKIPPED: already registered (${cfg.deviceId})');
    }

    // STEP 2 — TLS cert
    _log('STEP 2/5: generating / loading TLS certificate…');
    try {
      _cert = await HostCertificate.getOrCreate(cfg.storagePath!);
      _log('STEP 2/5 OK: cert fingerprint=${_cert!.fingerprint.substring(0, 24)}…');
    } catch (e, st) {
      _log('STEP 2/5 FAILED: $e\n$st');
      _lastError = 'cert_failed: $e';
      // We can still announce with a sentinel fingerprint — phones won't be
      // able to reach us until cert works, but the pill flips to online.
      _cert = null;
    }

    // STEP 3 — local HTTPS file server
    if (_cert != null) {
      _log('STEP 3/5: starting HTTPS file server on localhost…');
      try {
        final api = ref.read(apiProvider);
        final freshAuth = ref.read(authProvider);
        _server = HostServer(
          cert: _cert!,
          index: runtime.index,
          storage: runtime.storage,
          api: api,
          hostToken: freshAuth.token!,
        );
        _localPort = await _server!.start();
        _log('STEP 3/5 OK: listening on ${_localPort}');
      } catch (e, st) {
        _log('STEP 3/5 FAILED: $e\n$st');
        _lastError = 'server_failed: $e';
        _server = null;
      }
    } else {
      _log('STEP 3/5 SKIPPED: no cert');
    }

    // STEP 4 — UPnP port mapping (best-effort, has timeout)
    _externalPort = _localPort;
    _reachability = 'unknown';
    if (_localPort != null) {
      _log('STEP 4/5: probing UPnP (8s timeout)…');
      try {
        final localIp = await Upnp.primaryLanIp();
        if (localIp != null) {
          final ext = await Upnp.tryMapPort(localPort: _localPort!, localIp: localIp)
              .timeout(const Duration(seconds: 8), onTimeout: () => null);
          if (ext != null) {
            _externalPort = ext;
            _reachability = 'upnp';
            _log('STEP 4/5 OK: UPnP mapped $_localPort → $ext');
          } else {
            _log('STEP 4/5 NO-OP: UPnP not available / no IGD');
          }
        } else {
          _log('STEP 4/5 NO-OP: no primary LAN IP');
        }
      } catch (e) {
        _log('STEP 4/5 FAILED: $e (non-fatal)');
      }
    }

    // STEP 5 — announce to VPS (the important one — flips the pill)
    _log('STEP 5/5: announcing to VPS…');
    final announceOk = await _announceWithRetry(takeOver: forceTakeOver || true);
    if (announceOk) {
      _log('═══ all steps complete — host is online ═══');
      _lastError = null;
      _scheduleHeartbeat();
    } else {
      _log('═══ announce failed — will retry in 30s ═══');
      _scheduleRetry();
    }
  }

  Future<bool> _announceWithRetry({required bool takeOver}) async {
    final port = _externalPort ?? _localPort;
    if (port == null) {
      _log('  announce SKIP: no port (server never started)');
      return false;
    }
    final fingerprint = _cert?.fingerprint ?? 'sha256:pending';
    final auth = ref.read(authProvider);
    if (auth.token == null) {
      _log('  announce SKIP: no token');
      return false;
    }
    try {
      final res = await ref.read(apiProvider).announce(
            token: auth.token!,
            publicIp: 'auto',
            port: port,
            reachability: _reachability,
            certFingerprint: fingerprint,
            takeOver: takeOver,
          );
      _log('  announce OK: status=${res['status']} public_ip=${res['public_ip']} port=$port reach=$_reachability');
      ref.read(hostRoleProvider.notifier).announce(
            publicIp: 'auto',
            port: port,
            reachability: _reachability,
            certFingerprint: fingerprint,
            takeOver: takeOver,
          );
      return true;
    } on ApiException catch (e) {
      _log('  announce FAILED: ${e.code} (http ${e.statusCode})');
      _lastError = 'announce_failed: ${e.code}';
      return false;
    } catch (e) {
      _log('  announce FAILED (exception): $e');
      _lastError = 'announce_failed: $e';
      return false;
    }
  }

  void _scheduleHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(const Duration(minutes: 30), (_) async {
      _log('heartbeat tick');
      await _announceWithRetry(takeOver: false);
    });
  }

  void _scheduleRetry() {
    _retry?.cancel();
    _retry = Timer(const Duration(seconds: 30), () => ensureRunning());
  }

  Future<void> takeOver() async {
    if (!isRunning) {
      await ensureRunning(forceTakeOver: true);
    } else {
      await _announceWithRetry(takeOver: true);
    }
  }

  Future<void> stop() async {
    _heartbeat?.cancel();
    _retry?.cancel();
    _heartbeat = null;
    _retry = null;
    await _server?.stop();
    _server = null;
  }

  // ---- logging ----
  Future<void> _openLog(String? storagePath) async {
    if (storagePath == null) return;
    try {
      final f = File(p.join(storagePath, '.weeber-debug.log'));
      if (!await f.exists()) await f.create(recursive: true);
      _logFile = f;
    } catch (_) {}
  }

  void _log(String msg) {
    final ts = DateTime.now().toIso8601String();
    final line = '[$ts] $msg';
    // ignore: avoid_print
    print('[host] $line');
    stderr.writeln('[host] $line');
    if (_logFile != null) {
      try { _logFile!.writeAsStringSync('$line\n', mode: FileMode.append, flush: true); } catch (_) {}
    }
  }

  bool get _isDesktop =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  String _localDeviceName() {
    if (Platform.isMacOS) return '${Platform.localHostname} (macOS)';
    if (Platform.isWindows) return '${Platform.localHostname} (Windows)';
    if (Platform.isLinux) return '${Platform.localHostname} (Linux)';
    return Platform.localHostname;
  }
}

final hostLifecycleProvider = Provider<HostLifecycle>((ref) => HostLifecycle(ref: ref));
