package com.cablecanvas.client.protocol

import java.io.DataInputStream
import java.io.EOFException
import java.io.InputStream

object FrameProtocol {
    private const val MAGIC = "CCF1"
    private const val MAX_FRAME_BYTES = 25 * 1024 * 1024

    fun readFrame(input: InputStream): ByteArray {
        val dataInput = DataInputStream(input)
        val magicBytes = ByteArray(4)
        dataInput.readFully(magicBytes)
        val actualMagic = String(magicBytes, Charsets.US_ASCII)
        if (actualMagic != MAGIC) {
            throw EOFException("Invalid frame magic: $actualMagic")
        }
        val length = dataInput.readInt()
        require(length in 1..MAX_FRAME_BYTES) { "Invalid frame length: $length" }
        val frame = ByteArray(length)
        dataInput.readFully(frame)
        return frame
    }
}

