package app.anime.anime

import android.view.Surface
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.view.TextureRegistry

/**
 * A narrow emulator compatibility output. A frame is counted only after
 * Flutter's raster thread consumed a SurfaceTexture with a new buffer timestamp.
 * No media URI, codec log text, credentials or pixels cross this channel.
 */
internal class NativeVideoSurfaceChannel(
    messenger: BinaryMessenger,
    private val textures: TextureRegistry,
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "app.anime.anime/native-video-surface")
    private val outputs = mutableMapOf<Int, Output>()

    init { channel.setMethodCallHandler(this) }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val owner = call.argument<Number>("owner")?.toInt()
        if (owner == null) {
            result.error("invalid_surface_owner", null, null)
            return
        }
        when (call.method) {
            "create" -> {
                val serial = call.argument<Number>("open_serial")?.toInt()
                val epoch = call.argument<Number>("epoch")?.toInt()
                val width = call.argument<Number>("width")?.toInt()
                val height = call.argument<Number>("height")?.toInt()
                if (serial == null || epoch == null || width == null || height == null ||
                    !NativeSurfaceDimensions.valid(width, height)
                ) {
                    result.error("invalid_surface_dimensions", null, null)
                    return
                }
                // Caller has detached mpv's vo/wid before replacing this texture.
                outputs.remove(owner)?.close()
                try {
                    val output = Output(serial, epoch, width, height)
                    outputs[owner] = output
                    result.success(mapOf("texture_id" to output.texture.id(), "wid" to output.wid))
                } catch (_: Throwable) {
                    // Explicit fixed failure code; no raw native messages persisted.
                    result.error("surface_create_failed", null, null)
                }
            }
            "resize" -> {
                val output = outputs[owner]
                val serial = call.argument<Number>("open_serial")?.toInt()
                val epoch = call.argument<Number>("epoch")?.toInt()
                val width = call.argument<Number>("width")?.toInt()
                val height = call.argument<Number>("height")?.toInt()
                if (output == null || serial == null || epoch == null ||
                    serial != output.ledger.openSerial || epoch != output.ledger.epoch) {
                    result.error("stale_surface", null, null)
                    return
                }
                if (width == null || height == null || !NativeSurfaceDimensions.valid(width, height)) {
                    result.error("invalid_surface_dimensions", null, null)
                    return
                }
                try {
                    // MediaCodec owns direct-output buffer geometry. Only the
                    // software/GPU fallback asks to resize this queue in place.
                    result.success(output.resize(serial, epoch, width, height,
                        call.argument<Boolean>("resize_buffers") == true))
                } catch (_: Throwable) {
                    result.error("surface_resize_failed", null, null)
                }
            }
            "probe" -> {
                val output = outputs[owner]
                if (output == null ||
                    call.argument<Number>("open_serial")?.toInt() != output.ledger.openSerial ||
                    call.argument<Number>("epoch")?.toInt() != output.ledger.epoch
                ) {
                    result.error("stale_surface", null, null)
                } else {
                    result.success(output.snapshot())
                }
            }
            "dispose" -> {
                outputs.remove(owner)?.close()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private inner class Output(serial: Int, epoch: Int, width: Int, height: Int) {
        val ledger = NativeSurfaceFrameLedger(serial, epoch)
        private val dimensions = NativeSurfaceDimensions(serial, epoch, width, height)
        val texture = textures.createSurfaceTexture()
        private var surface: Surface? = null
        var wid = 0L
            private set
        @Volatile private var closed = false
        @Volatile private var reason = "awaiting_image"

        init {
            try {
                val surfaceTexture = texture.surfaceTexture()
                surfaceTexture.setDefaultBufferSize(width, height)
                // Flutter installs its own onFrameAvailable listener. Do not
                // replace it. This public callback runs on the raster thread
                // after SurfaceTextureWrapper.updateTexImage, not on resize.
                texture.setOnFrameConsumedListener {
                    if (!closed) {
                        try {
                            // A callback may repeat with the old buffer (e.g.
                            // UI redraw). Count only a strictly newer nonzero
                            // producer timestamp from this fresh SurfaceTexture.
                            val size = dimensions.current
                            if (ledger.consumed(surfaceTexture.timestamp, size.width, size.height)) {
                                reason = "texture_frame_consumed"
                            }
                        } catch (_: Throwable) {
                            reason = "texture_consume_failed"
                        }
                    }
                }
                surface = Surface(surfaceTexture)
                wid = SurfaceReferences.create(surface!!)
                check(wid != 0L)
            } catch (failure: Throwable) {
                close()
                throw failure
            }
        }

        fun snapshot(): Map<String, Any> = ledger.snapshot(reason)

        fun resize(serial: Int, epoch: Int, width: Int, height: Int, resizeBuffers: Boolean): Boolean {
            if (closed || !dimensions.belongsTo(serial, epoch) ||
                !NativeSurfaceDimensions.valid(width, height)) return false
            if (resizeBuffers) texture.surfaceTexture().setDefaultBufferSize(width, height)
            // Publish the pair atomically to the raster callback, never mixed
            // old/new width and height. Metadata itself does not create a frame.
            return dimensions.resize(serial, epoch, width, height)
        }

        fun close() {
            if (closed) return
            closed = true
            dimensions.close()
            ledger.close()
            texture.setOnFrameConsumedListener(null)
            // Dart has already detached vid/vo/wid. SurfaceTextureWrapper owns
            // updateTexImage/release synchronization and its BufferQueue.
            if (wid != 0L) {
                SurfaceReferences.delete(wid)
                wid = 0L
            }
            surface?.release()
            surface = null
            texture.release()
        }
    }

    fun close() {
        channel.setMethodCallHandler(null)
        outputs.values.forEach { it.close() }
        outputs.clear()
    }

    private object SurfaceReferences {
        private val helper by lazy {
            Class.forName("com.alexmercerind.mediakitandroidhelper.MediaKitAndroidHelper")
        }
        fun create(surface: Surface): Long =
            helper.getDeclaredMethod("newGlobalObjectRef", Any::class.java)
                .invoke(null, surface) as Long
        fun delete(reference: Long) {
            helper.getDeclaredMethod("deleteGlobalObjectRef", Long::class.javaPrimitiveType)
                .invoke(null, reference)
        }
    }
}

/** Metadata snapshot shared by platform-thread resize and raster consumption. */
internal data class NativeSurfaceSize(val width: Int, val height: Int)

internal class NativeSurfaceDimensions(
    private val openSerial: Int,
    private val epoch: Int,
    width: Int,
    height: Int,
) {
    @Volatile var current = NativeSurfaceSize(width, height)
        private set
    @Volatile private var closed = false

    fun belongsTo(serial: Int, surfaceEpoch: Int): Boolean =
        !closed && serial == openSerial && surfaceEpoch == epoch

    @Synchronized fun resize(serial: Int, surfaceEpoch: Int, width: Int, height: Int): Boolean {
        if (!belongsTo(serial, surfaceEpoch) || !valid(width, height)) return false
        current = NativeSurfaceSize(width, height)
        return true
    }

    @Synchronized fun close() { closed = true }

    companion object {
        fun valid(width: Int, height: Int): Boolean =
            width in 1..8192 && height in 1..8192 && width.toLong() * height <= 33554432L
    }
}

/** Actual raster-consumption accounting, independent of UI/decoder clocks. */
internal class NativeSurfaceFrameLedger(val openSerial: Int, val epoch: Int) {
    var frames = 0L
        private set
    var width = 0
        private set
    var height = 0
        private set
    private var lastTimestamp = 0L
    private var closed = false

    @Synchronized fun consumed(timestamp: Long, imageWidth: Int, imageHeight: Int): Boolean {
        if (closed || timestamp <= lastTimestamp || imageWidth <= 1 || imageHeight <= 1) return false
        lastTimestamp = timestamp
        frames++
        width = imageWidth
        height = imageHeight
        return true
    }

    @Synchronized fun snapshot(reason: String): Map<String, Any> = mapOf(
        "open_serial" to openSerial,
        "epoch" to epoch,
        "frame_count" to frames,
        "width" to width,
        "height" to height,
        "reason" to reason,
    )

    @Synchronized fun close() { closed = true }
}
