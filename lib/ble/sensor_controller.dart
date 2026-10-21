import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../cgm/cgm_parser.dart';
import '../cgm/crc.dart';
import '../cgm/sfloat.dart';
import 'cgm_uuids.dart';

enum ProbeState { idle, searching, connecting, connected, demo }

class FoundSensor {
  FoundSensor(this.device, this.name, {this.rssi, this.alreadyConnected = false});

  final BluetoothDevice device;
  final String name;
  final int? rssi;

  /// Found via systemDevices: another app on this phone (mySugr) holds
  /// the connection, so we can share it without pairing again.
  final bool alreadyConnected;
}

class Reading {
  Reading(this.measurement, this.receivedAt, this.sensorTime);

  final CgmMeasurement measurement;
  final DateTime receivedAt;

  /// Session start + time offset; null until the start time is known.
  final DateTime? sensorTime;
}

/// Finds a SmartGuide sensor, connects, reads its info and listens to
/// CGM Measurement notifications. It never writes to the sensor's control
/// points (RACP / SOCP), so it cannot change sensor settings.
class SensorController extends ChangeNotifier {
  ProbeState state = ProbeState.idle;
  String? message;
  final found = <DeviceIdentifier, FoundSensor>{};
  final info = <String, String>{};
  final readings = <Reading>[];
  final log = <String>[];

  BluetoothDevice? _device;
  SessionStartTime? _sessionStart;
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  Timer? _demoTimer;

  String get deviceName => _device?.platformName ?? 'Demo';

  void _log(String line) {
    final now = DateTime.now();
    log.add('${_hms(now)}  $line');
    debugPrint('[probe] $line');
  }

  void _set(ProbeState s, [String? msg]) {
    state = s;
    message = msg;
    notifyListeners();
  }

  /// Android only: whether connecting would trigger a new pairing (PIN
  /// prompt). A new pairing may take the sensor away from the phone that
  /// runs mySugr, so the UI asks first.
  Future<bool> needsNewPairing(FoundSensor s) async {
    if (!Platform.isAndroid || s.alreadyConnected) return false;
    return await s.device.bondState.first != BluetoothBondState.bonded;
  }

  Future<void> search() async {
    found.clear();
    if (await FlutterBluePlus.adapterState.first != BluetoothAdapterState.on) {
      _set(ProbeState.idle, 'Bluetooth is off. Turn it on and try again.');
      return;
    }
    _set(ProbeState.searching, 'Searching for 15 seconds...');

    try {
      final system = await FlutterBluePlus.systemDevices([CgmUuids.service]);
      for (final d in system) {
        found[d.remoteId] = FoundSensor(d, d.platformName, alreadyConnected: true);
        _log('System device: ${d.platformName} (${d.remoteId})');
      }
    } catch (e) {
      _log('systemDevices failed: $e');
    }
    notifyListeners();

    await _scanSub?.cancel();
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        final name = r.advertisementData.advName.isNotEmpty
            ? r.advertisementData.advName
            : r.device.platformName;
        final isCgm = looksLikeSmartGuide(name) ||
            r.advertisementData.serviceUuids.contains(CgmUuids.service);
        if (!isCgm || found[r.device.remoteId]?.alreadyConnected == true) {
          continue;
        }
        if (!found.containsKey(r.device.remoteId)) {
          _log('Advertising: $name (${r.device.remoteId}) ${r.rssi} dBm');
        }
        found[r.device.remoteId] = FoundSensor(r.device, name, rssi: r.rssi);
      }
      notifyListeners();
    });

    try {
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 15));
      await FlutterBluePlus.isScanning.where((s) => !s).first;
    } catch (e) {
      _log('Scan failed: $e');
      message = 'Scan failed: $e';
    }
    await _scanSub?.cancel();
    if (state == ProbeState.searching) {
      _set(
        ProbeState.idle,
        found.isEmpty
            ? 'No sensor found. On iPhone, the sensor only advertises when '
                'no app is connected to it.'
            : null,
      );
    }
  }

  Future<void> connect(FoundSensor s) async {
    await FlutterBluePlus.stopScan();
    _device = s.device;
    info.clear();
    readings.clear();
    _sessionStart = null;
    _set(ProbeState.connecting, 'Connecting to ${s.name}...');

    try {
      await _connSub?.cancel();
      _connSub = s.device.connectionState.listen((st) {
        _log('Connection state: ${st.name}');
        if (st == BluetoothConnectionState.disconnected &&
            state == ProbeState.connected) {
          _set(ProbeState.idle, 'Sensor disconnected.');
        }
      });
      await s.device.connect(license: License.nonprofit);
      _log('Connected to ${s.name}');

      final services = await s.device.discoverServices();
      final chars = {
        for (final svc in services)
          for (final c in svc.characteristics) c.uuid: c,
      };
      _log('Services: ${services.map((e) => e.uuid.str).join(', ')}');

      for (final entry in CgmUuids.deviceInfo.entries) {
        final c = chars[entry.key];
        if (c == null) continue;
        final v = await _read(c, entry.value);
        if (v != null) info[entry.value] = utf8.decode(v, allowMalformed: true);
      }
      await _readCgmInfo(chars);

      final m = chars[CgmUuids.measurement];
      if (m == null) throw StateError('No CGM Measurement characteristic');
      final sub = m.onValueReceived.listen(_onMeasurement);
      s.device.cancelWhenDisconnected(sub);
      await m.setNotifyValue(true);
      _log('Subscribed to CGM Measurement');
      _set(ProbeState.connected,
          'Waiting for the next reading (the sensor sends one every 5 minutes).');
    } catch (e) {
      _log('Connect failed: $e');
      await s.device.disconnect();
      _set(ProbeState.idle, 'Could not connect: $e');
    }
  }

  Future<void> _readCgmInfo(Map<Guid, BluetoothCharacteristic> chars) async {
    Future<void> decode(Guid id, String label, void Function(List<int>) f) async {
      final c = chars[id];
      if (c == null) return;
      final v = await _read(c, label);
      if (v == null) return;
      try {
        f(v);
      } catch (e) {
        info[label] = 'Could not decode ${hex(v)}: $e';
      }
    }

    await decode(CgmUuids.feature, 'Features', (v) {
      final f = parseFeature(v);
      info['Features'] = f.labels.join(', ');
      info['Sample'] = '${f.typeLabel}, ${f.sampleLocationLabel}';
      info['Multiple bonds'] = f.multipleBondSupported ? 'Supported' : 'No';
    });
    await decode(CgmUuids.sessionStartTime, 'Session start', (v) {
      _sessionStart = parseSessionStartTime(v);
      info['Session start'] = _dateTime(_sessionStart!.utc.toLocal());
    });
    await decode(CgmUuids.sessionRunTime, 'Sensor lifetime', (v) {
      final hours = parseSessionRunTimeHours(v);
      info['Sensor lifetime'] = '$hours h (${hours / 24} days)';
      if (_sessionStart != null) {
        final end = _sessionStart!.utc.add(Duration(hours: hours));
        info['Sensor ends'] = _dateTime(end.toLocal());
      }
    });
    await decode(CgmUuids.status, 'Status', (v) {
      final st = parseStatus(v);
      info['Status'] = st.annunciation.toString();
      info['Minutes since start'] = '${st.timeOffsetMinutes}';
    });
  }

  Future<List<int>?> _read(BluetoothCharacteristic c, String label) async {
    try {
      final v = await c.read();
      _log('Read $label (${c.uuid.str}): ${hex(v)}');
      return v;
    } catch (e) {
      _log('Read $label failed: $e');
      return null;
    }
  }

  void _onMeasurement(List<int> value) {
    _log('Measurement: ${hex(value)}');
    try {
      final now = DateTime.now();
      for (final m in parseMeasurements(value)) {
        readings.insert(0, Reading(m, now, _sessionStart == null ? null : m.timeFrom(_sessionStart!)));
        _log('  -> ${m.glucoseLabel} mg/dL, offset ${m.timeOffsetMinutes} min, '
            'CRC ${m.crcValid ? 'ok' : 'BAD'}');
      }
      message = null;
    } catch (e) {
      _log('  -> could not decode: $e');
    }
    notifyListeners();
  }

  Future<void> disconnect() async {
    _demoTimer?.cancel();
    await _connSub?.cancel();
    await _device?.disconnect();
    _device = null;
    _set(ProbeState.idle);
  }

  /// Plays back the reading captured from the real sensor, then a random
  /// walk, so the screens can be tested without a sensor.
  void startDemo() {
    const captured = [0x0D, 0x43, 0x5E, 0x00, 0x6E, 0x28, 0x02, 0x05, 0xE0, 0x59, 0x00, 0x78, 0x53];
    info
      ..clear()
      ..['Mode'] = 'Demo data, not from a sensor';
    readings.clear();
    var offset = 10350;
    _sessionStart = SessionStartTime(
      utc: DateTime.now().toUtc().subtract(const Duration(minutes: 10350)),
      timeZoneQuarterHours: 0,
      dstQuarterHours: null,
      crcValid: null,
    );
    _set(ProbeState.demo);
    _onMeasurement(captured);

    final rnd = Random();
    var glucose = 94.0;
    _demoTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      final trend = (rnd.nextDouble() - 0.45) * 4;
      glucose = (glucose + trend * 5).clamp(45, 260);
      offset += 5;
      final sf = encodeSfloat(glucose);
      final tr = encodeSfloat(trend, exponent: -2);
      final q = encodeSfloat(90);
      _onMeasurement(withCrc([
        13, 0x43, sf & 0xFF, sf >> 8, offset & 0xFF, offset >> 8, 0x02,
        tr & 0xFF, tr >> 8, q & 0xFF, q >> 8,
      ]));
    });
  }

  String readingsCsv() {
    final rows = ['received_local,sensor_time_local,glucose_mg_dl,trend_mg_dl_min,'
        'quality_pct,status,crc_ok,raw_hex'];
    for (final r in readings.reversed) {
      final m = r.measurement;
      rows.add([
        r.receivedAt.toIso8601String(),
        r.sensorTime?.toLocal().toIso8601String() ?? '',
        m.glucoseLabel,
        m.trendMgDlPerMin?.toStringAsFixed(2) ?? '',
        m.qualityPercent?.toStringAsFixed(0) ?? '',
        '"${m.annunciation}"',
        m.crcValid,
        hex(m.raw),
      ].join(','));
    }
    return rows.join('\n');
  }

  @override
  void dispose() {
    _demoTimer?.cancel();
    _scanSub?.cancel();
    _connSub?.cancel();
    super.dispose();
  }
}

String _two(int n) => n.toString().padLeft(2, '0');
String _hms(DateTime t) => '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';
String _dateTime(DateTime t) =>
    '${t.year}-${_two(t.month)}-${_two(t.day)} ${_hms(t)}';
String formatTime(DateTime t) => _hms(t);
