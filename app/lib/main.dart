import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'screens/auth/login_screen.dart';
import 'screens/auth/signup_screen.dart';
import 'screens/backup/backup_screen.dart';
import 'dart:io';
import 'screens/license_blocked_screen.dart';
import 'screens/main/client_drive_screen.dart';
import 'screens/main/demoted_screen.dart';
import 'screens/main/devices_screen.dart';
import 'screens/main/drive_screen.dart';
import 'screens/onboarding/encryption_screen.dart';
import 'screens/onboarding/storage_screen.dart';
import 'screens/onboarding/welcome_screen.dart';
import 'screens/pairing/host_qr_screen.dart';
import 'screens/pairing/scan_qr_screen.dart';
import 'security/embedded_secrets.g.dart';
import 'security/license_guard.dart';
import 'services/host_lifecycle.dart';
import 'state/auth.dart';
import 'state/config.dart';
import 'state/host_role.dart';
import 'theme/app_theme.dart';
import 'theme/theme_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  applyEmbeddedSecrets(); // unscrambles API URL + license public key
  runApp(const ProviderScope(child: WeeberApp()));
}

class WeeberApp extends ConsumerStatefulWidget {
  const WeeberApp({super.key});
  @override
  ConsumerState<WeeberApp> createState() => _WeeberAppState();
}

class _WeeberAppState extends ConsumerState<WeeberApp> {
  bool _bootstrapped = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await ref.read(themeControllerProvider.notifier).load();
    await ref.read(appConfigProvider.notifier).load();
    await ref.read(authProvider.notifier).bootstrap();
    await ref.read(licenseGuardProvider.notifier).bootstrap();
    // Boot the host file server + IP-announce loop on desktop. No-op on
    // mobile and on machines that haven't completed onboarding.
    final isDesktop = Platform.isMacOS || Platform.isWindows || Platform.isLinux;
    if (isDesktop) {
      // Don't await — host startup involves UPnP discovery (~5s) and shouldn't
      // block the UI from appearing.
      // ignore: unawaited_futures
      ref.read(hostLifecycleProvider).ensureRunning();
    }
    if (mounted) setState(() => _bootstrapped = true);
  }

  @override
  Widget build(BuildContext context) {
    if (!_bootstrapped) {
      return MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(body: Center(child: CircularProgressIndicator())),
      );
    }
    final router = _buildRouter(ref);
    return MaterialApp.router(
      title: 'Weeber',
      theme: AppTheme.light(),
      routerConfig: router,
      debugShowCheckedModeBanner: false,
    );
  }
}

GoRouter _buildRouter(WidgetRef ref) {
  return GoRouter(
    initialLocation: '/',
    refreshListenable: _RouterRefresh(ref),
    routes: [
      GoRoute(path: '/', builder: (_, _) => const _RootRedirect()),
      GoRoute(path: '/login', builder: (_, _) => const LoginScreen()),
      GoRoute(path: '/signup', builder: (_, _) => const SignupScreen()),
      GoRoute(path: '/onboarding/welcome', builder: (_, _) => const WelcomeScreen()),
      GoRoute(path: '/onboarding/storage', builder: (_, _) => const StorageScreen()),
      GoRoute(path: '/onboarding/encryption', builder: (_, _) => const EncryptionScreen()),
      GoRoute(path: '/drive', builder: (_, _) {
        // Desktop machines that ARE the host show the host drive screen
        // (their local files). Mobile + demoted desktops show the client
        // drive screen (browse the active host's files via HTTPS).
        final isDesktop = Platform.isMacOS || Platform.isWindows || Platform.isLinux;
        return isDesktop ? const DriveScreen() : const ClientDriveScreen();
      }),
      GoRoute(path: '/devices', builder: (_, _) => const DevicesScreen()),
      GoRoute(path: '/pair/host', builder: (_, _) => const HostQrScreen()),
      GoRoute(path: '/pair', builder: (_, _) => const ScanQrScreen()),
      GoRoute(path: '/blocked', builder: (_, _) => const LicenseBlockedScreen()),
      GoRoute(path: '/demoted', builder: (_, _) => const DemotedScreen()),
      GoRoute(path: '/backup', builder: (_, _) => const BackupScreen()),
    ],
    redirect: (context, state) {
      final auth = ref.read(authProvider);
      final cfg = ref.read(appConfigProvider);
      final license = ref.read(licenseGuardProvider);
      final hostRole = ref.read(hostRoleProvider);
      final loc = state.matchedLocation;

      // Hard kill — license revoked or fundamentally invalid → blocked screen.
      if (license.status == LicenseStatus.revoked || license.status == LicenseStatus.invalid) {
        return loc == '/blocked' ? null : '/blocked';
      }

      // We were the active host but got replaced — show demoted screen.
      if (hostRole.role == HostRole.demoted && loc != '/demoted') {
        return '/demoted';
      }

      final isAuthRoute = loc == '/login' || loc == '/signup';
      if (!auth.isLoggedIn) {
        return isAuthRoute ? null : '/login';
      }
      if (isAuthRoute) {
        return cfg.onboardingComplete ? '/drive' : '/onboarding/welcome';
      }
      if (loc == '/') {
        return cfg.onboardingComplete ? '/drive' : '/onboarding/welcome';
      }
      return null;
    },
  );
}

class _RootRedirect extends StatelessWidget {
  const _RootRedirect();
  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: CircularProgressIndicator()));
}

class _RouterRefresh extends ChangeNotifier {
  _RouterRefresh(WidgetRef ref) {
    ref.listen(authProvider, (_, _) => notifyListeners());
    ref.listen(appConfigProvider, (_, _) => notifyListeners());
    ref.listen(licenseGuardProvider, (_, _) => notifyListeners());
    ref.listen(hostRoleProvider, (_, _) => notifyListeners());
    ref.listen(themeControllerProvider, (_, _) => notifyListeners());
  }
}
