package com.example.trabajador_app

import android.content.Intent
import android.content.ClipData
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import java.io.File
import java.util.concurrent.Executors
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private val channelName = "trabajador_app/platform"
    private val updateExecutor = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "openWhatsApp" -> {
                    val phone = call.argument<String>("phone").orEmpty()
                    val message = call.argument<String>("message").orEmpty()
                    result.success(openWhatsApp(phone, message))
                }
                "prepareUpdateDirectory" -> {
                    val directory = File(cacheDir, "updates")
                    if (directory.isDirectory || directory.mkdirs()) {
                        result.success(directory.absolutePath)
                    } else {
                        result.error("UPDATE_STORAGE", "No se pudo preparar el almacenamiento de la actualización.", null)
                    }
                }
                "installUpdate" -> {
                    val path = call.argument<String>("path").orEmpty()
                    val expectedBuild = call.argument<Int>("expectedBuild") ?: 0
                    updateExecutor.execute {
                        try {
                            val apk = validateUpdate(path, expectedBuild)
                            runOnUiThread {
                                try {
                                    result.success(if (apk == null) "already_updated" else openInstaller(apk))
                                } catch (e: Exception) {
                                    result.error("UPDATE_INSTALL", "No se pudo abrir el instalador: ${e.message}", null)
                                }
                            }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("UPDATE_APK", e.message, null) }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        updateExecutor.shutdown()
        super.onDestroy()
    }

    @Suppress("DEPRECATION")
    private fun validateUpdate(path: String, expectedBuild: Int): File? {
        require(expectedBuild > 0) { "La versión solicitada no es válida." }
        val apk = File(path).canonicalFile
        val directory = File(cacheDir, "updates").canonicalFile
        require(apk.parentFile == directory && apk.isFile && apk.extension == "apk") {
            "No se encontró el APK descargado. Descárgalo nuevamente."
        }
        val flags = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
        val installed = packageManager.getPackageInfo(packageName, flags)
        if (versionCode(installed) >= expectedBuild) return null
        val archive = packageManager.getPackageArchiveInfo(apk.absolutePath, flags)
            ?: throw IllegalArgumentException("El APK no es válido. Descárgalo nuevamente.")
        require(archive.packageName == packageName && versionCode(archive) == expectedBuild.toLong()) {
            "El APK no corresponde a esta aplicación o versión."
        }
        val currentSigners = signers(installed)
        require(currentSigners.isNotEmpty() && currentSigners == signers(archive)) {
            "La firma del APK es diferente. No desinstales la app; solicita el APK compatible."
        }
        return apk
    }

    @Suppress("DEPRECATION")
    private fun versionCode(info: PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()

    @Suppress("DEPRECATION")
    private fun signers(info: PackageInfo): Set<String> =
        (if (Build.VERSION.SDK_INT >= 28) info.signingInfo?.apkContentsSigners else info.signatures)
            ?.map { it.toCharsString() }?.toSet() ?: emptySet()

    private fun openInstaller(apk: File): String {
        if (Build.VERSION.SDK_INT >= 26 && !packageManager.canRequestPackageInstalls()) {
            startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")))
            return "permission_required"
        }
        val uri = FileProvider.getUriForFile(this, "$packageName.updates", apk)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            clipData = ClipData.newRawUri("Actualización del Marcador", uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startActivity(intent)
        return "installer_opened"
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
