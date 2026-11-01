import 'cgm_parser.dart';

/// Sensor data recorded from a real SmartGuide, replayed by Demo mode.
///
/// File format: `#` comments, `start <hex>` (Session Start Time),
/// `feature <hex>` (CGM Feature), then one CGM Measurement record per line.
class ReplayData {
  const ReplayData(this.start, this.feature, this.records);

  final SessionStartTime start;
  final CgmFeature? feature;
  final List<List<int>> records;
}

List<int> parseHex(String hexString) {
  final s = hexString.replaceAll(RegExp(r'\s'), '');
  if (s.length.isOdd) throw FormatException('Odd-length hex', hexString);
  return [
    for (var i = 0; i < s.length; i += 2)
      int.parse(s.substring(i, i + 2), radix: 16),
  ];
}

ReplayData parseReplay(String text) {
  SessionStartTime? start;
  CgmFeature? feature;
  final records = <List<int>>[];
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    if (line.startsWith('start ')) {
      start = parseSessionStartTime(parseHex(line.substring(6)));
    } else if (line.startsWith('feature ')) {
      feature = parseFeature(parseHex(line.substring(8)));
    } else {
      records.add(parseHex(line));
    }
  }
  if (start == null) throw const FormatException('Replay file has no start line');
  return ReplayData(start, feature, records);
}
