package com.cablecanvas.client.protocol

import java.io.DataInputStream
import java.io.EOFException
import java.io.InputStream

object FrameProtocol {
    enum class Codec(val id: Int) {
        JPEG(1),
        H264(2),
    }

    data class Frame(
        val codec: Codec,
        val flags: Int,
        val width: Int,
        val height: Int,
        val payload: ByteArray,
    )

    private const val MAGIC = "CCF2"
    private const val MAX_FRAME_BYTES = 25 * 1024 * 1024

    fun readFrame(input: InputStream): Frame {
        val dataInput = DataInputStream(input)
        val magicBytes = ByteArray(4)
        dataInput.readFully(magicBytes)
        val actualMagic = String(magicBytes, Charsets.US_ASCII)
        if (actualMagic != MAGIC) {
            throw EOFException("Invalid frame magic: $actualMagic")
        }
        val codecRaw = dataInput.readUnsignedByte()
        val codec = Codec.entries.firstOrNull { it.id == codecRaw }
            ?: throw EOFException("Unknown codec id: $codecRaw")
        val flags = dataInput.readUnsignedByte()
        dataInput.readUnsignedShort() // reserved
        val width = dataInput.readInt()
        val height = dataInput.readInt()
        val length = dataInput.readInt()
        require(length in 1..MAX_FRAME_BYTES) { "Invalid frame length: $length" }
        val frame = ByteArray(length)
        dataInput.readFully(frame)
        return Frame(
            codec = codec,
            flags = flags,
            width = width,
            height = height,
            payload = frame,
        )
    }
}
