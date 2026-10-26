import 'dart:math';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../ble/sensor_controller.dart';

/// Simple glucose line over sensor time, with the 70-180 mg/dL target
/// range shaded. LO/HI/invalid readings are left out.
class GlucoseChart extends StatelessWidget {
  const GlucoseChart({super.key, required this.readings});

  /// Newest first, as kept by [SensorController].
  final List<Reading> readings;

  static const _low = 70.0;
  static const _high = 180.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final spots = [
      for (final r in readings.reversed)
        if (r.sensorTime != null && r.measurement.glucoseMgDl.isFinite)
          FlSpot(r.sensorTime!.millisecondsSinceEpoch.toDouble(),
              r.measurement.glucoseMgDl),
    ];
    if (spots.length < 2) {
      return const SizedBox(
        height: 120,
        child: Center(child: Text('The graph appears after two readings.')),
      );
    }

    final values = spots.map((s) => s.y);
    final minY = (min(60.0, values.reduce(min) - 10) / 10).floor() * 10.0;
    final maxY = (max(200.0, values.reduce(max) + 10) / 10).ceil() * 10.0;
    final span = Duration(
        milliseconds: (spots.last.x - spots.first.x).round());
    final step = span <= const Duration(hours: 2)
        ? const Duration(minutes: 30)
        : span <= const Duration(hours: 6)
            ? const Duration(hours: 1)
            : span <= const Duration(hours: 12)
                ? const Duration(hours: 2)
                : const Duration(hours: 4);
    final small = theme.textTheme.bodySmall;

    return SizedBox(
      height: 220,
      child: LineChart(
        LineChartData(
          minY: minY,
          maxY: maxY,
          rangeAnnotations: RangeAnnotations(horizontalRangeAnnotations: [
            HorizontalRangeAnnotation(
              y1: _low,
              y2: _high,
              color: Colors.green.withValues(alpha: 0.12),
            ),
          ]),
          gridData: FlGridData(
            drawVerticalLine: false,
            horizontalInterval: 50,
            getDrawingHorizontalLine: (_) => FlLine(
              color: theme.dividerColor.withValues(alpha: 0.3),
              strokeWidth: 1,
            ),
          ),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(),
            rightTitles: const AxisTitles(),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 36,
                interval: 50,
                getTitlesWidget: (value, meta) => SideTitleWidget(
                  meta: meta,
                  child: Text(value.round().toString(), style: small),
                ),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 24,
                interval: step.inMilliseconds.toDouble(),
                minIncluded: false,
                maxIncluded: false,
                getTitlesWidget: (value, meta) => SideTitleWidget(
                  meta: meta,
                  child: Text(_hhmm(value), style: small),
                ),
              ),
            ),
          ),
          lineTouchData: LineTouchData(
            touchTooltipData: LineTouchTooltipData(
              getTooltipItems: (touched) => [
                for (final t in touched)
                  LineTooltipItem(
                    '${t.y.round()} mg/dL\n${_hhmm(t.x)}',
                    TextStyle(color: theme.colorScheme.onInverseSurface),
                  ),
              ],
              getTooltipColor: (_) => theme.colorScheme.inverseSurface,
            ),
          ),
          lineBarsData: [
            LineChartBarData(
              spots: spots,
              color: theme.colorScheme.primary,
              barWidth: 2.5,
              dotData: FlDotData(show: spots.length <= 30),
            ),
          ],
        ),
      ),
    );
  }

  static String _hhmm(double millis) {
    final t = DateTime.fromMillisecondsSinceEpoch(millis.round());
    return '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}';
  }
}
