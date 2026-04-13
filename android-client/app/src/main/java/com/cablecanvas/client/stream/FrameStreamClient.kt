package com.cablecanvas.client.stream

import com.cablecanvas.client.protocol.FrameProtocol
import com.cablecanvas.client.transport.Transport
import com.cablecanvas.client.transport.TransportConnection
import java.io.Closeable

class FrameStreamClient(
    transport: Transport,
) : Closeable {
    private val connection: TransportConnection = transport.connect()

    fun readFrames(onFrame: (ByteArray) -> Unit) {
        while (true) {
            val frame = FrameProtocol.readFrame(connection.input)
            onFrame(frame)
        }
    }

    override fun close() {
        connection.close()
    }
}

