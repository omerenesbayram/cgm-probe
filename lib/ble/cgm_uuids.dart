import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// Bluetooth SIG UUIDs used by the Accu-Chek SmartGuide.
abstract final class CgmUuids {
  static final service = Guid('181F');
  static final measurement = Guid('2AA7');
  static final feature = Guid('2AA8');
  static final status = Guid('2AA9');
  static final sessionStartTime = Guid('2AAA');
  static final sessionRunTime = Guid('2AAB');
  static final racp = Guid('2A52');
  static final socp = Guid('2AAC');

  /// Device Information service strings, shown on the info card.
  static final deviceInfo = {
    Guid('2A29'): 'Manufacturer',
    Guid('2A24'): 'Model',
    Guid('2A25'): 'Serial number',
    Guid('2A27'): 'Hardware revision',
    Guid('2A26'): 'Firmware revision',
    Guid('2A28'): 'Software revision',
  };
}

/// SmartGuide sensors advertise as `AC-<serial>`.
bool looksLikeSmartGuide(String name) => name.startsWith('AC-');
