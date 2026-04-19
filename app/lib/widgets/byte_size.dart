String formatBytes(int bytes, {int decimals = 1}) {
  if (bytes < 1024) return '$bytes B';
  const suffixes = ['KB', 'MB', 'GB', 'TB', 'PB'];
  double v = bytes / 1024.0;
  int i = 0;
  while (v >= 1024 && i < suffixes.length - 1) {
    v /= 1024.0;
    i++;
  }
  return '${v.toStringAsFixed(decimals)} ${suffixes[i]}';
}
