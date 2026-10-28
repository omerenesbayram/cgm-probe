package com.omerb.cgm_probe

import android.bluetooth.BluetoothDevice
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Answers Android's pairing request with the PIN the user already typed in
 * the app, so the system's "Pair & connect" notification and PIN dialog
 * never appear.
 *
 * ACTION_PAIRING_REQUEST is an ordered broadcast: this receiver runs before
 * the Settings app's (higher priority), enters the PIN and stops the
 * broadcast there.
 */
class MainActivity : FlutterActivity() {
    private var pendingAddress: String? = null
    private var pendingPin: ByteArray? = null

    private val pairingReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val pin = pendingPin ?: return
            // The typed getParcelableExtra is unreliable on Android 13, so
            // use it from 14 on, as androidx's IntentCompat does.
            val device = if (Build.VERSION.SDK_INT >= 34) {
                intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
            } ?: return
            if (!device.address.equals(pendingAddress, ignoreCase = true)) return
            // The SmartGuide asks for a passkey, which Android delivers as
            // the PIN variant. Leave any other kind of request to the system.
            val variant = intent.getIntExtra(BluetoothDevice.EXTRA_PAIRING_VARIANT, -1)
            if (variant != BluetoothDevice.PAIRING_VARIANT_PIN) return
            try {
                if (device.setPin(pin)) {
                    pendingPin = null
                    if (isOrderedBroadcast) abortBroadcast()
                }
            } catch (_: SecurityException) {
                // No Bluetooth permission: the system dialog still works.
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "cgm_probe/pairing")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setPendingPin" -> {
                        pendingAddress = call.argument<String>("address")
                        pendingPin = call.argument<String>("pin")?.toByteArray(Charsets.US_ASCII)
                        result.success(null)
                    }
                    "clearPendingPin" -> {
                        pendingAddress = null
                        pendingPin = null
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        // Back on the main screen while recording: go to the background
        // instead of closing, which would stop the recording.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "cgm_probe/app")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "moveToBack" -> {
                        moveTaskToBack(true)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        val filter = IntentFilter(BluetoothDevice.ACTION_PAIRING_REQUEST).apply {
            priority = IntentFilter.SYSTEM_HIGH_PRIORITY - 1
        }
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(pairingReceiver, filter, Context.RECEIVER_EXPORTED)
        } else {
            registerReceiver(pairingReceiver, filter)
        }
    }

    override fun onDestroy() {
        unregisterReceiver(pairingReceiver)
        super.onDestroy()
    }
}
