package com.cablecanvas.client.transport

import java.io.Closeable
import java.io.InputStream
import java.io.OutputStream

interface Transport {
    fun connect(): TransportConnection
}

interface TransportConnection : Closeable {
    val input: InputStream
    val output: OutputStream
}

