/// E2E-CRC used by the Bluetooth CGM Service: CRC-16/MCRF4XX
/// (CCITT polynomial, reflected, init 0xFFFF), sent little-endian.
///
/// Verified against bytes captured from an Accu-Chek SmartGuide sensor.
int crc16Mcrf4xx(List<int> data, [int start = 0, int? end]) {
  var crc = 0xFFFF;
  for (var i = start; i < (end ?? data.length); i++) {
    crc ^= data[i] & 0xFF;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0x8408 : crc >> 1;
    }
  }
  return crc;
}

/// True when the last two bytes of [record] are a valid E2E-CRC
/// over all preceding bytes.
bool hasValidTrailingCrc(List<int> record) {
  if (record.length < 3) return false;
  final n = record.length;
  final stored = record[n - 2] | (record[n - 1] << 8);
  return crc16Mcrf4xx(record, 0, n - 2) == stored;
}

/// Appends a little-endian E2E-CRC to [payload].
List<int> withCrc(List<int> payload) {
  final crc = crc16Mcrf4xx(payload);
  return [...payload, crc & 0xFF, crc >> 8];
}
