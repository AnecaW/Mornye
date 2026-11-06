package xyz.luan.audioplayers.player

/** Bounded ID3v2.3/2.4 text frames from MediaPlayer's HLS timed metadata. */
internal object TimedId3Metadata {
    fun parse(bytes: ByteArray): Map<String, String> {
        if (bytes.size !in 10..262144 || String(bytes, 0, 3, Charsets.US_ASCII) != "ID3") return emptyMap()
        val version = bytes[3].toInt() and 255
        if (version !in 3..4 || bytes[5].toInt() and 0x80 != 0) return emptyMap()
        fun size(at: Int, syncSafe: Boolean): Int {
            var result = 0
            for (i in 0..3) {
                val value = bytes[at + i].toInt() and 255
                if (syncSafe && value > 127) return -1
                result = (result shl (if (syncSafe) 7 else 8)) or value
            }
            return result
        }
        val length = size(6, true)
        if (length < 0 || length > bytes.size - 10) return emptyMap()
        val end = length + 10
        var offset = 10
        if (bytes[5].toInt() and 0x40 != 0) {
            if (offset + 4 > end) return emptyMap()
            val extended = size(offset, version == 4)
            if (extended < 0 || extended > end - offset) return emptyMap()
            offset += extended + if (version == 3) 4 else 0
        }
        val result = mutableMapOf<String, String>()
        while (offset + 10 <= end) {
            val id = String(bytes, offset, 4, Charsets.US_ASCII)
            val frameSize = size(offset + 4, version == 4)
            val flags = bytes[offset + 9].toInt() and 255
            if (frameSize <= 0 || frameSize > end - offset - 10) break
            offset += 10
            val key = when (id) { "TIT2" -> "title"; "TPE1" -> "artist"; "TALB" -> "album"; else -> null }
            val unsupported = if (version == 4) flags and 0x4f != 0 else flags and 0xe0 != 0
            if (key != null && !unsupported && frameSize in 1..4096) {
                val charset = when (bytes[offset].toInt()) {
                    0 -> Charsets.ISO_8859_1; 1 -> Charsets.UTF_16; 2 -> Charsets.UTF_16BE; 3 -> Charsets.UTF_8; else -> null
                }
                if (charset != null) {
                    val value = String(bytes, offset + 1, frameSize - 1, charset).trim('\u0000', ' ', '\n', '\r')
                    if (value.isNotEmpty() || key == "title") result[key] = value
                }
            }
            offset += frameSize
        }
        return if (result.containsKey("title")) result.toMap() else emptyMap()
    }
}
