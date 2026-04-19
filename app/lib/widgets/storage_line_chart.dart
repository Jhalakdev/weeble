import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/app_theme.dart';

/// Lavender-gradient line chart (matches "Storage" card in CloudBox).
/// Data is optional — if null, draws a placeholder curve.
class StorageLineChart extends StatelessWidget {
  const StorageLineChart({super.key, this.spots});
  final List<FlSpot>? spots;

  static const _labels = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
  static const _placeholder = [
    FlSpot(0, 30),
    FlSpot(1, 55),
    FlSpot(2, 42),
    FlSpot(3, 62),
    FlSpot(4, 38),
    FlSpot(5, 70),
    FlSpot(6, 40),
    FlSpot(7, 60),
    FlSpot(8, 55),
    FlSpot(9, 75),
    FlSpot(10, 50),
    FlSpot(11, 68),
  ];

  @override
  Widget build(BuildContext context) {
    final data = spots ?? _placeholder;
    final c = context.weeberColors;
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
          bottomTitles: AxisTitles(sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 26,
            getTitlesWidget: (value, meta) => Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                _labels[value.toInt() % 12],
                style: GoogleFonts.poppins(color: c.textMuted, fontSize: 10),
              ),
            ),
          )),
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
