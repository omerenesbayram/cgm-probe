import 'dart:io' show Platform;

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Android foreground service that keeps the app process alive (screen off,
/// app in the background) while a sensor is connected. The Bluetooth work
/// itself stays in the app; the service only shows a notification and keeps
/// Android from stopping the app. It ends when the app is closed.
///
/// iOS needs no service: the bluetooth-central background mode in
/// Info.plist lets the app receive readings in the background.
abstract final class Background {
  static void init() {
    if (!Platform.isAndroid) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'cgm_recording',
        channelName: 'Glucose recording',
        channelDescription: 'Shown while the app receives sensor readings.',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWakeLock: true,
        stopWithTask: true,
      ),
    );
  }

  static Future<void> start(String sensorName) async {
    if (!Platform.isAndroid) return;
    if (await FlutterForegroundTask.checkNotificationPermission() !=
        NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
    if (await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.startService(
      serviceTypes: [ForegroundServiceTypes.connectedDevice],
      notificationTitle: 'Recording glucose',
      notificationText: 'Receiving readings from $sensorName',
    );
  }

  static Future<void> stop() async {
    if (!Platform.isAndroid) return;
    await FlutterForegroundTask.stopService();
  }
}
