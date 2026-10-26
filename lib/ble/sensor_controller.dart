import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, Platform;
import 'dart:math' show min;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodChannel, rootBundle;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../cgm/cgm_parser.dart';
import '../cgm/recorder.dart';
import '../cgm/replay.dart';
import 'background.dart';
import 'cgm_uuids.dart';
import 'saved_sensor.dart';

const replayAsset = 'assets/replay/smartguide_8h.txt';
const demoSensorName = 'AC-DEMO0000001';

/// Native side: MainActivity.kt. Answers Android's pairing request with
/// the PIN so the system's own PIN dialog does not appear.
const _pairingChannel = MethodChannel('cgm_probe/pairing');

enum ProbeState { idle, searching, connecting, connected, reconnecting, demo }

class FoundSensor {
  FoundSensor(BluetoothDevice this.device, this.name,
      {this.rssi, this.alreadyConnected = false});

  /// The pretend sensor used by Demo mode.
  const FoundSensor.simulated(this.name)
      : device = null,
        rssi = -62,
        alreadyConnected = false;

  /// null for the simulated demo sensor.
  final BluetoothDevice? device;
  final String name;
  final int? rssi;

  /// Found via systemDevices: another app on this phone (mySugr) holds
  /// the connection, so we can share it without pairing again.
  final bool alreadyConnected;

  bool get simulated => device == null;
}

class Reading {
  Reading(this.measurement, this.receivedAt, this.sensorTime);

  final CgmMeasurement measurement;
  final DateTime receivedAt;

  /// Session start + time offset; null until the start time is known.
  final DateTime? sensorTime;
}

/// Finds a SmartGuide sensor, pairs (Android), listens to CGM Measurement
/// notifications and records them to a file per sensor.
///
/// After the first connection the sensor is remembered: every app launch
/// reconnects to it, reloads its recording and downloads the readings
/// missed in between, and a lost connection is re-established
/// automatically, until the user taps "Forget sensor".
///
/// The only thing it ever writes to the sensor is a request for stored
/// readings (RACP "report records", what mySugr does to fill gaps). It never
/// uses the sensor's settings control point (SOCP).
class SensorController extends ChangeNotifier {
  ProbeState state = ProbeState.idle;
  String? message;

  /// Keyed by name: the SmartGuide changes its Bluetooth address every few
  /// minutes (resolvable private address), so the newest address wins.
  final found = <String, FoundSensor>{};
  final info = <String, String>{};

  /// Newest first, one per sensor time offset.
  final readings = <Reading>[];
  final log = <String>[];

  /// Set while a real sensor is in use; null in Demo mode.
  Recorder? recorder;
  bool historyBusy = false;

  BluetoothDevice? _device;
  String? _sensorName;
  SessionStartTime? _sessionStart;
  BluetoothCharacteristic? _racp;
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  Timer? _demoTimer;
  bool _demoSearch = false;

  /// True once a sensor is set up: a lost connection is then re-established
  /// automatically until the user forgets the sensor.
  bool _keep = false;
  bool _linking = false;
  bool _reconnecting = false;

  /// The remembered sensor's PIN, for pairing again on its own (see
  /// [_connectKnown]).
  String? _pin;

  String get deviceName => _sensorName ?? 'CGM Probe';

  bool get canDownloadHistory => state == ProbeState.connected && _racp != null;

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

  /// Progress message that keeps the live screen during a reconnection.
  void _progress(String msg) => _set(
      state == ProbeState.reconnecting
          ? ProbeState.reconnecting
          : ProbeState.connecting,
      msg);

  void _resetSession(String name) {
    _sensorName = name;
    info.clear();
    readings.clear();
    _sessionStart = null;
    _racp = null;
    recorder = null;
  }

  // ---------------------------------------------------------------- launch

  /// Called once at app start: reconnects to the remembered sensor.
  Future<void> init() async {
    Background.init();
    final saved = await SavedSensor.load();
    if (saved == null) return;
    _log('Remembered sensor: ${saved.name}');
    _resetSession(saved.name);
    _pin = saved.pin;
    await _openRecording(saved.name);
    _set(ProbeState.reconnecting, 'Reconnecting to ${saved.name}...');
    final d = await _knownDevice(saved);
    _device = d;
    _watch(d);
    _keep = true;
    await Background.start(saved.name);
    unawaited(_reconnectLoop());
  }

  /// Finds the remembered sensor without scanning: Android looks it up in
  /// the paired devices (which follow its changing address), iOS asks for
  /// the devices already connected to the phone.
  Future<BluetoothDevice> _knownDevice(SavedSensor saved) async {
    try {
      final candidates = Platform.isAndroid
          ? await FlutterBluePlus.bondedDevices
          : await FlutterBluePlus.systemDevices([CgmUuids.service]);
      for (final d in candidates) {
        if (d.platformName == saved.name) return d;
      }
    } catch (e) {
      _log('Lookup of known devices failed: $e');
    }
    return BluetoothDevice.fromId(saved.remoteId);
  }

  /// Whether this phone is already paired with the sensor. null means no
  /// pairing step applies (iPhone, or a connection shared with another app).
  /// The demo sensor always asks for a PIN, like a real first pairing.
  Future<bool?> androidPaired(FoundSensor s) async {
    if (s.simulated) return false;
    if (!Platform.isAndroid || s.alreadyConnected) return null;
    return await s.device!.bondState.first == BluetoothBondState.bonded;
  }

  // ---------------------------------------------------------------- search

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
        found[_key(d.platformName, d)] =
            FoundSensor(d, d.platformName, alreadyConnected: true);
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
        final key = _key(name, r.device);
        final previous = found[key];
        if (!isCgm || previous?.alreadyConnected == true) continue;
        if (previous?.device?.remoteId != r.device.remoteId) {
          _log('Advertising: $name (${r.device.remoteId}) ${r.rssi} dBm');
        }
        found[key] = FoundSensor(r.device, name, rssi: r.rssi);
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

  /// Demo mode: a pretend search that finds a simulated sensor, which then
  /// goes through the same PIN dialog and pairing steps as a real one.
  void startDemoSearch() {
    found.clear();
    _demoSearch = true;
    _set(ProbeState.searching, 'Searching (demo)...');
    _demoTimer?.cancel();
    _demoTimer = Timer(const Duration(milliseconds: 1500), () {
      found[demoSensorName] = const FoundSensor.simulated(demoSensorName);
      _log('Advertising: $demoSensorName (simulated)');
      notifyListeners();
      _demoTimer = Timer(const Duration(seconds: 6), stopSearch);
    });
  }

  static String _key(String name, BluetoothDevice d) =>
      name.isEmpty ? d.remoteId.str : name;

  /// Ends a running search early; [search] then finishes on its own.
  Future<void> stopSearch() async {
    if (_demoSearch) {
      _demoSearch = false;
      _demoTimer?.cancel();
      if (state == ProbeState.searching) _set(ProbeState.idle);
      return;
    }
    await FlutterBluePlus.stopScan();
  }

  /// Scans for [name] and returns the sensor at its current address.
  Future<BluetoothDevice> _findByName(String name) async {
    _log('Looking for $name at its current address');
    final match = Completer<BluetoothDevice>();
    final sub = FlutterBluePlus.onScanResults.listen((results) {
      for (final r in results) {
        if (r.advertisementData.advName == name && !match.isCompleted) {
          match.complete(r.device);
        }
      }
    });
    try {
      await FlutterBluePlus.startScan(
          withNames: [name], timeout: const Duration(seconds: 15));
      final d = await match.future.timeout(const Duration(seconds: 15));
      _log('Found $name at ${d.remoteId}');
      return d;
    } on TimeoutException {
      throw StateError('$name not found. Is another phone connected to it?');
    } finally {
      await sub.cancel();
      await FlutterBluePlus.stopScan();
    }
  }

  // --------------------------------------------------------------- connect

  /// First connection to a sensor picked from the search list: connects,
  /// pairs if needed (Android), sets the link up, then remembers the sensor
  /// so later launches reconnect on their own.
  ///
  /// [pin]: the PIN from the applicator cap, asked for before connecting.
  /// [forgetFirst]: remove this phone's old pairing before pairing again,
  /// needed after the sensor has been paired with another phone.
  /// [usePairing]: the phone is already paired and the user chose to keep
  /// that pairing ([pin] may still be given, for automatic re-pairing).
  Future<void> connect(FoundSensor s,
      {String? pin, bool forgetFirst = false, bool usePairing = false}) async {
    await stopSearch();
    if (s.simulated) return _connectDemo(s);

    _keep = false;
    var d = s.device!;
    _device = d;
    _resetSession(s.name);
    final saved = await SavedSensor.load();
    _pin = pin ?? (saved?.name == s.name ? saved?.pin : null);
    _set(ProbeState.connecting, 'Connecting to ${s.name}...');

    try {
      await _openRecording(s.name);
      if (usePairing) {
        d = await _connectKnown(d, s.name);
      } else {
        if (forgetFirst && Platform.isAndroid) {
          _log('Removing this phone\'s old pairing');
          await d.removeBond();
          // Without the old keys the phone can no longer follow the
          // sensor's changing address, so look it up again by name.
          _set(ProbeState.connecting, 'Looking for ${s.name}...');
          d = await _findByName(s.name);
          _device = d;
        }
        _watch(d);
        await d.connect(license: License.nonprofit);
        _log('Connected to ${s.name}');

        // Pair before anything else: the sensor slows the link down after
        // service discovery, and each extra read delays pairing by ~2 s.
        if (Platform.isAndroid && !s.alreadyConnected) {
          await _pairIfNeeded(d, pin);
        }
      }
      await _linkUp(d);

      await SavedSensor(s.name, d.remoteId.str, _pin).save();
      _keep = true;
      _log('Remembered ${s.name}; it will reconnect automatically');
      await Background.start(s.name);
    } catch (e) {
      _log('Connect failed: $e');
      await d.disconnect();
      _set(
        ProbeState.idle,
        usePairing && _pin == null
            ? 'Could not connect: $e\n\nIf the sensor is nearby, this phone '
                'may not be able to follow its changing address. Choose '
                'Re-pair and enter the PIN; the app then pairs again on its '
                'own whenever needed.'
            : 'Could not connect: $e',
      );
    }
  }

  /// Connects to a sensor this phone is already paired with.
  ///
  /// The SmartGuide changes its Bluetooth address every few minutes. Phones
  /// with Bluetooth 4.2+ follow it in hardware; older ones such as the
  /// Nexus 6P (Bluetooth 4.1, Android 8.1) keep dialing the address from
  /// pairing time and time out with error 133. So when a direct connection
  /// fails while the sensor is nearby, pair again with the saved PIN.
  Future<BluetoothDevice> _connectKnown(BluetoothDevice d, String name) async {
    _watch(d);
    try {
      await d.connect(
          license: License.nonprofit, timeout: const Duration(seconds: 20));
      _log('Connected to $name');
      return d;
    } catch (e) {
      _log('Direct connection failed: $e');
      final pin = _pin;
      if (!Platform.isAndroid || pin == null) rethrow;

      // Only touch the pairing when the sensor is in range; otherwise this
      // is just "out of range" and the pairing must stay.
      _progress('Looking for $name...');
      await _findByName(name);
      _log('Sensor is nearby but unreachable at its old address; pairing '
          'again with the saved PIN');
      _progress('Pairing again with the saved PIN...');
      await d.removeBond();
      final fresh = await _findByName(name);
      _device = fresh;
      _watch(fresh);
      await fresh.connect(license: License.nonprofit);
      await _pairIfNeeded(fresh, pin);
      await SavedSensor(name, fresh.remoteId.str, pin).save();
      return fresh;
    }
  }

  /// Logs connection changes, and starts [_reconnectLoop] when an
  /// established connection drops.
  void _watch(BluetoothDevice d) {
    _connSub?.cancel();
    _connSub = d.connectionState.listen((st) {
      _log('Connection state: ${st.name}');
      if (st == BluetoothConnectionState.disconnected &&
          _keep &&
          state == ProbeState.connected) {
        _set(ProbeState.reconnecting,
            'Connection lost. Reconnecting automatically...');
        unawaited(_reconnectLoop());
      }
    });
  }

  /// Reconnects to the remembered sensor until it works or the user forgets
  /// the sensor, waiting a little longer after each failed attempt.
  Future<void> _reconnectLoop() async {
    if (_reconnecting) return;
    _reconnecting = true;
    try {
      for (var attempt = 1; _keep; attempt++) {
        try {
          final d = await _connectKnown(_device!, _sensorName!);
          await _linkUp(d);
          return;
        } catch (e) {
          _log('Reconnect attempt $attempt failed: $e');
          if (!_keep) return;
          await _device?.disconnect(); // drop a half set-up link
          if (!_keep) return;
          final wait = Duration(seconds: min(60, 10 * attempt));
          _set(ProbeState.reconnecting,
              'Sensor not reachable. Trying again in ${wait.inSeconds} s.');
          await Future<void>.delayed(wait);
        }
      }
    } finally {
      _reconnecting = false;
    }
  }

  /// Everything after the link is up, for the first connection and every
  /// reconnection: read the sensor info, subscribe to readings, then
  /// download the readings missed while disconnected.
  Future<void> _linkUp(BluetoothDevice d) async {
    if (_linking) return;
    _linking = true;
    try {
      _progress('Connected. Reading sensor info...');
      final services = await d.discoverServices();
      final chars = {
        for (final svc in services)
          for (final c in svc.characteristics) c.uuid: c,
      };
      _log('Services: ${services.map((e) => e.uuid.str).join(', ')}');

      // These need an encrypted (paired) link.
      await _readCgmInfo(chars);
      final m = chars[CgmUuids.measurement];
      if (m == null) throw StateError('No CGM Measurement characteristic');
      final sub = m.onValueReceived.listen(_onMeasurement);
      d.cancelWhenDisconnected(sub);
      await m.setNotifyValue(true);
      _racp = chars[CgmUuids.racp];
      _log('Subscribed to CGM Measurement');
      _set(ProbeState.connected,
          'Waiting for the next reading (the sensor sends one every 5 minutes).');

      // Catch up on what was missed while the app was closed or the sensor
      // was out of range (the sensor keeps the last 8 hours).
      await downloadHistory(missedOnly: true);

      // Nice to have, and slow: read once.
      if (!info.containsKey('Manufacturer')) {
        for (final entry in CgmUuids.deviceInfo.entries) {
          final c = chars[entry.key];
          if (c == null) continue;
          final v = await _read(c, entry.value);
          if (v != null) info[entry.value] = utf8.decode(v, allowMalformed: true);
        }
        notifyListeners();
      }
    } finally {
      _linking = false;
    }
  }

  Future<void> _pairIfNeeded(BluetoothDevice d, String? pin) async {
    if (await d.bondState.first == BluetoothBondState.bonded) {
      _log('Already paired with this phone');
      return;
    }
    _progress(pin == null
        ? 'Pairing: type the PIN in the Android dialog right away '
            '(the sensor allows only a few seconds).'
        : 'Pairing: entering the PIN automatically...');
    _log(pin == null ? 'Pairing (PIN typed by hand)' : 'Pairing (PIN entered by the app)');
    try {
      if (pin != null) {
        // MainActivity answers the pairing request with this PIN before the
        // system shows its own dialog. The PIN never goes to the log.
        await _pairingChannel.invokeMethod(
            'setPendingPin', {'address': d.remoteId.str, 'pin': pin});
      }
      await d.createBond(timeout: 30);
    } catch (e) {
      // The sensor may close the link right as pairing completes, which
      // can surface here as an error even though the pairing succeeded.
      _log('createBond ended with: $e');
    } finally {
      await _pairingChannel.invokeMethod('clearPendingPin');
    }
    if (await d.bondState.first != BluetoothBondState.bonded) {
      throw StateError('Pairing failed. Check the PIN and try again.');
    }
    _log('Paired');

    // The SmartGuide sometimes closes the connection right after a new
    // pairing (seen 64 ms later on 2026-10-26). Wait briefly for that, then
    // reconnect with the new keys.
    try {
      await d.connectionState
          .where((st) => st == BluetoothConnectionState.disconnected)
          .first
          .timeout(const Duration(seconds: 3));
      _log('Sensor closed the link after pairing; reconnecting');
      _progress('Paired. Reconnecting...');
      await d.connect(license: License.nonprofit);
      _log('Reconnected');
    } on TimeoutException {
      _log('Link stayed open after pairing');
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
      recorder?.writeFeature(v);
      _showFeature(parseFeature(v));
    });
    await decode(CgmUuids.sessionStartTime, 'Session start', (v) {
      recorder?.writeStart(v);
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

  void _showFeature(CgmFeature f) {
    info['Features'] = f.labels.join(', ');
    info['Sample'] = '${f.typeLabel}, ${f.sampleLocationLabel}';
    info['Multiple bonds'] = f.multipleBondSupported ? 'Supported' : 'No';
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

  // ------------------------------------------------------------- recording

  /// Opens this sensor's recording and shows what it already holds.
  /// Android: app-specific external storage, which `adb pull` can read:
  /// /sdcard/Android/data/com.omerb.cgm_probe/files/recordings
  /// iOS: the app's Documents folder.
  Future<void> _openRecording(String sensorName) async {
    try {
      final base = (Platform.isAndroid ? await getExternalStorageDirectory() : null) ??
          await getApplicationDocumentsDirectory();
      final rec = await Recorder.open(Directory('${base.path}/recordings'), sensorName);
      recorder = rec;
      _log('Recording to ${rec.file.path} (${rec.count} readings so far)');
      final previous = rec.previous;
      if (previous == null) return;
      _sessionStart = previous.start;
      if (previous.feature != null) _showFeature(previous.feature!);
      for (final raw in previous.records) {
        for (final m in parseMeasurements(raw)) {
          final t = m.timeFrom(previous.start);
          _addReading(Reading(m, t, t));
        }
      }
      notifyListeners();
    } catch (e) {
      _log('Could not open the recording: $e');
    }
  }

  // -------------------------------------------------------------- readings

  void _onMeasurement(List<int> value) {
    _log('Measurement: ${hex(value)}');
    try {
      final now = DateTime.now();
      for (final m in parseMeasurements(value)) {
        recorder?.add(m);
        final added = _addReading(Reading(
            m, now, _sessionStart == null ? null : m.timeFrom(_sessionStart!)));
        _log('  -> ${m.glucoseLabel} mg/dL, offset ${m.timeOffsetMinutes} min, '
            'CRC ${m.crcValid ? 'ok' : 'BAD'}${added ? '' : ' (duplicate)'}');
      }
      if (!historyBusy && state == ProbeState.connected) message = null;
    } catch (e) {
      _log('  -> could not decode: $e');
    }
    notifyListeners();
  }

  /// Keeps [readings] newest first with one entry per time offset; stored
  /// readings from a history download arrive oldest first, after live ones.
  bool _addReading(Reading r) {
    final offset = r.measurement.timeOffsetMinutes;
    var i = 0;
    while (i < readings.length &&
        readings[i].measurement.timeOffsetMinutes > offset) {
      i++;
    }
    if (i < readings.length &&
        readings[i].measurement.timeOffsetMinutes == offset) {
      return false;
    }
    readings.insert(i, r);
    return true;
  }

  /// Asks the sensor for stored readings (it keeps the last 8 hours) via
  /// the Record Access Control Point. They arrive as ordinary CGM
  /// Measurement notifications, followed by a response code on the RACP.
  ///
  /// [missedOnly]: only readings newer than the newest one we have
  /// (falls back to all stored readings if the sensor refuses the filter).
  Future<void> downloadHistory({bool missedOnly = false}) async {
    final racp = _racp;
    if (racp == null || historyBusy) return;
    historyBusy = true;
    message = missedOnly ? 'Catching up on missed readings...' : 'Downloading stored readings...';
    notifyListeners();
    final before = readings.length;
    try {
      if (!racp.isNotifying) await racp.setNotifyValue(true);
      final from = missedOnly && readings.isNotEmpty
          ? readings.first.measurement.timeOffsetMinutes + 1
          : null;
      var code = await _racpRequest(
          racp,
          from == null
              // Report stored records: all.
              ? [0x01, 0x01]
              // Report stored records: time offset >= from.
              : [0x01, 0x03, 0x01, from & 0xFF, from >> 8]);
      if (from != null && code != 0x01 && code != 0x06) {
        _log('Filtered request refused (code $code); asking for all');
        code = await _racpRequest(racp, [0x01, 0x01]);
      }
      final added = readings.length - before;
      _log('History: $added new readings (response code $code)');
      // Response codes: 01 success, 06 no records found.
      message = code == 0x01 || code == 0x06
          ? (added == 0 ? 'Up to date.' : 'Added $added stored readings.')
          : 'The sensor answered with error code $code.';
    } catch (e) {
      _log('History download failed: $e');
      message = 'History download failed: $e';
    } finally {
      historyBusy = false;
      notifyListeners();
    }
  }

  /// Sends one RACP request and returns the response code from the
  /// `06 00 <op code> <response code>` indication.
  Future<int> _racpRequest(BluetoothCharacteristic racp, List<int> request) async {
    final response = Completer<List<int>>();
    final sub = racp.onValueReceived.listen((v) {
      if (v.isNotEmpty && v[0] == 0x06 && !response.isCompleted) {
        response.complete(v);
      }
    });
    try {
      _log('RACP request: ${hex(request)}');
      await racp.write(request);
      final r = await response.future.timeout(const Duration(seconds: 120));
      _log('RACP response: ${hex(r)}');
      return r.length >= 4 ? r[3] : -1;
    } finally {
      await sub.cancel();
    }
  }

  // ------------------------------------------------------------------ demo

  /// Demo connection: walks through the same steps as a real first pairing,
  /// then replays 8 hours recorded from a real SmartGuide (one record every
  /// 400 ms) through the same decoder.
  Future<void> _connectDemo(FoundSensor s) async {
    _resetSession(s.name);
    final data = parseReplay(await rootBundle.loadString(replayAsset));

    Future<void> step(String text, int ms) async {
      _log('Demo: $text');
      _set(ProbeState.connecting, text);
      await Future<void>.delayed(Duration(milliseconds: ms));
    }

    await step('Connecting to ${s.name}...', 1200);
    await step('Pairing: entering the PIN automatically...', 2500);
    await step('Paired. Reconnecting...', 1000);
    await step('Reading sensor info...', 1200);

    info['Mode'] =
        'Demo: replay of real sensor data (${data.records.length} readings)';
    if (data.feature != null) _showFeature(data.feature!);
    _sessionStart = data.start;
    info['Session start'] = _dateTime(data.start.utc.toLocal());
    _set(ProbeState.demo, 'Waiting for the next reading...');

    var next = 0;
    _demoTimer?.cancel();
    _demoTimer = Timer.periodic(const Duration(milliseconds: 400), (timer) {
      if (next == data.records.length) {
        timer.cancel();
        message = 'Replay finished.';
        notifyListeners();
        return;
      }
      _onMeasurement(data.records[next++]);
    });
  }

  void stopDemo() {
    _demoTimer?.cancel();
    _set(ProbeState.idle);
  }

  // ---------------------------------------------------------------- forget

  /// Disconnects and stops reconnecting on launch. The phone's Bluetooth
  /// pairing and the recording file are kept, so connecting again later
  /// needs no PIN and continues the same recording.
  Future<void> forgetSensor() async {
    _keep = false;
    _pin = null;
    await _connSub?.cancel();
    _connSub = null;
    await _device?.disconnect();
    await recorder?.flush();
    await SavedSensor.clear();
    await Background.stop();
    _log('Forgot ${_sensorName ?? 'sensor'}');
    _device = null;
    _racp = null;
    _set(ProbeState.idle);
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

/// "26.10 18:45", for lists that span several days.
String formatDayTime(DateTime t) =>
    '${_two(t.day)}.${_two(t.month)} ${_two(t.hour)}:${_two(t.minute)}';
