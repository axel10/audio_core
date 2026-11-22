package com.flutter_rust_bridge.audio_core

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import org.json.JSONObject
import java.nio.ByteBuffer

/**
 * Manages Android USB Audio device discovery, permission prompts, hotplug
 * lifecycle, and exclusive ownership via [UsbExclusiveNative].
 */
class UsbExclusiveManager(
    private val context: Context,
    private val onStateChanged: (eventType: String, statusJson: String) -> Unit,
) {
    companion object {
        private const val ACTION_USB_PERMISSION =
            "com.flutter_rust_bridge.audio_core.USB_EXCLUSIVE_PERMISSION"
        private const val PREFS_NAME = "vynody_usb_exclusive_prefs"
        private const val KEY_WAS_EXCLUSIVE_ACTIVE = "was_exclusive_active"
        private const val KEY_LAST_EXCLUSIVE_VID_PID = "last_exclusive_vid_pid"
    }

    private val usbManager: UsbManager? =
        context.getSystemService(Context.USB_SERVICE) as? UsbManager
    private val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val audioKeepAlive = UsbExclusiveAudioKeepAlive(context)

    @Volatile
    var isExclusiveActive: Boolean = false
        private set

    private var activeConnection: UsbDeviceConnection? = null
    private var activeDeviceName: String? = null
    private var pendingPermissionCallback: ((Boolean, String?) -> Unit)? = null
    private var pendingPermissionDeviceName: String? = null
    private var receiversRegistered = false

    private val usbReceiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context?, intent: Intent?) {
            val action = intent?.action ?: return
            when (action) {
                ACTION_USB_PERMISSION -> {
                    val device = extractUsbDevice(intent)
                    val granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
                    val callback = pendingPermissionCallback
                    pendingPermissionCallback = null
                    pendingPermissionDeviceName = null

                    if (!granted || device == null) {
                        callback?.invoke(false, "USB permission denied by user")
                        return
                    }

                    val (ok, err) = attachDeviceInternal(device)
                    callback?.invoke(ok, err)
                }

                UsbManager.ACTION_USB_DEVICE_ATTACHED -> {
                    val device = extractUsbDevice(intent)
                    if (device != null && isUsbAudioDevice(device)) {
                        NativeLog.d("UsbExclusive", "USB audio device attached: ${displayName(device)}")
                        notifyStateChanged("device_attached")
                    }
                }

                UsbManager.ACTION_USB_DEVICE_DETACHED -> {
                    val device = extractUsbDevice(intent)
                    if (device != null && device.deviceName == activeDeviceName) {
                        NativeLog.d("UsbExclusive", "Active exclusive USB DAC detached: ${displayName(device)}")
                        disableExclusiveModeInternal(notifyEvent = "device_detached")
                    } else if (device != null && isUsbAudioDevice(device)) {
                        notifyStateChanged("device_detached")
                    }
                }
            }
        }
    }

    fun startListening() {
        if (receiversRegistered) return
        val filter = IntentFilter().apply {
            addAction(ACTION_USB_PERMISSION)
            addAction(UsbManager.ACTION_USB_DEVICE_ATTACHED)
            addAction(UsbManager.ACTION_USB_DEVICE_DETACHED)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(usbReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            context.registerReceiver(usbReceiver, filter)
        }
        receiversRegistered = true
        restoreKernelDriverIfUncleanExit()
    }

    fun stopListening() {
        disableExclusiveModeInternal(notifyEvent = null)
        if (receiversRegistered) {
            try {
                context.unregisterReceiver(usbReceiver)
            } catch (_: Throwable) {
            }
            receiversRegistered = false
        }
    }

    fun listUsbAudioDevices(): List<Map<String, Any?>> {
        val manager = usbManager ?: return emptyList()
        return manager.deviceList.values
            .filter { isUsbAudioDevice(it) }
            .map { dev ->
                mapOf(
                    "deviceName" to dev.deviceName,
                    "productName" to displayName(dev),
                    "manufacturerName" to (dev.manufacturerName ?: ""),
                    "vendorId" to dev.vendorId,
                    "productId" to dev.productId,
                    "hasPermission" to manager.hasPermission(dev),
                    "isActiveExclusive" to (isExclusiveActive && dev.deviceName == activeDeviceName),
                )
            }
    }

    fun enableExclusiveMode(
        targetDeviceName: String?,
        callback: (ok: Boolean, error: String?) -> Unit,
    ) {
        val manager = usbManager
        if (manager == null) {
            callback(false, "UsbManager unavailable on this device")
            return
        }

        val candidates = manager.deviceList.values.filter { isUsbAudioDevice(it) }
        val device = if (!targetDeviceName.isNullOrBlank()) {
            candidates.firstOrNull { it.deviceName == targetDeviceName }
        } else {
            candidates.firstOrNull()
        }

        if (device == null) {
            callback(false, "No USB Audio DAC connected")
            return
        }

        if (isExclusiveActive && activeDeviceName == device.deviceName) {
            callback(true, null)
            return
        }

        if (manager.hasPermission(device)) {
            val (ok, err) = attachDeviceInternal(device)
            callback(ok, err)
            return
        }

        pendingPermissionCallback?.invoke(false, "Superseded by a new USB permission request")
        pendingPermissionCallback = callback
        pendingPermissionDeviceName = device.deviceName

        val permIntent = Intent(ACTION_USB_PERMISSION).apply {
            setPackage(context.packageName)
        }
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        val pendingIntent = PendingIntent.getBroadcast(context, 0, permIntent, flags)
        manager.requestPermission(device, pendingIntent)
    }

    fun disableExclusiveMode() {
        disableExclusiveModeInternal(notifyEvent = "exclusive_disabled")
    }

    fun getStatusJson(): String = UsbExclusiveNative.nativeGetStatusJson()

    /**
     * Configures the source format for the low-volume real-PCM keep-alive
     * [AudioTrack] used during active USB exclusive playback.
     */
    fun configureKeepAlive(sampleRate: Int, channelCount: Int) {
        audioKeepAlive.configure(sampleRate, channelCount)
    }

    /**
     * Toggles the low-volume [AudioTrack] keep-alive anchor used during active
     * USB exclusive playback so OEM power managers do not freeze the process on
     * screen-off.
     */
    fun setKeepAliveActive(active: Boolean) {
        if (active && isExclusiveActive) {
            audioKeepAlive.start()
        } else {
            audioKeepAlive.stop()
        }
    }

    /**
     * Feeds interleaved Float32 PCM (native byte order) to the keep-alive
     * [AudioTrack] without blocking.
     */
    fun feedKeepAliveFloatPcm(floatPcm: ByteBuffer, sourceChannels: Int) {
        if (!isExclusiveActive) return
        audioKeepAlive.feedFloatPcm(floatPcm, sourceChannels)
    }

    private fun attachDeviceInternal(device: UsbDevice): Pair<Boolean, String?> {
        val manager = usbManager ?: return Pair(false, "UsbManager unavailable")

        // Release any previous connection first.
        disableExclusiveModeInternal(notifyEvent = null)

        val connection = manager.openDevice(device)
            ?: return Pair(false, "UsbManager.openDevice() returned null")

        val fd = connection.fileDescriptor
        if (fd < 0) {
            connection.close()
            return Pair(false, "Invalid USB file descriptor: $fd")
        }

        val name = displayName(device)
        val rawResult = UsbExclusiveNative.nativeRegisterDevice(
            fd = fd,
            vendorId = device.vendorId,
            productId = device.productId,
            deviceName = name,
        )

        val parsed = try {
            JSONObject(rawResult)
        } catch (e: Throwable) {
            connection.close()
            return Pair(false, "Invalid native registration response: $rawResult")
        }

        if (!parsed.optBoolean("ok", false)) {
            val err = parsed.optString("error", "Unknown USB DAC registration error")
            connection.close()
            return Pair(false, err)
        }

        activeConnection = connection
        activeDeviceName = device.deviceName
        isExclusiveActive = true
        persistExclusiveSessionFlag(active = true, device = device)
        notifyStateChanged("exclusive_enabled")
        return Pair(true, null)
    }

    private fun disableExclusiveModeInternal(notifyEvent: String?) {
        val wasActive = isExclusiveActive || activeConnection != null
        isExclusiveActive = false
        activeDeviceName = null
        audioKeepAlive.stop()
        try {
            UsbExclusiveNative.nativeClearDevice()
        } catch (t: Throwable) {
            NativeLog.d("UsbExclusive", "nativeClearDevice error: ${t.message}")
        }
        try {
            activeConnection?.close()
        } catch (_: Throwable) {
        }
        activeConnection = null
        if (wasActive) {
            persistExclusiveSessionFlag(active = false, device = null)
        }
        if (wasActive && notifyEvent != null) {
            notifyStateChanged(notifyEvent)
        }
    }

    private fun deviceVidPidKey(device: UsbDevice): String =
        String.format("%04X:%04X", device.vendorId, device.productId)

    private fun persistExclusiveSessionFlag(active: Boolean, device: UsbDevice?) {
        prefs.edit().apply {
            putBoolean(KEY_WAS_EXCLUSIVE_ACTIVE, active)
            if (active && device != null) {
                putString(KEY_LAST_EXCLUSIVE_VID_PID, deviceVidPidKey(device))
            }
            apply()
        }
    }

    /**
     * If the previous process was force-stopped or crashed while USB exclusive
     * mode was active, `snd-usb-audio` could not be re-attached on exit, leaving
     * normal system audio playback silent until the DAC is replugged.
     *
     * On next startup, silently disconnect any stale `usbfs` claim and re-attach
     * `snd-usb-audio` for the previously owned DAC (only when permission is
     * already granted, so no permission prompt is shown and other apps' active
     * exclusive sessions are never disturbed).
     */
    private fun restoreKernelDriverIfUncleanExit() {
        if (!prefs.getBoolean(KEY_WAS_EXCLUSIVE_ACTIVE, false)) return
        val lastVidPid = prefs.getString(KEY_LAST_EXCLUSIVE_VID_PID, null)
        persistExclusiveSessionFlag(active = false, device = null)

        val manager = usbManager ?: return
        val targetDevice = manager.deviceList.values.firstOrNull { dev ->
            isUsbAudioDevice(dev) &&
                manager.hasPermission(dev) &&
                (lastVidPid == null || deviceVidPidKey(dev) == lastVidPid)
        } ?: return

        Thread({
            if (isExclusiveActive) return@Thread
            var conn: UsbDeviceConnection? = null
            try {
                conn = manager.openDevice(targetDevice) ?: return@Thread
                val fd = conn.fileDescriptor
                if (fd < 0 || isExclusiveActive) return@Thread
                val restored = UsbExclusiveNative.nativeRestoreKernelDriver(fd)
                NativeLog.d(
                    "UsbExclusive",
                    "Recovered USB DAC after unclean exit (${displayName(targetDevice)}): restored=$restored",
                )
            } catch (t: Throwable) {
                NativeLog.d("UsbExclusive", "restoreKernelDriverIfUncleanExit error: ${t.message}")
            } finally {
                try {
                    conn?.close()
                } catch (_: Throwable) {
                }
            }
        }, "UsbExclusiveRestore").start()
    }

    private fun notifyStateChanged(eventType: String) {
        val statusJson = getStatusJson()
        mainHandler.post {
            onStateChanged(eventType, statusJson)
        }
    }

    private fun isUsbAudioDevice(device: UsbDevice): Boolean {
        if (device.deviceClass == UsbConstants.USB_CLASS_AUDIO) return true
        for (i in 0 until device.interfaceCount) {
            if (device.getInterface(i).interfaceClass == UsbConstants.USB_CLASS_AUDIO) {
                return true
            }
        }
        return false
    }

    private fun displayName(device: UsbDevice): String {
        val product = device.productName?.trim().orEmpty()
        val manufacturer = device.manufacturerName?.trim().orEmpty()
        return when {
            product.isNotEmpty() && manufacturer.isNotEmpty() && !product.startsWith(manufacturer, ignoreCase = true) ->
                "$manufacturer $product"
            product.isNotEmpty() -> product
            manufacturer.isNotEmpty() -> manufacturer
            else -> "USB Audio DAC (${String.format("%04X:%04X", device.vendorId, device.productId)})"
        }
    }

    @Suppress("DEPRECATION")
    private fun extractUsbDevice(intent: Intent): UsbDevice? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
        } else {
            intent.getParcelableExtra(UsbManager.EXTRA_DEVICE)
        }
    }
}
