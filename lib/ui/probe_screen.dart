import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ble/sensor_controller.dart';
import '../cgm/cgm_parser.dart';

class ProbeScreen extends StatefulWidget {
  const ProbeScreen({super.key});

  @override
  State<ProbeScreen> createState() => _ProbeScreenState();
}

class _ProbeScreenState extends State<ProbeScreen> {
  final controller = SensorController();

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  Future<void> _connect(FoundSensor s) async {
    if (await controller.needsNewPairing(s)) {
      if (!mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Pair this phone?'),
          content: const Text(
            'This phone is not paired with the sensor yet. Connecting will '
            'show a PIN prompt and pair it.\n\n'
            'The sensor may then stop talking to the phone that runs mySugr. '
            'Only continue if you accept that, for example near the end of '
            'the sensor\'s 14 days.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Pair'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    await controller.connect(s);
  }

  Future<void> _copy(String label, String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('$label copied to clipboard')));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final live = controller.state == ProbeState.connected ||
            controller.state == ProbeState.demo;
        return Scaffold(
          appBar: AppBar(
            title: Text(live ? controller.deviceName : 'CGM Probe'),
            actions: [
              IconButton(
                tooltip: 'Copy readings as CSV',
                icon: const Icon(Icons.table_chart_outlined),
                onPressed: controller.readings.isEmpty
                    ? null
                    : () => _copy('Readings', controller.readingsCsv()),
              ),
              IconButton(
                tooltip: 'Copy log',
                icon: const Icon(Icons.copy_all_outlined),
                onPressed: () => _copy('Log', controller.log.join('\n')),
              ),
            ],
          ),
          body: SafeArea(
            child: live ? _liveView(context) : _searchView(context),
          ),
        );
      },
    );
  }

  Widget _searchView(BuildContext context) {
    final searching = controller.state == ProbeState.searching;
    final busy = searching || controller.state == ProbeState.connecting;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: busy ? null : controller.search,
                icon: const Icon(Icons.bluetooth_searching),
                label: const Text('Find sensor'),
              ),
            ),
            const SizedBox(width: 12),
            OutlinedButton(
              onPressed: busy ? null : controller.startDemo,
              child: const Text('Demo'),
            ),
          ],
        ),
        if (busy) const Padding(
          padding: EdgeInsets.only(top: 16),
          child: LinearProgressIndicator(),
        ),
        if (controller.message != null)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(controller.message!),
          ),
        const SizedBox(height: 8),
        for (final s in controller.found.values)
          Card(
            child: ListTile(
              leading: const Icon(Icons.sensors),
              title: Text(s.name.isEmpty ? s.device.remoteId.str : s.name),
              subtitle: Text(s.alreadyConnected
                  ? 'Already connected to this phone (shared with mySugr)'
                  : 'Advertising, ${s.rssi} dBm'),
              trailing: const Icon(Icons.chevron_right),
              onTap: busy ? null : () => _connect(s),
            ),
          ),
      ],
    );
  }

  Widget _liveView(BuildContext context) {
    final theme = Theme.of(context);
    final latest =
        controller.readings.isEmpty ? null : controller.readings.first;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: latest == null
                ? Text(controller.message ?? 'Waiting for data...')
                : _latestReading(theme, latest),
          ),
        ),
        if (controller.info.isNotEmpty)
          Card(
            child: ExpansionTile(
              title: const Text('Sensor info'),
              children: [
                for (final e in controller.info.entries)
                  ListTile(
                    dense: true,
                    title: Text(e.key),
                    subtitle: Text(e.value),
                  ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 16, 4, 4),
          child: Text('Readings (${controller.readings.length})',
              style: theme.textTheme.titleMedium),
        ),
        for (final r in controller.readings)
          ListTile(
            dense: true,
            leading: Text(r.measurement.glucoseLabel,
                style: theme.textTheme.titleLarge),
            title: Text(r.sensorTime == null
                ? 'Received ${formatTime(r.receivedAt)}'
                : 'Sensor time ${formatTime(r.sensorTime!.toLocal())}'),
            subtitle: Text(hex(r.measurement.raw),
                style: const TextStyle(fontFamily: 'monospace')),
          ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: controller.disconnect,
          icon: const Icon(Icons.link_off),
          label: Text(controller.state == ProbeState.demo
              ? 'Stop demo'
              : 'Disconnect'),
        ),
      ],
    );
  }

  Widget _latestReading(ThemeData theme, Reading r) {
    final m = r.measurement;
    final time = r.sensorTime?.toLocal() ?? r.receivedAt;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(m.glucoseLabel,
                style: theme.textTheme.displayLarge
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text('mg/dL  ${trendArrow(m.trendMgDlPerMin)}',
                  style: theme.textTheme.headlineSmall),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text('Sensor time: ${formatTime(time)}'),
        if (m.trendMgDlPerMin != null)
          Text('Trend: ${m.trendMgDlPerMin!.toStringAsFixed(2)} mg/dL/min'),
        if (m.qualityPercent != null)
          Text('Quality: ${m.qualityPercent!.toStringAsFixed(0)}%'),
        Text('Status: ${m.annunciation}'),
        Text('Checksum: ${!m.crcPresent ? 'none' : m.crcValid ? 'OK' : 'BAD'}'),
      ],
    );
  }
}

/// Arrow for a rate of change in mg/dL per minute, using the usual CGM
/// bands (1, 2 and 3 mg/dL/min).
String trendArrow(double? rate) {
  if (rate == null || rate.isNaN) return '';
  if (rate >= 3) return '⇈';
  if (rate >= 2) return '↑';
  if (rate >= 1) return '↗';
  if (rate > -1) return '→';
  if (rate > -2) return '↘';
  if (rate > -3) return '↓';
  return '⇊';
}
