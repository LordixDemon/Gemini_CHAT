package dev.antigravity.remote.antigravity_remote

import android.Manifest
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.Uri
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.net.Inet4Address
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL_NAME = "dev.antigravity.remote/android"
        private const val REQ_PICK_ATTACHMENT = 7443
        private const val REQ_NOTIF_PERMISSION = 7444
        private const val MAX_UPLOAD_BYTES = 20 * 1024 * 1024
        private const val CHANNEL_APPROVALS = "agy_approvals"
        private const val CHANNEL_TASKS = "agy_tasks"
    }

    private val ioExecutor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var pendingPickResult: MethodChannel.Result? = null
    private var methodChannel: MethodChannel? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
        methodChannel = channel
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "pickAttachment" -> {
                    val kind = call.argument<String>("kind") ?: "file"
                    launchDocumentPicker(kind, result)
                }
                "discoverMdns" -> {
                    val timeoutMs = (call.argument<Number>("timeoutMs")?.toLong() ?: 1300L)
                        .coerceIn(400L, 5000L)
                    discoverMdnsServices(timeoutMs, result)
                }
                "requestNotificationPermission" -> {
                    result.success(requestNotificationPermissionIfNeeded())
                }
                "showNotification" -> {
                    val id = call.argument<Number>("id")?.toInt() ?: 74431
                    val notifChannel = call.argument<String>("channel") ?: "tasks"
                    val title = call.argument<String>("title") ?: "Antigravity Remote"
                    val body = call.argument<String>("body") ?: ""
                    val convId = call.argument<String>("conversationId")
                    result.success(showLocalNotification(id, notifChannel, title, body, convId))
                }
                "cancelNotification" -> {
                    val id = call.argument<Number>("id")?.toInt()
                    cancelLocalNotification(id)
                    result.success(true)
                }
                "setKeepScreenOn" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    mainHandler.post {
                        try {
                            if (enabled) {
                                window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                            } else {
                                window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                            }
                        } catch (_: Exception) {}
                    }
                    result.success(true)
                }
                "openExternalUrl" -> {
                    val url = call.argument<String>("url")?.trim() ?: ""
                    result.success(openExternalHttpUrl(url))
                }
                else -> result.notImplemented()
            }
        }
        registerNetworkWakeCallback()
    }

    private fun hasNotificationPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true
        return checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
    }

    private fun requestNotificationPermissionIfNeeded(): Boolean {
        if (hasNotificationPermission()) return true
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            try {
                requestPermissions(
                    arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                    REQ_NOTIF_PERMISSION,
                )
            } catch (_: Exception) {}
        }
        return false
    }

    private fun ensureNotificationChannels(nm: NotificationManager) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        if (nm.getNotificationChannel(CHANNEL_APPROVALS) == null) {
            val ch = NotificationChannel(
                CHANNEL_APPROVALS,
                "Запросы разрешений",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "Срочные подтверждения PreToolUse от агента"
                enableVibration(true)
            }
            nm.createNotificationChannel(ch)
        }
        if (nm.getNotificationChannel(CHANNEL_TASKS) == null) {
            val ch = NotificationChannel(
                CHANNEL_TASKS,
                "Статус задач",
                NotificationManager.IMPORTANCE_DEFAULT,
            ).apply {
                description = "Уведомления о завершении фоновых задач агента"
            }
            nm.createNotificationChannel(ch)
        }
    }

    private fun showLocalNotification(
        id: Int,
        channelKey: String,
        title: String,
        body: String,
        conversationId: String?,
    ): Boolean {
        if (!hasNotificationPermission()) return false
        val nm = applicationContext.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            ?: return false
        return try {
            ensureNotificationChannels(nm)
            val channelId = if (channelKey == "approvals") CHANNEL_APPROVALS else CHANNEL_TASKS
            val launchIntent = Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
                if (!conversationId.isNullOrBlank()) {
                    putExtra("conversationId", conversationId)
                }
            }
            val piFlags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            val pendingIntent = PendingIntent.getActivity(this, id, launchIntent, piFlags)

            @Suppress("DEPRECATION")
            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(this, channelId)
            } else {
                Notification.Builder(this)
            }
            val iconRes = applicationInfo.icon.takeIf { it != 0 }
                ?: android.R.drawable.ic_dialog_info
            builder
                .setSmallIcon(iconRes)
                .setContentTitle(title)
                .setContentText(body)
                .setStyle(Notification.BigTextStyle().bigText(body))
                .setAutoCancel(true)
                .setContentIntent(pendingIntent)

            nm.notify(id, builder.build())
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun cancelLocalNotification(id: Int?) {
        val nm = applicationContext.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            ?: return
        try {
            if (id != null) {
                nm.cancel(id)
            } else {
                nm.cancelAll()
            }
        } catch (_: Exception) {}
    }

    private fun openExternalHttpUrl(url: String): Boolean {
        val lower = url.lowercase()
        if (!lower.startsWith("http://") && !lower.startsWith("https://")) return false
        return try {
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
            startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val convId = intent.getStringExtra("conversationId")
        if (!convId.isNullOrBlank()) {
            mainHandler.post {
                try {
                    methodChannel?.invokeMethod(
                        "onNotificationTapped",
                        mapOf("conversationId" to convId),
                    )
                } catch (_: Exception) {}
            }
        }
    }

    private fun registerNetworkWakeCallback() {
        unregisterNetworkWakeCallback()
        val cm = applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            ?: return
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                mainHandler.post {
                    try {
                        methodChannel?.invokeMethod("onNetworkAvailable", mapOf("reason" to "available"))
                    } catch (_: Exception) {}
                }
            }

            override fun onBlockedStatusChanged(network: Network, blocked: Boolean) {
                if (!blocked) {
                    mainHandler.post {
                        try {
                            methodChannel?.invokeMethod("onNetworkAvailable", mapOf("reason" to "unblocked"))
                        } catch (_: Exception) {}
                    }
                }
            }
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                cm.registerDefaultNetworkCallback(cb)
                networkCallback = cb
            }
        } catch (_: Exception) {}
    }

    private fun unregisterNetworkWakeCallback() {
        val cb = networkCallback ?: return
        networkCallback = null
        try {
            val cm = applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            cm?.unregisterNetworkCallback(cb)
        } catch (_: Exception) {}
    }

    private fun launchDocumentPicker(kind: String, result: MethodChannel.Result) {
        if (pendingPickResult != null) {
            result.error("BUSY", "Another file picker request is already active", null)
            return
        }
        pendingPickResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = if (kind == "image") "image/*" else "*/*"
        }
        try {
            @Suppress("DEPRECATION")
            startActivityForResult(intent, REQ_PICK_ATTACHMENT)
        } catch (e: Exception) {
            pendingPickResult = null
            result.error("PICKER_FAILED", e.message, null)
        }
    }

    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != REQ_PICK_ATTACHMENT) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        val callback = pendingPickResult
        pendingPickResult = null
        if (callback == null) return

        val uri: Uri? = if (resultCode == Activity.RESULT_OK) data?.data else null
        if (uri == null) {
            callback.success(null)
            return
        }

        ioExecutor.execute {
            try {
                val resolver = applicationContext.contentResolver
                var displayName = "attachment.bin"
                resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)
                    ?.use { cursor ->
                        if (cursor.moveToFirst()) {
                            val nameIdx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                            if (nameIdx >= 0 && !cursor.isNull(nameIdx)) {
                                displayName = cursor.getString(nameIdx) ?: displayName
                            }
                            val sizeIdx = cursor.getColumnIndex(OpenableColumns.SIZE)
                            if (sizeIdx >= 0 && !cursor.isNull(sizeIdx)) {
                                val reportedSize = cursor.getLong(sizeIdx)
                                if (reportedSize > MAX_UPLOAD_BYTES) {
                                    throw IllegalArgumentException("Файл превышает лимит 20 МБ")
                                }
                            }
                        }
                    }

                val mimeType = resolver.getType(uri) ?: "application/octet-stream"
                val out = ByteArrayOutputStream()
                resolver.openInputStream(uri)?.use { input ->
                    val buf = ByteArray(16 * 1024)
                    var total = 0
                    while (true) {
                        val read = input.read(buf)
                        if (read <= 0) break
                        total += read
                        if (total > MAX_UPLOAD_BYTES) {
                            throw IllegalArgumentException("Файл превышает лимит 20 МБ")
                        }
                        out.write(buf, 0, read)
                    }
                } ?: throw IllegalStateException("Не удалось прочитать выбранный файл")

                val bytes = out.toByteArray()
                val payload = mapOf(
                    "fileName" to displayName,
                    "mimeType" to mimeType,
                    "bytes" to bytes,
                    "sizeBytes" to bytes.size,
                )
                mainHandler.post { callback.success(payload) }
            } catch (e: Exception) {
                mainHandler.post {
                    callback.error("READ_FAILED", e.message ?: "Ошибка чтения файла", null)
                }
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun discoverMdnsServices(timeoutMs: Long, result: MethodChannel.Result) {
        val nsdManager = applicationContext.getSystemService(Context.NSD_SERVICE) as? NsdManager
        if (nsdManager == null) {
            result.success(emptyList<Map<String, Any>>())
            return
        }

        val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
        val multicastLock = try {
            wifiManager?.createMulticastLock("agy_remote_mdns")?.apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (_: Exception) {
            null
        }

        val found = ConcurrentHashMap<String, Map<String, Any>>()
        val resolveQueue = ConcurrentLinkedQueue<NsdServiceInfo>()
        val resolving = AtomicBoolean(false)
        val finished = AtomicBoolean(false)

        fun pumpResolveQueue() {
            if (finished.get()) return
            if (!resolving.compareAndSet(false, true)) return
            val next = resolveQueue.poll()
            if (next == null) {
                resolving.set(false)
                return
            }
            try {
                nsdManager.resolveService(next, object : NsdManager.ResolveListener {
                    override fun onResolveFailed(serviceInfo: NsdServiceInfo?, errorCode: Int) {
                        resolving.set(false)
                        pumpResolveQueue()
                    }

                    override fun onServiceResolved(serviceInfo: NsdServiceInfo?) {
                        if (serviceInfo != null) {
                            val hostAddr = serviceInfo.host
                            val ip = if (hostAddr is Inet4Address) {
                                hostAddr.hostAddress
                            } else {
                                hostAddr?.hostAddress?.takeIf { !it.contains(':') }
                            }
                            val port = serviceInfo.port
                            if (!ip.isNullOrBlank() && port > 0) {
                                val attrs = serviceInfo.attributes
                                val machineId = attrs["m"]?.let { String(it, Charsets.UTF_8) } ?: ""
                                val machineName = attrs["n"]?.let { String(it, Charsets.UTF_8) }
                                    ?: serviceInfo.serviceName
                                    ?: ip
                                found["$ip:$port"] = mapOf(
                                    "host" to ip,
                                    "port" to port,
                                    "machineId" to machineId,
                                    "machineName" to machineName,
                                )
                            }
                        }
                        resolving.set(false)
                        pumpResolveQueue()
                    }
                })
            } catch (_: Exception) {
                resolving.set(false)
                pumpResolveQueue()
            }
        }

        val discoveryListener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(regType: String?) {}
            override fun onServiceFound(service: NsdServiceInfo?) {
                if (service != null && !finished.get()) {
                    resolveQueue.add(service)
                    pumpResolveQueue()
                }
            }
            override fun onServiceLost(service: NsdServiceInfo?) {}
            override fun onDiscoveryStopped(serviceType: String?) {}
            override fun onStartDiscoveryFailed(serviceType: String?, errorCode: Int) {}
            override fun onStopDiscoveryFailed(serviceType: String?, errorCode: Int) {}
        }

        try {
            nsdManager.discoverServices("_agy-remote._tcp.", NsdManager.PROTOCOL_DNS_SD, discoveryListener)
        } catch (_: Exception) {
            try {
                if (multicastLock?.isHeld == true) multicastLock.release()
            } catch (_: Exception) {}
            result.success(emptyList<Map<String, Any>>())
            return
        }

        mainHandler.postDelayed({
            if (finished.compareAndSet(false, true)) {
                try {
                    nsdManager.stopServiceDiscovery(discoveryListener)
                } catch (_: Exception) {}
                try {
                    if (multicastLock?.isHeld == true) multicastLock.release()
                } catch (_: Exception) {}
                result.success(found.values.toList())
            }
        }, timeoutMs)
    }

    override fun onResume() {
        super.onResume()
        mainHandler.post {
            try {
                methodChannel?.invokeMethod("onNativeResumed", null)
            } catch (_: Exception) {}
        }
    }

    override fun onStop() {
        super.onStop()
        if (pendingPickResult == null) {
            mainHandler.post {
                try {
                    methodChannel?.invokeMethod("onNativePaused", null)
                } catch (_: Exception) {}
            }
        }
    }

    override fun onDestroy() {
        unregisterNetworkWakeCallback()
        try {
            pendingPickResult?.success(null)
        } catch (_: Exception) {}
        pendingPickResult = null
        mainHandler.removeCallbacksAndMessages(null)
        methodChannel = null
        ioExecutor.shutdownNow()
        super.onDestroy()
    }
}
