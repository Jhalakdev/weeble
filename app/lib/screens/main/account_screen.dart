import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../api/client.dart';
import '../../state/auth.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_shell.dart';

class AccountScreen extends ConsumerStatefulWidget {
  const AccountScreen({super.key});
  @override
  ConsumerState<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends ConsumerState<AccountScreen> {
  BillingStatus? _status;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final token = ref.read(authProvider).token;
    if (token == null) {
      if (mounted) setState(() { _loading = false; _error = 'Not signed in'; });
      return;
    }
    try {
      final s = await ref.read(apiProvider).billingStatus(token);
      if (!mounted) return;
      setState(() { _status = s; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _error = e.toString(); });
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final c = context.weeberColors;
    return AppShell(
      title: 'Account',
      activeRoute: '/account',
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _Card(
            title: 'Profile',
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _kv('Account ID', auth.accountId ?? '—'),
              const SizedBox(height: 12),
              _kv('Status', auth.isLoggedIn ? 'Signed in' : 'Signed out'),
            ]),
          ),
          const SizedBox(height: 16),
          if (_loading)
            const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))
          else if (_status != null)
            _Card(
              title: 'Plan',
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(
                  _status!.plan == 'trial' ? 'Free trial' : _status!.plan,
                  style: GoogleFonts.poppins(fontSize: 22, fontWeight: FontWeight.w700, color: c.textPrimary),
                ),
                const SizedBox(height: 4),
                Text(
                  _planSubtitle(_status!),
                  style: GoogleFonts.poppins(fontSize: 12, color: c.textMuted),
                ),
              ]),
            )
          else if (_error != null)
            _Card(title: 'Plan', child: Text('Could not load plan: $_error', style: TextStyle(color: c.textMuted))),
          const SizedBox(height: 16),
          _Card(
            title: 'About Weeber',
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                'Your files live on your computer, not on a remote server. '
                'A persistent encrypted tunnel lets every device you own reach those files — '
                'no router configuration, no cloud storage bills.',
                style: GoogleFonts.poppins(fontSize: 12.5, color: c.textMuted, height: 1.5),
              ),
            ]),
          ),
          const SizedBox(height: 24),
          OutlinedButton.icon(
            icon: const Icon(Icons.logout),
            label: const Text('Sign out'),
            onPressed: () => ref.read(authProvider.notifier).logout(),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.red.shade600,
              side: BorderSide(color: Colors.red.shade300),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
        ],
      ),
    );
  }

  String _planSubtitle(BillingStatus s) {
    if (s.plan == 'trial' && s.trialDaysRemaining > 0) {
      return '${s.trialDaysRemaining} day${s.trialDaysRemaining == 1 ? '' : 's'} remaining · status: ${s.status}';
    }
    return 'status: ${s.status}';
  }

  Widget _kv(String k, String v) {
    final c = context.weeberColors;
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(width: 110, child: Text(k, style: GoogleFonts.poppins(fontSize: 11, color: c.textMuted))),
      Expanded(child: Text(v, style: GoogleFonts.poppins(fontSize: 12, color: c.textPrimary, fontWeight: FontWeight.w500))),
    ]);
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.title, required this.child});
  final String title;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final c = context.weeberColors;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.surface, borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w600, color: c.textPrimary)),
        const SizedBox(height: 12),
        child,
      ]),
    );
  }
}
