import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/app_theme.dart';

/// Lavender-gradient line chart of real storage usage over time.
/// `spots` come from FileIndex.storageHistory(); a daily snapshot is taken
/// by HostLifecycle. Empty/single-point shows an empty axis (no fake data).
class StorageLineChart extends StatelessWidget {
  const StorageLineChart({super.key, this.spots});
  final List<FlSpot>? spots;

  @override
  Widget build(BuildContext context) {
    final data = spots ?? const <FlSpot>[];
    final c = context.weeberColors;
    if (data.length < 2) {
      return Center(
        child: Text(
          data.isEmpty ? 'No data yet' : 'Day 1 — chart will fill in over time',
          style: GoogleFonts.poppins(fontSize: 12, color: c.textMuted),
        ),
      );
    }
    return LineChart(
      LineChartData(
        gridData: FlGridData(
          show: true, drawVerticalLine: false,
          getDrawingHorizontalLine: (_) => FlLine(color: c.border, strokeWidth: 1),
        ),
        titlesData: FlTitlesData(
          show: true,
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          bottomTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        borderData: FlBorderData(show: false),
        minY: 0, maxY: 100,
        lineBarsData: [
          LineChartBarData(
            spots: data,
            isCurved: true,
            preventCurveOverShooting: true,
            color: AppTheme.accent,
            barWidth: 2.5,
            isStrokeCapRound: true,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [AppTheme.accent.withValues(alpha: 0.22), AppTheme.accent.withValues(alpha: 0.0)],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
