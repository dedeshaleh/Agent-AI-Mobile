package id.agenthq.agent_hq

import android.content.Context
import android.os.Build
import android.os.PowerManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Status termal untuk overlay performa (PowerManager.THERMAL_STATUS_*, API 29+).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "agenthq/thermal").setMethodCallHandler { call, result ->
            if (call.method != "status") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                result.success(-1)
                return@setMethodCallHandler
            }
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            result.success(pm.currentThermalStatus)
        }
    }
}
