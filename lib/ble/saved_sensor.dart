import 'package:shared_preferences/shared_preferences.dart';

/// The sensor the app reconnects to on every launch, until the user taps
/// "Forget sensor". Stored in the app's private storage.
class SavedSensor {
  const SavedSensor(this.name, this.remoteId, this.pin);

  final String name;

  /// Android: Bluetooth address at pairing time. iOS: CoreBluetooth UUID.
  final String remoteId;

  /// Lets the app pair again on its own on phones that cannot follow the
  /// sensor's changing address (see SensorController._connectKnown).
  final String? pin;

  static const _nameKey = 'sensor.name';
  static const _idKey = 'sensor.remoteId';
  static const _pinKey = 'sensor.pin';

  static Future<SavedSensor?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final name = prefs.getString(_nameKey);
    final id = prefs.getString(_idKey);
    if (name == null || id == null) return null;
    return SavedSensor(name, id, prefs.getString(_pinKey));
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_nameKey, name);
    await prefs.setString(_idKey, remoteId);
    if (pin != null) {
      await prefs.setString(_pinKey, pin!);
    } else {
      await prefs.remove(_pinKey);
    }
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_nameKey);
    await prefs.remove(_idKey);
    await prefs.remove(_pinKey);
  }
}
