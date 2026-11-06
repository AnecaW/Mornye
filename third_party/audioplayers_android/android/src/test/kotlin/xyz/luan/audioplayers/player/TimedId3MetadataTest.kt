package xyz.luan.audioplayers.player

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class TimedId3MetadataTest {
    private fun size(value: Int, syncSafe: Boolean): ByteArray {
        val shift = if (syncSafe) 7 else 8
        val mask = if (syncSafe) 127 else 255
        return ByteArray(4) { index -> ((value shr ((3 - index) * shift)) and mask).toByte() }
    }
    private fun tag(version: Int, vararg fields: Pair<String, String>): ByteArray {
        val frames = fields.flatMap { (key, value) ->
            val text = byteArrayOf(3) + value.toByteArray(Charsets.UTF_8)
            (key.toByteArray(Charsets.US_ASCII) + size(text.size, version == 4) + byteArrayOf(0, 0) + text).toList()
        }.toByteArray()
        return "ID3".toByteArray() + byteArrayOf(version.toByte(), 0, 0) + size(frames.size, true) + frames
    }
    @Test fun `decodes version 3 and 4 titles artists albums and unicode`() {
        for (version in listOf(3, 4)) {
            assertEquals(mapOf("title" to "Jóga", "artist" to "Björk", "album" to "Homogenic"),
                TimedId3Metadata.parse(tag(version, "TIT2" to "Jóga", "TPE1" to "Björk", "TALB" to "Homogenic")))
            assertEquals("x".repeat(200), TimedId3Metadata.parse(tag(version, "TIT2" to "x".repeat(200)))["title"])
        }
    }
    @Test fun `new tag does not retain previous track fields`() {
        TimedId3Metadata.parse(tag(4, "TIT2" to "Old", "TALB" to "Album"))
        assertEquals(mapOf("title" to "New"), TimedId3Metadata.parse(tag(4, "TIT2" to "New")))
        assertEquals(mapOf("title" to ""), TimedId3Metadata.parse(tag(4, "TIT2" to "")))
    }
    @Test fun `malformed truncated oversized and nonmusic metadata stay empty`() {
        assertTrue(TimedId3Metadata.parse(byteArrayOf()).isEmpty())
        assertTrue(TimedId3Metadata.parse(ByteArray(262145)).isEmpty())
        val valid = tag(4, "TIT2" to "Song")
        assertTrue(TimedId3Metadata.parse(valid.copyOf(valid.size - 1)).isEmpty())
        assertTrue(TimedId3Metadata.parse(tag(4, "TXXX" to "Station information")).isEmpty())
        val unsafe = valid.clone().also { it[6] = 0xff.toByte() }
        assertTrue(TimedId3Metadata.parse(unsafe).isEmpty())
    }
}
