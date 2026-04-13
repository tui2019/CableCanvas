package com.cablecanvas.client

import android.graphics.BitmapFactory
import android.os.Bundle
import android.widget.ImageView
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import com.cablecanvas.client.stream.FrameStreamClient
import com.cablecanvas.client.transport.AdbTcpTransport

class MainActivity : AppCompatActivity() {
    @Volatile
    private var running = true

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        startReceiverLoop()
    }

    override fun onDestroy() {
        running = false
        super.onDestroy()
    }

    private fun startReceiverLoop() {
        val frameView = findViewById<ImageView>(R.id.frameView)
        val statusView = findViewById<TextView>(R.id.statusView)

        Thread {
            while (running) {
                updateStatus(statusView, getString(R.string.status_connecting))
                try {
                    FrameStreamClient(AdbTcpTransport()).use { client ->
                        updateStatus(statusView, getString(R.string.status_connected))
                        client.readFrames { bytes ->
                            val bmp = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: return@readFrames
                            runOnUiThread { frameView.setImageBitmap(bmp) }
                        }
                    }
                } catch (_: Exception) {
                    updateStatus(statusView, getString(R.string.status_disconnected))
                    Thread.sleep(1500)
                }
            }
        }.start()
    }

    private fun updateStatus(statusView: TextView, text: String) {
        runOnUiThread {
            statusView.text = text
        }
    }
}

