import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/encryption.dart';
import '../services/file_index.dart';
import '../services/file_storage.dart';
import 'auth.dart';
import 'config.dart';

/// Holds the long-lived host-side runtime objects (file index + storage)
/// once onboarding is complete. Other screens read from this provider.
class HostRuntime {
  HostRuntime({required this.index, required this.storage});
  final FileIndex index;
  final FileStorage storage;
}

final hostRuntimeProvider = FutureProvider<HostRuntime?>((ref) async {
  final cfg = ref.watch(appConfigProvider);
  if (cfg.storagePath == null || !cfg.onboardingComplete) return null;

  final index = await FileIndex.open(cfg.storagePath!);
  final crypto = FileCrypto(ref.read(secureStorageProvider));
  final storage = FileStorage(
    root: cfg.storagePath!,
    encryptionEnabled: cfg.encryptionEnabled,
    crypto: crypto,
  );
  return HostRuntime(index: index, storage: storage);
});
