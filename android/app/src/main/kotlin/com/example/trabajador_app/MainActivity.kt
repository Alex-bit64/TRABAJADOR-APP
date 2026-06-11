package com.example.trabajador_app

import android.content.Intent
import android.net.Uri
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private val channelName = "trabajador_app/platform"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "openWhatsApp" -> {
                    val phone = call.argument<String>("phone").orEmpty()
                    val message = call.argument<String>("message").orEmpty()
                    result.success(openWhatsApp(phone, message))
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun openWhatsApp(phone: String, message: String): Boolean {
        return try {
            val uri = Uri.Builder()
                .scheme("https")
                .authority("wa.me")
                .appendPath(phone)
                .appendQueryParameter("text", message)
                .build()
            val intent = Intent(Intent.ACTION_VIEW, uri)
            startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }
}
