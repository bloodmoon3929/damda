package kr.bloodmoon.notes

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.FlutterActivityLaunchConfigs.BackgroundMode
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Small "save to 미정리" window, opened by the share sheet (a link from
 * another app) or the home-screen memo widget. It runs its own Dart entry
 * point (quickMemoMain) over a transparent window, so the full app does not
 * have to start.
 */
class QuickMemoActivity : FlutterActivity() {
    override fun getDartEntrypointFunctionName(): String = "quickMemoMain"

    override fun getBackgroundMode(): BackgroundMode = BackgroundMode.transparent

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "sharedText" -> result.success(shared(intent))
                    "close" -> {
                        result.success(null)
                        finish()
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /** Text and title handed over by the share sheet, if any. */
    private fun shared(intent: Intent?): Map<String, String>? {
        if (intent?.action != Intent.ACTION_SEND) return null
        val text = intent.getStringExtra(Intent.EXTRA_TEXT) ?: return null
        val subject = intent.getStringExtra(Intent.EXTRA_SUBJECT) ?: ""
        return mapOf("text" to text, "subject" to subject)
    }

    companion object {
        const val CHANNEL = "kr.bloodmoon.notes/quick"
    }
}
