package com.aitechdb.ghostchat

import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val METHOD_CHANNEL = "com.aitechdb.ghostchat/native"

    // Puntatore opaco al QuickTunnelCtx lato Rust.
    private var tunnelCtx: Long = 0L

    init {
        System.loadLibrary("qttunnel")
        System.loadLibrary("qttunnel_jni")
    }

    // Funzioni native (Rust FFI)
    private external fun quick_tunnel_start(port: Int): Long
    private external fun quick_tunnel_url(ctx: Long): String?
    private external fun quick_tunnel_stop(ctx: Long)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Blocca screenshot e registrazione schermo.
        // Necessario perche' la schermata mostra passphrase e codici invito.
        window.setFlags(
            WindowManager.LayoutParams.FLAG_SECURE,
            WindowManager.LayoutParams.FLAG_SECURE
        )
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startTunnel" -> {
                        val port = call.argument<Int>("port") ?: 8080
                        Thread {
                            try {
                                val ctx = quick_tunnel_start(port)
                                if (ctx == 0L) {
                                    runOnUiThread {
                                        result.error("TUNNEL_START_FAILED",
                                            "quick_tunnel_start ha ritornato NULL", null)
                                    }
                                    return@Thread
                                }
                                tunnelCtx = ctx
                                val url = quick_tunnel_url(ctx)
                                runOnUiThread {
                                    if (url != null) result.success(url)
                                    else result.error("URL_NULL",
                                        "quick_tunnel_url ha ritornato NULL", null)
                                }
                            } catch (e: Throwable) {
                                runOnUiThread {
                                    result.error("TUNNEL_FAILED", e.message, null)
                                }
                            }
                        }.start()
                    }

                    "stopTunnel" -> {
                        val ctx = tunnelCtx
                        tunnelCtx = 0L
                        if (ctx != 0L) {
                            Thread {
                                try {
                                    quick_tunnel_stop(ctx)
                                } catch (_: Throwable) {}
                            }.start()
                        }
                        stopForegroundService()
                        result.success(true)
                    }

                    "startForegroundService" -> {
                        val url = call.argument<String>("url")
                        startForegroundServiceInternal(url)
                        result.success(true)
                    }

                    "stopForegroundService" -> {
                        stopForegroundService()
                        result.success(true)
                    }

                    "isForegroundServiceRunning" -> {
                        result.success(GhostChatService.isRunning)
                    }

                    else -> result.notImplemented()
                }
            }
    }

    private fun startForegroundServiceInternal(url: String?) {
        val intent = Intent(this, GhostChatService::class.java).apply {
            action = GhostChatService.ACTION_START
            putExtra(GhostChatService.EXTRA_URL, url)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    private fun stopForegroundService() {
        try {
            stopService(Intent(this, GhostChatService::class.java))
        } catch (_: Throwable) {}
    }

    override fun onDestroy() {
        super.onDestroy()
    }
}
