// Parsers for the Bluetooth SIG Continuous Glucose Monitoring Service (0x181F)
// characteristics, as used by the Accu-Chek SmartGuide.
//
// All multi-byte fields are little-endian. Records may end in a 2-byte
// E2E-CRC (CRC-16/MCRF4XX); the SmartGuide sends one on every characteristic.

import 'crc.dart';
import 'sfloat.dart';

int _u16(List<int> b, int i) => (b[i] & 0xFF) | ((b[i + 1] & 0xFF) << 8);

/// 24-bit Sensor Status Annunciation: bits 0-7 status octet,
/// bits 8-15 cal/temp octet, bits 16-23 warning octet.
class SensorAnnunciation {
  const SensorAnnunciation(this.bits);

  final int bits;

  static const _labels = {
    0: 'Session stopped',
    1: 'Device battery low',
    2: 'Sensor type incorrect',
    3: 'Sensor malfunction',
    4: 'Device specific alert',
    5: 'General device fault',
    8: 'Time synchronization required',
    9: 'Calibration not allowed',
    10: 'Calibration recommended',
    11: 'Calibration required',
    12: 'Sensor temperature too high',
    13: 'Sensor temperature too low',
    14: 'Calibration pending',
    16: 'Below patient low level',
    17: 'Above patient high level',
    18: 'Below hypo level',
    19: 'Above hyper level',
    20: 'Rate of decrease exceeded',
    21: 'Rate of increase exceeded',
    22: 'Below device range',
    23: 'Above device range',
  };

  List<String> get labels => [
        for (var bit = 0; bit < 24; bit++)
          if (bits & (1 << bit) != 0) _labels[bit] ?? 'Reserved bit $bit',
      ];

  @override
  String toString() => labels.isEmpty ? 'OK' : labels.join(', ');
}

/// One glucose record from CGM Measurement (0x2AA7).
class CgmMeasurement {
  const CgmMeasurement({
    required this.glucoseMgDl,
    required this.timeOffsetMinutes,
    required this.annunciation,
    required this.raw,
    this.trendMgDlPerMin,
    this.qualityPercent,
    this.crcPresent = false,
    this.crcValid = false,
  });

  /// mg/dL. -infinity means below the sensor's range ("LO"),
  /// +infinity above it ("HI"), NaN means no valid value.
  final double glucoseMgDl;

  /// Minutes since the session (sensor) start.
  final int timeOffsetMinutes;
  final double? trendMgDlPerMin;
  final double? qualityPercent;
  final SensorAnnunciation annunciation;
  final bool crcPresent;
  final bool crcValid;
  final List<int> raw;

  DateTime timeFrom(SessionStartTime start) =>
      start.utc.add(Duration(minutes: timeOffsetMinutes));

  String get glucoseLabel {
    if (glucoseMgDl == double.negativeInfinity) return 'LO';
    if (glucoseMgDl == double.infinity) return 'HI';
    if (glucoseMgDl.isNaN) return '---';
    return glucoseMgDl.round().toString();
  }
}

/// Parses a CGM Measurement notification. One notification may carry
/// several records back to back, each starting with its own size byte.
List<CgmMeasurement> parseMeasurements(List<int> value) {
  final records = <CgmMeasurement>[];
  var i = 0;
  while (i < value.length) {
    final size = value[i];
    if (size < 6 || i + size > value.length) {
      throw FormatException('Bad CGM measurement size $size at $i', value);
    }
    records.add(_parseRecord(value.sublist(i, i + size)));
    i += size;
  }
  return records;
}

CgmMeasurement _parseRecord(List<int> r) {
  final flags = r[1];
  var p = 6;
  var warning = 0, calTemp = 0, status = 0;
  if (flags & 0x20 != 0) warning = r[p++];
  if (flags & 0x40 != 0) calTemp = r[p++];
  if (flags & 0x80 != 0) status = r[p++];
  double? trend, quality;
  if (flags & 0x01 != 0) {
    trend = decodeSfloat(_u16(r, p));
    p += 2;
  }
  if (flags & 0x02 != 0) {
    quality = decodeSfloat(_u16(r, p));
    p += 2;
  }
  final remaining = r.length - p;
  if (remaining != 0 && remaining != 2) {
    throw FormatException('Unexpected $remaining trailing bytes', r);
  }
  return CgmMeasurement(
    glucoseMgDl: decodeSfloat(_u16(r, 2)),
    timeOffsetMinutes: _u16(r, 4),
    trendMgDlPerMin: trend,
    qualityPercent: quality,
    annunciation: SensorAnnunciation(status | calTemp << 8 | warning << 16),
    crcPresent: remaining == 2,
    crcValid: remaining == 2 && hasValidTrailingCrc(r),
    raw: r,
  );
}

/// CGM Session Start Time (0x2AAA). The wall-clock fields are local time
/// of the given time zone; the SmartGuide sends time zone 0 (UTC).
class SessionStartTime {
  const SessionStartTime({
    required this.utc,
    required this.timeZoneQuarterHours,
    required this.dstQuarterHours,
    required this.crcValid,
  });

  final DateTime utc;
  final int timeZoneQuarterHours;

  /// null when the sensor reports DST as unknown (0xFF).
  final int? dstQuarterHours;
  final bool? crcValid;
}

SessionStartTime parseSessionStartTime(List<int> b) {
  if (b.length != 9 && b.length != 11) {
    throw FormatException('Bad session start time length ${b.length}', b);
  }
  final tz = b[7] >= 0x80 ? b[7] - 0x100 : b[7];
  final dst = b[8] == 0xFF ? null : b[8];
  final wallClock = DateTime.utc(_u16(b, 0), b[2], b[3], b[4], b[5], b[6]);
  return SessionStartTime(
    utc: wallClock.subtract(Duration(minutes: 15 * (tz + (dst ?? 0)))),
    timeZoneQuarterHours: tz,
    dstQuarterHours: dst,
    crcValid: b.length == 11 ? hasValidTrailingCrc(b) : null,
  );
}

/// CGM Session Run Time (0x2AAB): expected sensor lifetime in hours.
int parseSessionRunTimeHours(List<int> b) {
  if (b.length != 2 && b.length != 4) {
    throw FormatException('Bad session run time length ${b.length}', b);
  }
  return _u16(b, 0);
}

/// CGM Status (0x2AA9).
class CgmStatus {
  const CgmStatus(this.timeOffsetMinutes, this.annunciation, this.crcValid);

  final int timeOffsetMinutes;
  final SensorAnnunciation annunciation;
  final bool? crcValid;
}

CgmStatus parseStatus(List<int> b) {
  if (b.length != 5 && b.length != 7) {
    throw FormatException('Bad CGM status length ${b.length}', b);
  }
  return CgmStatus(
    _u16(b, 0),
    SensorAnnunciation(b[2] | b[3] << 8 | b[4] << 16),
    b.length == 7 ? hasValidTrailingCrc(b) : null,
  );
}

/// CGM Feature (0x2AA8).
class CgmFeature {
  const CgmFeature(this.bits, this.type, this.sampleLocation);

  final int bits;
  final int type;
  final int sampleLocation;

  static const _labels = {
    0: 'Calibration',
    1: 'Patient high/low alerts',
    2: 'Hypo alerts',
    3: 'Hyper alerts',
    4: 'Rate of change alerts',
    5: 'Device specific alert',
    6: 'Sensor malfunction detection',
    7: 'Sensor temperature detection',
    8: 'Sensor result high/low detection',
    9: 'Low battery detection',
    10: 'Sensor type error detection',
    11: 'General device fault',
    12: 'E2E-CRC',
    13: 'Multiple bond',
    14: 'Multiple sessions',
    15: 'Trend information',
    16: 'Quality',
  };

  bool get e2eCrcSupported => bits & (1 << 12) != 0;
  bool get multipleBondSupported => bits & (1 << 13) != 0;

  List<String> get labels => [
        for (var bit = 0; bit < 24; bit++)
          if (bits & (1 << bit) != 0) _labels[bit] ?? 'Reserved bit $bit',
      ];

  String get typeLabel => switch (type) {
        9 => 'Interstitial fluid',
        _ => 'Type $type',
      };

  String get sampleLocationLabel => switch (sampleLocation) {
        5 => 'Subcutaneous tissue',
        15 => 'Not available',
        _ => 'Location $sampleLocation',
      };
}

CgmFeature parseFeature(List<int> b) {
  if (b.length != 6) {
    throw FormatException('Bad CGM feature length ${b.length}', b);
  }
  return CgmFeature(b[0] | b[1] << 8 | b[2] << 16, b[3] & 0x0F, b[3] >> 4);
}

String hex(List<int> bytes) => bytes
    .map((b) => (b & 0xFF).toRadixString(16).padLeft(2, '0'))
    .join(' ')
    .toUpperCase();
