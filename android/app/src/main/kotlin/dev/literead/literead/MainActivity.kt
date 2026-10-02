package dev.literead.literead

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    companion object {
        /// 首次启动存储权限请求码
        private const val REQ_STORAGE = 1001
    }

    /// 应用内更新：接收 Dart 侧下载好的 APK 路径，唤起系统安装器。
    /// 缺少「安装未知应用」权限时返回 NO_INSTALL_PERMISSION，由 Dart 侧引导授权。
    private fun installApk(path: String) {
        if (!packageManager.canRequestPackageInstalls()) {
            throw SecurityException("NO_INSTALL_PERMISSION")
        }
        val file = File(path)
        val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
    }

    /// 跳转系统「安装未知应用」授权页
    private fun openInstallPermissionSettings() {
        val intent = Intent(
            Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
            Uri.parse("package:$packageName"),
        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivity(intent)
    }

    /// 首次启动请求本地存储权限（读取图片/插图等场景）
    private fun requestStoragePermission() {
        val perms = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            arrayOf(Manifest.permission.READ_MEDIA_IMAGES)
        } else {
            arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)
        }
        val need = perms.filter {
            ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
        }
        if (need.isNotEmpty()) {
            ActivityCompat.requestPermissions(this, need.toTypedArray(), REQ_STORAGE)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "literead/updater")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "installApk" -> {
                        try {
                            val path = call.argument<String>("path")
                                ?: throw IllegalArgumentException("path is required")
                            installApk(path)
                            result.success(true)
                        } catch (e: SecurityException) {
                            result.error("NO_INSTALL_PERMISSION", e.message, null)
                        } catch (e: Exception) {
                            result.error("INSTALL_ERROR", e.message, null)
                        }
                    }
                    "openInstallPermissionSettings" -> {
                        try {
                            openInstallPermissionSettings()
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("OPEN_SETTINGS_ERROR", e.message, null)
                        }
                    }
                    "requestStoragePermission" -> {
                        try {
                            requestStoragePermission()
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("STORAGE_ERROR", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
