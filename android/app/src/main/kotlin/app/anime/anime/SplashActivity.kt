package app.anime.anime

import android.app.Activity
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.ViewTreeObserver
import android.widget.ImageView
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor

class SplashActivity : Activity() {
    private var flutterEngine: FlutterEngine? = null
    private var handedOff = false
    private var handOffRunnable: Runnable? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        if (
            !isTaskRoot &&
            intent?.action == Intent.ACTION_MAIN &&
            intent?.hasCategory(Intent.CATEGORY_LAUNCHER) == true
        ) {
            finish()
            return
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            splashScreen.setOnExitAnimationListener { provider ->
                provider.remove()
            }
        }

        val splashView = ImageView(this).apply {
            setBackgroundColor(getColor(R.color.zeluna_splash_background))
            setImageResource(R.drawable.zeluna_launch_background)
            scaleType = ImageView.ScaleType.CENTER_CROP
            contentDescription = getString(R.string.zeluna_startup_description)
        }
        setContentView(splashView)

        splashView.viewTreeObserver.addOnPreDrawListener(
            object : ViewTreeObserver.OnPreDrawListener {
                override fun onPreDraw(): Boolean {
                    splashView.viewTreeObserver.removeOnPreDrawListener(this)
                    splashView.post { startFlutterEngine() }
                    return true
                }
            },
        )
    }

    private fun startFlutterEngine() {
        if (isFinishing || flutterEngine != null) return

        val engine = FlutterEngine(this)
        flutterEngine = engine
        engine.navigationChannel.setInitialRoute("/")
        engine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint.createDefault(),
        )
        val runnable = Runnable { handOffToFlutter(engine) }
        handOffRunnable = runnable
        window.decorView.postDelayed(runnable, nativeSplashDurationMillis)
    }

    private fun handOffToFlutter(engine: FlutterEngine) {
        if (handedOff || isFinishing) return
        handedOff = true
        handOffRunnable?.let(window.decorView::removeCallbacks)
        handOffRunnable = null
        FlutterEngineCache.getInstance().put(engineId, engine)

        val flutterIntent = FlutterActivity.CachedEngineIntentBuilder(
            MainActivity::class.java,
            engineId,
        ).destroyEngineWithActivity(true).build(this)
        startActivity(flutterIntent)
        disableActivityTransition()
        finish()
    }

    @Suppress("DEPRECATION")
    private fun disableActivityTransition() {
        overridePendingTransition(0, 0)
    }

    override fun onDestroy() {
        handOffRunnable?.let(window.decorView::removeCallbacks)
        handOffRunnable = null
        if (!handedOff) {
            flutterEngine?.destroy()
        }
        flutterEngine = null
        super.onDestroy()
    }

    private companion object {
        const val engineId = "zeluna_startup_engine"
        const val nativeSplashDurationMillis = 700L
    }
}
