import 'package:cgm_probe/cgm/cgm_parser.dart';
import 'package:cgm_probe/cgm/crc.dart';
import 'package:cgm_probe/cgm/sfloat.dart';
import 'package:flutter_test/flutter_test.dart';

List<int> bytes(String hexString) => [
      for (var i = 0; i < hexString.replaceAll(' ', '').length; i += 2)
        int.parse(hexString.replaceAll(' ', '').substring(i, i + 2), radix: 16),
    ];

// Captured with nRF Connect from a SmartGuide sensor on 2026-10-20 16:27
// (Turkey, UTC+3). mySugr showed 94 mg/dL with a flat arrow.
final measurement = bytes('0D 43 5E 00 6E 28 02 05 E0 59 00 78 53');
final status = bytes('6C 28 00 02 00 30 BF');
final sessionStart = bytes('EA 07 0A 0D 08 37 05 00 FF 15 48');
final runTime = bytes('50 01 C6 32');

void main() {
  group('E2E-CRC', () {
    test('matches captured sensor records', () {
      for (final record in [measurement, status, sessionStart, runTime]) {
        expect(hasValidTrailingCrc(record), isTrue, reason: hex(record));
      }
    });

    test('matches SOCP commands from Juggluco', () {
      expect(withCrc([0x02]), bytes('02 95 2C'));
      expect(withCrc([0x05, 0x00, 0x00]), bytes('05 00 00 8E 00'));
      expect(hasValidTrailingCrc(bytes('03 05 7D 8D')), isTrue);
    });

    test('detects corruption', () {
      final bad = [...measurement]..[2] = 0x5F;
      expect(hasValidTrailingCrc(bad), isFalse);
    });
  });

  group('SFLOAT', () {
    test('decodes plain and scaled values', () {
      expect(decodeSfloat(0x005E), 94);
      expect(decodeSfloat(0xE005), closeTo(0.05, 1e-9));
      expect(decodeSfloat(0x0FFF), -1); // negative mantissa
    });

    test('decodes special values', () {
      expect(decodeSfloat(0x0802), double.negativeInfinity);
      expect(decodeSfloat(0x07FE), double.infinity);
      expect(decodeSfloat(0x07FF), isNaN);
    });

    test('round-trips through encode', () {
      expect(decodeSfloat(encodeSfloat(123)), 123);
      expect(decodeSfloat(encodeSfloat(-1.25, exponent: -2)),
          closeTo(-1.25, 1e-9));
    });
  });

  group('CGM Measurement', () {
    test('decodes the captured reading', () {
      final records = parseMeasurements(measurement);
      expect(records, hasLength(1));
      final m = records.single;
      expect(m.glucoseMgDl, 94);
      expect(m.glucoseLabel, '94');
      expect(m.timeOffsetMinutes, 10350);
      expect(m.trendMgDlPerMin, closeTo(0.05, 1e-9));
      expect(m.qualityPercent, 89);
      expect(m.annunciation.labels, ['Calibration not allowed']);
      expect(m.crcPresent, isTrue);
      expect(m.crcValid, isTrue);
    });

    test('splits multiple records in one notification', () {
      final records = parseMeasurements([...measurement, ...measurement]);
      expect(records, hasLength(2));
    });

    test('labels LO readings', () {
      final lo = withCrc(bytes('08 00 02 08 10 00'));
      expect(parseMeasurements(lo).single.glucoseLabel, 'LO');
    });

    test('rejects truncated data', () {
      expect(() => parseMeasurements(measurement.sublist(0, 8)),
          throwsFormatException);
    });
  });

  group('Session and status', () {
    test('session start is 2026-10-13 08:55:05 UTC', () {
      final s = parseSessionStartTime(sessionStart);
      expect(s.utc, DateTime.utc(2026, 10, 13, 8, 55, 5));
      expect(s.timeZoneQuarterHours, 0);
      expect(s.dstQuarterHours, isNull);
      expect(s.crcValid, isTrue);
    });

    test('reading time lines up with the capture time', () {
      final m = parseMeasurements(measurement).single;
      final t = m.timeFrom(parseSessionStartTime(sessionStart));
      // 16:25:05 in Turkey (UTC+3), two minutes before the screenshot.
      expect(t, DateTime.utc(2026, 10, 20, 13, 25, 5));
    });

    test('run time is 14 days', () {
      expect(parseSessionRunTimeHours(runTime), 336);
    });

    test('status decodes', () {
      final s = parseStatus(status);
      expect(s.timeOffsetMinutes, 10348);
      expect(s.annunciation.labels, ['Calibration not allowed']);
      expect(s.crcValid, isTrue);
    });
  });

  group('CGM Feature', () {
    test('reads capability bits', () {
      // E2E-CRC (bit 12) + trend (15) + quality (16), ISF, subcutaneous.
      final f = parseFeature(withCrc([0x00, 0x90, 0x01, 0x59]));
      expect(f.e2eCrcSupported, isTrue);
      expect(f.multipleBondSupported, isFalse);
      expect(f.typeLabel, 'Interstitial fluid');
      expect(f.sampleLocationLabel, 'Subcutaneous tissue');
    });
  });
}
