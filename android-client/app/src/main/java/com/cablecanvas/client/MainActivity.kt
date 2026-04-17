package com.cablecanvas.client

import android.graphics.SurfaceTexture
import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.Surface
import android.view.TextureView
import android.view.View
import android.view.WindowManager
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.compose.ui.platform.ComposeView
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import com.cablecanvas.client.protocol.FrameProtocol
import com.cablecanvas.client.stream.FrameStreamClient
import com.cablecanvas.client.transport.AdbTcpTransport
import com.cablecanvas.client.ui.ConnectingScreen
import java.nio.ByteBuffer

class MainActivity : AppCompatActivity(), TextureView.SurfaceTextureListener {
    private val logTag = "CableCanvas"

    @Volatile
    private var running = true

    @Volatile
    private var surfaceReady = false

    private var decoder: MediaCodec? = null
    private lateinit var textureView: TextureView
    private lateinit var statusView: TextView
    private lateinit var connectingComposeView: ComposeView

    private var mediaSurface: Surface? = null // Holds the rendering surface for MediaCodec
    private var decoderWidth = 0
    private var decoderHeight = 0
    private var csdSps: ByteArray? = null
    private var csdPps: ByteArray? = null
    private var receiverThread: Thread? = null
    private var frameCounter = 0L

    /** True after the first decoded frame is rendered – hides the connecting overlay. */
    @Volatile
    private var videoStarted = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        setContentView(R.layout.activity_main)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            window.addFlags(WindowManager.LayoutParams.FLAG_BLUR_BEHIND)
            window.attributes.blurBehindRadius = 64 // Adjust 1-100 for blur intensity
            window.attributes = window.attributes
        }

        textureView = findViewById(R.id.videoSurface)

        // Ensure the TextureView allows the wallpaper to show through initially
        textureView.isOpaque = false
        textureView.alpha = 0f
        textureView.surfaceTextureListener = this

        statusView = findViewById(R.id.statusView)
        connectingComposeView = findViewById(R.id.connectingComposeView)

        // Inject the Compose UI
        connectingComposeView.setContent {
            ConnectingScreen()
        }

        enterImmersiveMode()
    }

    override fun onResume() {
        super.onResume()
        enterImmersiveMode()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) enterImmersiveMode()
    }

    override fun onDestroy() {
        running = false
        receiverThread?.interrupt()
        releaseDecoder()
        mediaSurface?.release()
        Log.i(logTag, "MainActivity destroyed")
        super.onDestroy()
    }

    // ── TextureView.SurfaceTextureListener Callbacks ──────────────────────────

    override fun onSurfaceTextureAvailable(surface: SurfaceTexture, width: Int, height: Int) {
        mediaSurface = Surface(surface)
        surfaceReady = true
        startReceiverLoopIfNeeded()
    }

    override fun onSurfaceTextureSizeChanged(surface: SurfaceTexture, width: Int, height: Int) = Unit

    override fun onSurfaceTextureDestroyed(surface: SurfaceTexture): Boolean {
        surfaceReady = false
        releaseDecoder()
        mediaSurface?.release()
        mediaSurface = null
        return true
    }

    override fun onSurfaceTextureUpdated(surface: SurfaceTexture) = Unit

    // ── Connecting overlay helpers ─────────────────────────────────────────────

    private fun showConnectingOverlay(status: String) {
        runOnUiThread {
            if (connectingComposeView.visibility != View.VISIBLE) {
                connectingComposeView.alpha = 1f // Reset alpha before showing
                connectingComposeView.visibility = View.VISIBLE
            }

            // Fade the frozen video frame out smoothly over 500ms
            if (videoStarted) {
                textureView.animate()
                    .alpha(0f)
                    .setDuration(500)
                    .start()
            }

            videoStarted = false
        }
    }

    private fun hideConnectingOverlay() {
        if (videoStarted) return
        videoStarted = true
        runOnUiThread {
            // 1. Fade IN the live video stream smoothly over 500ms
            textureView.animate()
                .alpha(1f)
                .setDuration(500)
                .start()

            // 2. Fade OUT the spinner and scrim over 500ms
            connectingComposeView.animate()
                .alpha(0f)
                .setDuration(500)
                .withEndAction { connectingComposeView.visibility = View.GONE }
                .start()
        }
    }

    // ── Receiver loop ─────────────────────────────────────────────────────────

    private fun startReceiverLoopIfNeeded() {
        if (receiverThread != null || !surfaceReady) return
        Log.i(logTag, "Starting receiver loop")
        receiverThread = Thread {
            while (running) {
                showConnectingOverlay(getString(R.string.status_connecting))
                try {
                    FrameStreamClient(AdbTcpTransport()).use { client ->
                        Log.i(logTag, "Transport connected")
                        showConnectingOverlay(getString(R.string.status_connected))
                        client.readFrames { frame ->
                            frameCounter += 1
                            if (frameCounter <= 5L || frameCounter % 120L == 0L) {
                                Log.i(
                                    logTag,
                                    "Frame #$frameCounter codec=${frame.codec} flags=${frame.flags} " +
                                        "size=${frame.width}x${frame.height} bytes=${frame.payload.size}"
                                )
                            }
                            if (frame.codec != FrameProtocol.Codec.H264) return@readFrames
                            if (frame.width <= 0 || frame.height <= 0) return@readFrames

                            val nalUnits = parseAvccNalUnits(frame.payload)
                            if (nalUnits.isEmpty()) {
                                if (frameCounter <= 20L) {
                                    Log.w(logTag, "No NAL units in payload (${frame.payload.size} bytes)")
                                }
                                return@readFrames
                            }
                            for (nalu in nalUnits) {
                                if (nalu.isEmpty()) continue
                                when (nalu[0].toInt() and 0x1F) {
                                    7 -> csdSps = nalu
                                    8 -> csdPps = nalu
                                }
                            }

                            ensureDecoder(width = frame.width, height = frame.height)

                            val accessUnit = buildAnnexBAccessUnit(nalUnits)
                            if (accessUnit.isEmpty()) {
                                if (frameCounter <= 20L || frameCounter % 120L == 0L) {
                                    Log.w(logTag, "Access unit empty")
                                }
                                return@readFrames
                            }
                            queueFrame(accessUnit, frame.flags)
                            val rendered = drainDecoder()
                            if (rendered) hideConnectingOverlay()
                        }
                    }
                } catch (e: Exception) {
                    Log.e(logTag, "Receiver loop error", e)
                    releaseDecoder()
                    showConnectingOverlay(getString(R.string.status_disconnected))
                    try {
                        Thread.sleep(1500)
                    } catch (_: InterruptedException) {
                        return@Thread
                    }
                }
            }
        }.also { it.start() }
    }

    // ── Decoder ───────────────────────────────────────────────────────────────

    private fun ensureDecoder(width: Int, height: Int) {
        if (!surfaceReady) return
        if (decoder != null && decoderWidth == width && decoderHeight == height) return

        val sps = csdSps ?: return
        val pps = csdPps ?: return
        releaseDecoder()

        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height)
        format.setByteBuffer("csd-0", ByteBuffer.wrap(sps))
        format.setByteBuffer("csd-1", ByteBuffer.wrap(pps))
        format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, width * height)
        try {
            format.setInteger("low-latency", 1)
            format.setInteger("operating-rate", 120)
            format.setInteger("priority", 0)
        } catch (_: Exception) {}

        val codec = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        codec.configure(format, mediaSurface, null, 0)
        codec.start()
        decoder = codec
        decoderWidth = width
        decoderHeight = height
        Log.i(logTag, "Decoder configured ${width}x${height}")
    }

    private fun queueFrame(frameBytes: ByteArray, frameFlags: Int) {
        val codec = decoder ?: return
        val inputIndex = codec.dequeueInputBuffer(5_000)
        if (inputIndex < 0) {
            if (frameCounter <= 20L || frameCounter % 120L == 0L) {
                Log.w(logTag, "No decoder input buffer available")
            }
            return
        }
        val inputBuffer: ByteBuffer = codec.getInputBuffer(inputIndex) ?: return
        inputBuffer.clear()
        if (frameBytes.size > inputBuffer.capacity()) {
            Log.w(logTag, "Frame larger than decoder input buffer: frame=${frameBytes.size} capacity=${inputBuffer.capacity()}")
            return
        }
        inputBuffer.put(frameBytes)
        val flags = if ((frameFlags and 1) != 0) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0
        codec.queueInputBuffer(inputIndex, 0, frameBytes.size, System.nanoTime() / 1_000, flags)
    }

    private fun drainDecoder(): Boolean {
        val codec = decoder ?: return false
        val bufferInfo = MediaCodec.BufferInfo()
        var lastOutputIndex = -1
        var lastPtsUs = 0L
        var rendered = false
        while (true) {
            val outputIndex = codec.dequeueOutputBuffer(bufferInfo, 0)
            when {
                outputIndex >= 0 -> {
                    if (lastOutputIndex >= 0) codec.releaseOutputBuffer(lastOutputIndex, false)
                    lastOutputIndex = outputIndex
                    lastPtsUs = bufferInfo.presentationTimeUs
                }
                outputIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    Log.i(logTag, "Output format changed: ${codec.outputFormat}")
                }
                else -> {
                    if (lastOutputIndex >= 0) {
                        codec.releaseOutputBuffer(lastOutputIndex, true)
                        rendered = true
                        if (frameCounter <= 5L || frameCounter % 120L == 0L) {
                            Log.i(logTag, "Rendered output buffer, pts=$lastPtsUs")
                        }
                    }
                    return rendered
                }
            }
        }
    }

    private fun releaseDecoder() {
        val codec = decoder ?: return
        try { codec.stop() } catch (_: Exception) {}
        try { codec.release() } catch (_: Exception) {}
        decoder = null
        decoderWidth = 0
        decoderHeight = 0
        Log.i(logTag, "Decoder released")
    }

    // ── NAL helpers ───────────────────────────────────────────────────────────

    private fun parseAvccNalUnits(payload: ByteArray): List<ByteArray> {
        val nalUnits = mutableListOf<ByteArray>()
        var offset = 0
        while (offset + 4 <= payload.size) {
            val naluLength =
                ((payload[offset].toInt() and 0xFF) shl 24) or
                ((payload[offset + 1].toInt() and 0xFF) shl 16) or
                ((payload[offset + 2].toInt() and 0xFF) shl 8) or
                (payload[offset + 3].toInt() and 0xFF)
            offset += 4
            if (naluLength <= 0 || offset + naluLength > payload.size) break
            nalUnits.add(payload.copyOfRange(offset, offset + naluLength))
            offset += naluLength
        }
        return nalUnits
    }

    private fun buildAnnexBAccessUnit(nalUnits: List<ByteArray>): ByteArray {
        val filtered = nalUnits.filter { it.isNotEmpty() }
        if (filtered.isEmpty()) return ByteArray(0)
        var totalSize = 0
        for (nalu in filtered) totalSize += 4 + nalu.size
        val output = ByteArray(totalSize)
        var offset = 0
        for (nalu in filtered) {
            output[offset] = 0; output[offset + 1] = 0; output[offset + 2] = 0; output[offset + 3] = 1
            offset += 4
            System.arraycopy(nalu, 0, output, offset, nalu.size)
            offset += nalu.size
        }
        return output
    }

    // ── Misc ──────────────────────────────────────────────────────────────────

    private fun enterImmersiveMode() {
        val controller = WindowCompat.getInsetsController(window, window.decorView)
        controller.systemBarsBehavior =
            WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        controller.hide(WindowInsetsCompat.Type.systemBars())
    }
}
