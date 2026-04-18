package com.cablecanvas.client

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.SurfaceTexture
import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.Surface
import android.view.TextureView
import android.view.WindowManager
import androidx.activity.compose.setContent
import androidx.appcompat.app.AppCompatActivity
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
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
    private var surfaceReady = false

    private var decoder: MediaCodec? = null

    // Compose State
    private var videoStarted by mutableStateOf(false)
    private var statusMessage by mutableStateOf("Connecting...")

    private var mediaSurface: Surface? = null
    private var decoderWidth = 0
    private var decoderHeight = 0
    private var csdSps: ByteArray? = null
    private var csdPps: ByteArray? = null
    private var receiverThread: Thread? = null
    private var frameCounter = 0L

    private val exitReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == "com.cablecanvas.client.EXIT") {
                finishAndRemoveTask()
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        
        ContextCompat.registerReceiver(
            this,
            exitReceiver,
            IntentFilter("com.cablecanvas.client.EXIT"),
            ContextCompat.RECEIVER_EXPORTED
        )

        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        WindowCompat.setDecorFitsSystemWindows(window, false)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            window.addFlags(WindowManager.LayoutParams.FLAG_BLUR_BEHIND)
            window.attributes.blurBehindRadius = 64
            window.attributes = window.attributes
        }

        enterImmersiveMode()

        setContent {
            Box(modifier = Modifier.fillMaxSize()) {
                val videoAlpha by animateFloatAsState(
                    targetValue = if (videoStarted) 1f else 0f,
                    animationSpec = tween(durationMillis = 800),
                    label = "Video Alpha"
                )
                val overlayAlpha by animateFloatAsState(
                    targetValue = if (videoStarted) 0f else 1f,
                    animationSpec = tween(durationMillis = 800),
                    label = "Overlay Alpha"
                )

                AndroidView(
                    factory = { context ->
                        TextureView(context).apply {
                            isOpaque = false
                            surfaceTextureListener = this@MainActivity
                        }
                    },
                    modifier = Modifier
                        .fillMaxSize()
                        .alpha(videoAlpha)
                )

                if (overlayAlpha > 0f) {
                    Box(modifier = Modifier.fillMaxSize().alpha(overlayAlpha)) {
                        ConnectingScreen()
                    }
                }
            }
        }
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
        unregisterReceiver(exitReceiver)
        stopReceiverLoop()
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
        stopReceiverLoop()
        releaseDecoder()
        mediaSurface?.release()
        mediaSurface = null
        return true
    }

    override fun onSurfaceTextureUpdated(surface: SurfaceTexture) = Unit

    // ── Connecting overlay helpers ─────────────────────────────────────────────

    private fun showConnectingOverlay(status: String) {
        runOnUiThread {
            statusMessage = status
            videoStarted = false
        }
    }

    private fun hideConnectingOverlay() {
        if (videoStarted) return
        runOnUiThread {
            videoStarted = true
        }
    }

    // ── Receiver loop ─────────────────────────────────────────────────────────

    private fun stopReceiverLoop() {
        receiverThread?.interrupt()
        receiverThread = null
    }

    private fun startReceiverLoopIfNeeded() {
        if (receiverThread != null || !surfaceReady) return
        Log.i(logTag, "Starting receiver loop")
        receiverThread = Thread {
            while (!Thread.currentThread().isInterrupted) {
                showConnectingOverlay("Connecting...")
                try {
                    FrameStreamClient(AdbTcpTransport()).use { client ->
                        Log.i(logTag, "Transport connected")
                        showConnectingOverlay("Connected")
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
                    showConnectingOverlay("Disconnected")
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