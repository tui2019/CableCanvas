package com.cablecanvas.client

import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Bundle
import android.util.Log
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import com.cablecanvas.client.protocol.FrameProtocol
import com.cablecanvas.client.stream.FrameStreamClient
import com.cablecanvas.client.transport.AdbTcpTransport
import java.nio.ByteBuffer

class MainActivity : AppCompatActivity(), SurfaceHolder.Callback {
    private val logTag = "CableCanvas"

    @Volatile
    private var running = true

    @Volatile
    private var surfaceReady = false

    private var decoder: MediaCodec? = null
    private lateinit var surfaceView: SurfaceView
    private lateinit var statusView: TextView
    private var decoderWidth = 0
    private var decoderHeight = 0
    private var csdSps: ByteArray? = null
    private var csdPps: ByteArray? = null
    private var receiverThread: Thread? = null
    private var frameCounter = 0L

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        surfaceView = findViewById(R.id.videoSurface)
        statusView = findViewById(R.id.statusView)
        surfaceView.holder.addCallback(this)
    }

    override fun onDestroy() {
        running = false
        receiverThread?.interrupt()
        releaseDecoder()
        Log.i(logTag, "MainActivity destroyed")
        super.onDestroy()
    }

    override fun surfaceCreated(holder: SurfaceHolder) {
        surfaceReady = true
        startReceiverLoopIfNeeded()
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) = Unit

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        surfaceReady = false
        releaseDecoder()
    }

    private fun startReceiverLoopIfNeeded() {
        if (receiverThread != null || !surfaceReady) {
            return
        }
        Log.i(logTag, "Starting receiver loop")
        receiverThread = Thread {
            while (running) {
                updateStatus(getString(R.string.status_connecting))
                try {
                    FrameStreamClient(AdbTcpTransport()).use { client ->
                        Log.i(logTag, "Transport connected")
                        updateStatus(getString(R.string.status_connected))
                        client.readFrames { frame ->
                            frameCounter += 1
                            if (frameCounter <= 5L || frameCounter % 120L == 0L) {
                                Log.i(
                                    logTag,
                                    "Frame #$frameCounter codec=${frame.codec} flags=${frame.flags} size=${frame.width}x${frame.height} bytes=${frame.payload.size}"
                                )
                            }
                            if (frame.codec != FrameProtocol.Codec.H264) {
                                return@readFrames
                            }
                            if (frame.width <= 0 || frame.height <= 0) {
                                return@readFrames
                            }

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
                            drainDecoder()
                        }
                    }
                } catch (e: Exception) {
                    Log.e(logTag, "Receiver loop error", e)
                    releaseDecoder()
                    updateStatus(getString(R.string.status_disconnected))
                    try {
                        Thread.sleep(1500)
                    } catch (_: InterruptedException) {
                        return@Thread
                    }
                }
            }
        }.also { it.start() }
    }

    private fun ensureDecoder(width: Int, height: Int) {
        if (!surfaceReady) {
            return
        }
        if (decoder != null && decoderWidth == width && decoderHeight == height) {
            return
        }

        val sps = csdSps ?: return
        val pps = csdPps ?: return
        releaseDecoder()

        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height)
        format.setByteBuffer("csd-0", ByteBuffer.wrap(sps))
        format.setByteBuffer("csd-1", ByteBuffer.wrap(pps))
        format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, width * height)
        val codec = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        codec.configure(format, surfaceView.holder.surface, null, 0)
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

    private fun drainDecoder() {
        val codec = decoder ?: return
        val bufferInfo = MediaCodec.BufferInfo()
        while (true) {
            val outputIndex = codec.dequeueOutputBuffer(bufferInfo, 0)
            when {
                outputIndex >= 0 -> {
                    codec.releaseOutputBuffer(outputIndex, true)
                    if (frameCounter <= 5L || frameCounter % 120L == 0L) {
                        Log.i(logTag, "Rendered output buffer, pts=${bufferInfo.presentationTimeUs}")
                    }
                }
                outputIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    Log.i(logTag, "Output format changed: ${codec.outputFormat}")
                }
                outputIndex == MediaCodec.INFO_TRY_AGAIN_LATER -> return
                else -> return
            }
        }
    }

    private fun releaseDecoder() {
        val codec = decoder ?: return
        try {
            codec.stop()
        } catch (_: Exception) {
        }
        try {
            codec.release()
        } catch (_: Exception) {
        }
        decoder = null
        decoderWidth = 0
        decoderHeight = 0
        Log.i(logTag, "Decoder released")
    }

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
            if (naluLength <= 0 || offset + naluLength > payload.size) {
                break
            }
            nalUnits.add(payload.copyOfRange(offset, offset + naluLength))
            offset += naluLength
        }
        return nalUnits
    }

    private fun buildAnnexBAccessUnit(nalUnits: List<ByteArray>): ByteArray {
        val filtered = nalUnits.filter { it.isNotEmpty() }
        if (filtered.isEmpty()) {
            return ByteArray(0)
        }
        var totalSize = 0
        for (nalu in filtered) {
            totalSize += 4 + nalu.size
        }
        val output = ByteArray(totalSize)
        var offset = 0
        for (nalu in filtered) {
            output[offset] = 0
            output[offset + 1] = 0
            output[offset + 2] = 0
            output[offset + 3] = 1
            offset += 4
            val size = nalu.size
            System.arraycopy(nalu, 0, output, offset, size)
            offset += size
        }
        return output
    }

    private fun updateStatus(text: String) {
        runOnUiThread {
            statusView.text = text
        }
    }
}
