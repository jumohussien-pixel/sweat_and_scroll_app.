package com.example.sweat_and_scroll_app

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import android.app.AppOpsManager
import android.os.Build
import android.os.Process
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.example.sweat_and_scroll_app/overlay"

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "requestPermissions" -> {
                    requestPermissions()
                    result.success(true)
                }
                "blockScreen" -> {
                    blockScreen()
                    result.success(true)
                }
                "unblockScreen" -> {
                    // إذا أردت إضافة أي أمر عند إلغاء الحظر برمجياً
                    result.success(true)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    // 1. طلب الصلاحيات من المستخدم وعرض شاشات الإعدادات تلقائياً
    private fun requestPermissions() {
        // صلاحية الظهور فوق التطبيقات الأخرى (System Alert Window)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            if (!Settings.canDrawOverlays(this)) {
                val intent = Intent(
                    Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                    Uri.parse("package:$packageName")
                )
                startActivity(intent)
            }
        }

        // صلاحية الوصول لبيانات الاستخدام (Usage Stats)
        if (!isUsageStatsPermissionGranted()) {
            val intent = Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS)
            startActivity(intent)
        }
    }

    // فحص هل الصلاحية مفعلة أم لا
    private fun isUsageStatsPermissionGranted(): Boolean {
        val appOps = getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
        val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            appOps.unsafeCheckOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS,
                Process.myUid(),
                packageName
            )
        } else {
            appOps.checkOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS,
                Process.myUid(),
                packageName
            )
        }
        return mode == AppOpsManager.MODE_ALLOWED
    }

    // 2. إجبار الموبايل على الخروج من أي تطبيق والرجوع للـ Home Screen فوراً
    private fun blockScreen() {
        val startMain = Intent(Intent.ACTION_MAIN)
        startMain.addCategory(Intent.CATEGORY_HOME)
        startMain.flags = Intent.FLAG_ACTIVITY_NEW_TASK
        startActivity(startMain)
    }
}