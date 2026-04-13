package com.cablecanvas.client.transport

import java.net.InetSocketAddress
import java.net.Socket

class AdbTcpTransport(
    private val host: String = "127.0.0.1",
    private val port: Int = 27183,
    private val connectTimeoutMs: Int = 5000,
) : Transport {
    override fun connect(): TransportConnection {
        val socket = Socket()
        socket.tcpNoDelay = true
        socket.connect(InetSocketAddress(host, port), connectTimeoutMs)
        return SocketTransportConnection(socket)
    }
}

private class SocketTransportConnection(
    private val socket: Socket,
) : TransportConnection {
    override val input = socket.getInputStream()
    override val output = socket.getOutputStream()

    override fun close() {
        socket.close()
    }
}

