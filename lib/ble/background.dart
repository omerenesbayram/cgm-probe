import 'dart:io' show Platform;

import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Native side: MainActivity.kt.
const _appChannel = MethodChannel('cgm_probe/app');

/// Keeps the app recording while it is in the background or the screen is
/// off. On Android this takes a "foreground service": despite the name, that
/// is how Android lets an app keep working in the background. It must show a
/// notification, and in return Android does not stop the app the way it
/// stops plain background work. The Bluetooth work itself stays in the app;
/// the service only shows the notification and keeps the app alive. It ends
/// when the app is swiped away from the recent apps.
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

  /// Sends the app to the background like Home does, instead of closing it.
  static Future<void> moveAppToBack() async {
    if (!Platform.isAndroid) return;
    await _appChannel.invokeMethod('moveToBack');
  }
}
