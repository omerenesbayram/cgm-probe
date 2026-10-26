import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ble/sensor_controller.dart';
import '../cgm/cgm_parser.dart';
import 'glucose_chart.dart';

/// The list under the graph shows only the newest readings; a recording
/// grows by 288 a day.
const _shownReadings = 100;

/// pair: pair now (Pair / Re-pair); otherwise keep the existing pairing.
/// pin: entered PIN, also kept for pairing again automatically later.
typedef _PairResult = ({bool pair, String? pin});

/// Asks for the PIN before connecting, like mySugr does. Owns its text
/// controller so it lives until the dialog's closing animation is done.
class _PairDialog extends StatefulWidget {
  const _PairDialog({required this.paired});

  final bool paired;

  @override
  State<_PairDialog> createState() => _PairDialogState();
}

class _PairDialogState extends State<_PairDialog> {
  final _pin = TextEditingController();

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pin = _pin.text.trim();
    return AlertDialog(
      title: Text(widget.paired ? 'Already paired' : 'Pair this phone?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.paired
              ? 'This phone was paired with the sensor before. If the sensor '
                  'has been paired with another phone since then, choose '
                  'Re-pair.\n\nEnter the PIN either way: some phones need it '
                  'to pair again on their own when the sensor changes its '
                  'Bluetooth address.'
              : 'The sensor keeps only one pairing. Pairing this phone moves '
                  'the sensor away from the phone that runs mySugr.'),
          const SizedBox(height: 12),
          TextField(
            controller: _pin,
            autofocus: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration:
                const InputDecoration(labelText: 'PIN from the applicator cap'),
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        if (widget.paired)
          TextButton(
            onPressed: () => Navigator.pop(
                context, (pair: false, pin: pin.isEmpty ? null : pin)),
            child: const Text('Use pairing'),
          ),
        FilledButton(
          onPressed: pin.isEmpty
              ? null
              : () => Navigator.pop(context, (pair: true, pin: pin)),
          child: Text(widget.paired ? 'Re-pair' : 'Pair'),
        ),
      ],
    );
  }
}

class ProbeScreen extends StatefulWidget {
  const ProbeScreen({super.key});

  @override
  State<ProbeScreen> createState() => _ProbeScreenState();
}

class _ProbeScreenState extends State<ProbeScreen> {
  final controller = SensorController();

  @override
  void initState() {
    super.initState();
    controller.init(); // reconnects to the remembered sensor, if any
  }

  Future<void> _forget() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Forget sensor?'),
        content: const Text(
          'The app disconnects and stops reconnecting to this sensor when it '
          'starts. The recording is kept. To use the sensor again, find it '
          'and connect.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Forget'),
          ),
        ],
      ),
    );
    if (ok == true) await controller.forgetSensor();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  /// Tapping a sensor stops the search right away. On Android, pairing asks
  /// for the PIN first (like mySugr) and the app enters it the moment the
  /// sensor requests it.
  Future<void> _connect(FoundSensor s) async {
    await controller.stopSearch();
    final paired = await controller.androidPaired(s);
    if (paired == null) return controller.connect(s);
    if (!mounted) return;

    final result = await showDialog<_PairResult>(
      context: context,
      builder: (context) => _PairDialog(paired: paired),
    );
    if (result == null) return;
    await controller.connect(
      s,
      pin: result.pin,
      forgetFirst: paired && result.pair,
      usePairing: paired && !result.pair,
    );
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
            controller.state == ProbeState.reconnecting ||
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
    final connecting = controller.state == ProbeState.connecting;
    final busy = connecting || controller.state == ProbeState.searching;
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
              onPressed: busy ? null : controller.startDemoSearch,
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
              title: Text(s.name.isEmpty ? s.device!.remoteId.str : s.name),
              subtitle: Text(s.simulated
                  ? 'Simulated sensor (demo)'
                  : s.alreadyConnected
                      ? 'Already connected to this phone (shared with mySugr)'
                      : 'Advertising, ${s.rssi} dBm'),
              trailing: const Icon(Icons.chevron_right),
              // Tappable while searching; the tap stops the search.
              onTap: connecting ? null : () => _connect(s),
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
        if (latest != null && controller.message != null)
          Card(
            child: ListTile(
              leading: controller.state == ProbeState.reconnecting ||
                      controller.historyBusy
                  ? const SizedBox.square(
                      dimension: 24,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    )
                  : const Icon(Icons.info_outline),
              title: Text(controller.message!),
            ),
          ),
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 16, 16, 8),
            child: GlucoseChart(readings: controller.readings),
          ),
        ),
        if (controller.state != ProbeState.demo)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FilledButton.tonalIcon(
                  onPressed: controller.canDownloadHistory &&
                          !controller.historyBusy
                      ? controller.downloadHistory
                      : null,
                  icon: const Icon(Icons.history),
                  label: Text(controller.historyBusy
                      ? 'Downloading...'
                      : 'Download stored readings (last 8 h)'),
                ),
                if (controller.recorder != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'Recording ${controller.recorder!.count} readings to '
                      '${controller.recorder!.file.path}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
              ],
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
          child: Text(
              controller.readings.length > _shownReadings
                  ? 'Readings (${controller.readings.length}, '
                      'latest $_shownReadings shown)'
                  : 'Readings (${controller.readings.length})',
              style: theme.textTheme.titleMedium),
        ),
        for (final r in controller.readings.take(_shownReadings))
          ListTile(
            dense: true,
            leading: SizedBox(
              width: 56,
              child: Text(r.measurement.glucoseLabel,
                  textAlign: TextAlign.end,
                  style: theme.textTheme.titleLarge),
            ),
            title: Text(r.sensorTime == null
                ? 'Received ${formatDayTime(r.receivedAt)}'
                : 'Sensor time ${formatDayTime(r.sensorTime!.toLocal())}'),
            subtitle: Text(hex(r.measurement.raw),
                style: const TextStyle(fontFamily: 'monospace')),
          ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: controller.state == ProbeState.demo
              ? controller.stopDemo
              : _forget,
          icon: const Icon(Icons.link_off),
          label: Text(controller.state == ProbeState.demo
              ? 'Stop demo'
              : 'Forget sensor'),
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
