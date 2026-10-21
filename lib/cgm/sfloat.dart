/// IEEE-11073 16-bit SFLOAT: 4-bit signed exponent (high nibble),
/// 12-bit signed mantissa. value = mantissa * 10^exponent.
///
/// Special values map to doubles: NaN / NRes / reserved -> NaN,
/// +INFINITY -> double.infinity, -INFINITY -> double.negativeInfinity.
/// The SmartGuide reports readings below its range ("LO") as -INFINITY.
double decodeSfloat(int raw) {
  raw &= 0xFFFF;
  switch (raw) {
    case 0x07FF: // NaN
    case 0x0800: // NRes
    case 0x0801: // reserved
      return double.nan;
    case 0x07FE:
      return double.infinity;
    case 0x0802:
      return double.negativeInfinity;
  }
  var mantissa = raw & 0x0FFF;
  if (mantissa >= 0x0800) mantissa -= 0x1000;
  var exponent = raw >> 12;
  if (exponent >= 0x8) exponent -= 0x10;
  var value = mantissa.toDouble();
  for (var i = 0; i < exponent.abs(); i++) {
    value = exponent > 0 ? value * 10 : value / 10;
  }
  return value;
}

/// Encodes [value] as SFLOAT with the given decimal [exponent]
/// (used by the demo data source and tests).
int encodeSfloat(double value, {int exponent = 0}) {
  if (value.isNaN) return 0x07FF;
  if (value == double.infinity) return 0x07FE;
  if (value == double.negativeInfinity) return 0x0802;
  var scaled = value;
  for (var i = 0; i < exponent.abs(); i++) {
    scaled = exponent > 0 ? scaled / 10 : scaled * 10;
  }
  final mantissa = scaled.round().clamp(-2046, 2045);
  return ((exponent & 0xF) << 12) | (mantissa & 0x0FFF);
}
