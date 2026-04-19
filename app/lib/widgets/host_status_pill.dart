import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import '../api/client.dart';
import '../state/auth.dart';
import '../state/config.dart';
import '../state/host_role.dart';

enum _Status { checking, online, offline, error }

/// Live host-connection pill shown in the top bar on every dashboard page.
/// Polls `/v1/accounts/me/active-host` every 15s and on app-resume.
class HostStatusPill extends ConsumerStatefulWidget {
  const HostStatusPill({super.key});
  @override
  ConsumerState<HostStatusPill> createState() => _HostStatusPillState();
}

class _HostStatusPillState extends ConsumerState<HostStatusPill> with WidgetsBindingObserver {
  _Status _status = _Status.checking;
  String? _hostName;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => _check());
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    final auth = ref.read(authProvider);
    if (auth.token == null) {
      if (mounted) setState(() => _status = _Status.offline);
      return;
    }
    // If this device IS the active host, show online directly without a round-trip.
    final hostRole = ref.read(hostRoleProvider);
    if (hostRole.role == HostRole.active) {
      if (mounted) setState(() {
        _status = _Status.online;
        _hostName = 'this device';
      });
      return;
    }
    try {
      final res = await ref.read(apiProvider).getActiveHost(auth.token!);
      if (mounted) setState(() {
        _status = _Status.online;
        _hostName = res['name'] as String?;
      });
    } on ApiException catch (e) {
      if (mounted) setState(() {
        _status = (e.code == 'no_active_host' || e.code == 'host_offline') ? _Status.offline : _Status.error;
      });
    } catch (_) {
      if (mounted) setState(() => _status = _Status.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final (color, bg, label) = _decode();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Text(label, style: GoogleFonts.poppins(color: color, fontSize: 11, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  (Color, Color, String) _decode() {
    switch (_status) {
      case _Status.checking:
        return (const Color(0xFF64748B), const Color(0xFFF1F5F9), 'Checking…');
      case _Status.online:
        return (const Color(0xFF059669), const Color(0xFFD1FAE5),
                _hostName != null ? 'Online · $_hostName' : 'Online');
      case _Status.offline:
        final cfg = ref.read(appConfigProvider);
        final hasOnboarded = cfg.onboardingComplete;
        return (const Color(0xFFB45309), const Color(0xFFFEF3C7),
                hasOnboarded ? 'Storage offline' : 'No storage yet');
      case _Status.error:
        return (const Color(0xFFB91C1C), const Color(0xFFFEE2E2), 'Connection error');
    }
  }
}
