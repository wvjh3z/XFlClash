package com.follow.clash.plugins

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * APK 安装器插件（self-update tier-2）。
 *
 * Flutter 侧通过 MethodChannel 'com.follow.clash/apk_installer' 调用：
 * - installApk(path: String): 用 FileProvider + ACTION_VIEW 触发系统安装器
 */
class ApkInstallerPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private var channel: MethodChannel? = null
    private var context: Context? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "com.follow.clash/apk_installer")
        channel?.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        context = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "installApk" -> {
                val path = call.argument<String>("path")
                if (path == null) {
                    result.error("INVALID_PATH", "APK path is null", null)
                    return
                }
                try {
                    installApk(path)
                    result.success(true)
                } catch (e: Exception) {
                    result.error("INSTALL_FAILED", e.message, e.stackTraceToString())
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun installApk(path: String) {
        val ctx = context ?: throw IllegalStateException("Context is null")
        val file = File(path)
        if (!file.exists()) throw IllegalStateException("APK file not found: $path")

        val uri: Uri = FileProvider.getUriForFile(
            ctx,
            "${ctx.packageName}.update_provider",
            file
        )

        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        ctx.startActivity(intent)
    }
}
