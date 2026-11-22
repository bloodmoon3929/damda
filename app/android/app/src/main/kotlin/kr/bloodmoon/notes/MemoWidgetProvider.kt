package kr.bloodmoon.notes

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.util.SizeF
import android.widget.RemoteViews

/**
 * Home-screen widget: a one-line memo box, 1x1 up to 1x5. Widgets can't
 * hold a text field, so tapping it opens the quick memo window. One cell
 * wide it is just the app icon (tap = memo); wider, the icon opens the app
 * and the box beside it takes the memo.
 */
class MemoWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        for (id in ids) update(context, manager, id)
    }

    override fun onAppWidgetOptionsChanged(
        context: Context,
        manager: AppWidgetManager,
        id: Int,
        options: Bundle,
    ) {
        update(context, manager, id)
    }

    private fun update(context: Context, manager: AppWidgetManager, id: Int) {
        val views = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            // Android 12+: the launcher picks the layout for the size.
            RemoteViews(
                mapOf(
                    SizeF(40f, 40f) to small(context),
                    SizeF(110f, 40f) to wide(context),
                ),
            )
        } else {
            val width = manager.getAppWidgetOptions(id)
                .getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 250)
            if (width < 110) small(context) else wide(context)
        }
        manager.updateAppWidget(id, views)
    }

    private fun small(context: Context) =
        RemoteViews(context.packageName, R.layout.memo_widget_small).apply {
            setOnClickPendingIntent(R.id.memo_box, memo(context))
        }

    private fun wide(context: Context) =
        RemoteViews(context.packageName, R.layout.memo_widget).apply {
            setOnClickPendingIntent(R.id.memo_box, memo(context))
            setOnClickPendingIntent(R.id.memo_app, app(context))
        }

    private fun memo(context: Context) = PendingIntent.getActivity(
        context,
        0,
        Intent(context, QuickMemoActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    private fun app(context: Context) = PendingIntent.getActivity(
        context,
        1,
        Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )
}
