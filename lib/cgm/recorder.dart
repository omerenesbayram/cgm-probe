import 'dart:io';

import 'cgm_parser.dart';
import 'replay.dart';

/// Appends sensor data to one text file per sensor, in the replay format
/// (see replay.dart), so a recording can be replayed by Demo mode and used
/// as test data. Each record is written as soon as it arrives, and reopening
/// the file continues where the previous session stopped.
class Recorder {
  Recorder._(this.file, this.previous);

  final File file;

  /// What the file already held when it was opened, or null for a new file.
  final ReplayData? previous;

  final _offsets = <int>{};
  Future<void> _writes = Future.value();

  /// Number of distinct readings in the file.
  int get count => _offsets.length;

  /// Opens (or creates) `<dir>/<sensorName>.txt`.
  static Future<Recorder> open(Directory dir, String sensorName) async {
    await dir.create(recursive: true);
    final file = File('${dir.path}/$sensorName.txt');
    ReplayData? previous;
    if (await file.exists()) {
      try {
        previous = parseReplay(await file.readAsString());
      } on FormatException {
        // A file without a start line yet: nothing to restore.
      }
    }
    final recorder = Recorder._(file, previous);
    if (previous != null) {
      for (final r in previous.records) {
        for (final m in parseMeasurements(r)) {
          recorder._offsets.add(m.timeOffsetMinutes);
        }
      }
    }
    if (!await file.exists()) {
      recorder._append('# Accu-Chek SmartGuide recording of $sensorName. '
          'Format: lib/cgm/replay.dart\n');
    }
    return recorder;
  }

  void writeStart(List<int> raw) => _append('start ${_hex(raw)}\n');

  void writeFeature(List<int> raw) => _append('feature ${_hex(raw)}\n');

  /// Writes [m] unless a reading with the same time offset was already
  /// written (history downloads overlap with live readings).
  void add(CgmMeasurement m) {
    if (_offsets.add(m.timeOffsetMinutes)) _append('${_hex(m.raw)}\n');
  }

  /// Waits until everything so far is on disk.
  Future<void> flush() => _writes;

  void _append(String text) {
    _writes = _writes.then(
        (_) => file.writeAsString(text, mode: FileMode.append, flush: true));
  }

  static String _hex(List<int> raw) => hex(raw).replaceAll(' ', '');
}
