package dev.antigravity.remote.antigravity_remote

import android.app.Activity
import android.content.Context
import android.content.Intent
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
        private const val MAX_UPLOAD_BYTES = 20 * 1024 * 1024
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
                else -> result.notImplemented()
            }
        }
        registerNetworkWakeCallback()
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
        methodChannel = null
        ioExecutor.shutdownNow()
        super.onDestroy()
    }
}
