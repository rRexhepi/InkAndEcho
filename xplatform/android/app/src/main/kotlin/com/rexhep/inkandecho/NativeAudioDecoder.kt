package com.rexhep.inkandecho

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedOutputStream
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder

// Android audio decoder slot — replaces the ffmpeg-kit dependency on this
// platform. Uses MediaExtractor + MediaCodec to decode any audio file the
// system supports (m4b / mp3 / aac / opus / ...), downmixes to mono, and
// resamples to 16 kHz (or whatever the caller asks for) before writing a
// minimal s16le WAV. Mirrors the high-level shape of FfmpegRunner so the
// Dart side stays platform-agnostic.
//
// Why we own this: ffmpeg-kit's published x86_64 .aar crashes at JNI_OnLoad
// on every modern Android emulator, blocking the app from even starting.
// MediaExtractor / MediaCodec are platform APIs available since API 16 —
// no third-party native dep, no 16 KB page-size compliance work to chase.
object NativeAudioDecoder {
    const val CHANNEL = "inkandecho/native_decoder"
    const val STREAM_CHANNEL = "inkandecho/native_decoder_stream"
    private const val TIMEOUT_US = 10_000L
    private const val STREAM_BUFFER_BYTES = 64 * 1024

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "decode" -> {
                    val source = call.argument<String>("source")!!
                    val output = call.argument<String>("output")!!
                    val start = (call.argument<Number>("startSeconds") ?: 0).toDouble()
                    val duration = call.argument<Number?>("durationSeconds")?.toDouble()
                    val sampleRate = (call.argument<Number>("sampleRate") ?: 16000).toInt()
                    val channels = (call.argument<Number>("channels") ?: 1).toInt()
                    decode(source, output, start, duration, sampleRate, channels)
                    result.success(null)
                }
                "duration" -> {
                    val source = call.argument<String>("source")!!
                    result.success(durationSeconds(source))
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("decode_failed", e.message ?: e.javaClass.simpleName, e.stackTraceToString())
        }
    }

    fun createStreamHandler(): io.flutter.plugin.common.EventChannel.StreamHandler {
        return object : io.flutter.plugin.common.EventChannel.StreamHandler {
            @Volatile private var cancelled = false
            private var thread: Thread? = null

            override fun onListen(arguments: Any?, events: io.flutter.plugin.common.EventChannel.EventSink?) {
                if (events == null || arguments == null) return
                val args = arguments as Map<*, *>
                val source = args["source"] as String
                val sampleRate = (args["sampleRate"] as? Number)?.toInt() ?: 16000
                val channels = (args["channels"] as? Number)?.toInt() ?: 1
                cancelled = false

                thread = Thread {
                    try {
                        streamDecode(source, sampleRate, channels, events)
                    } catch (e: Exception) {
                        android.os.Handler(android.os.Looper.getMainLooper()).post {
                            events.error("stream_failed", e.message, e.stackTraceToString())
                        }
                    }
                }.also { it.start() }
            }

            override fun onCancel(arguments: Any?) {
                cancelled = true
                thread?.interrupt()
                thread = null
            }

            private fun streamDecode(
                sourcePath: String,
                targetSampleRate: Int,
                targetChannels: Int,
                sink: io.flutter.plugin.common.EventChannel.EventSink,
            ) {
                require(targetChannels == 1)

                val extractor = MediaExtractor()
                extractor.setDataSource(sourcePath)

                val trackIndex = (0 until extractor.trackCount).firstOrNull { i ->
                    extractor.getTrackFormat(i).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
                } ?: throw IllegalArgumentException("No audio track in $sourcePath")
                extractor.selectTrack(trackIndex)
                val inputFormat = extractor.getTrackFormat(trackIndex)
                val mime = inputFormat.getString(MediaFormat.KEY_MIME)!!

                val codec = MediaCodec.createDecoderByType(mime)
                codec.configure(inputFormat, null, null, 0)
                codec.start()

                var sourceSampleRate = inputFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                var sourceChannels = inputFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                var ratio = sourceSampleRate.toDouble() / targetSampleRate.toDouble()
                var srcAccum = 0.0

                val bufferInfo = MediaCodec.BufferInfo()
                var doneInput = false
                var doneOutput = false

                val emit = ByteBuffer.allocate(STREAM_BUFFER_BYTES).order(ByteOrder.LITTLE_ENDIAN)
                val handler = android.os.Handler(android.os.Looper.getMainLooper())

                try {
                    while (!doneOutput && !cancelled) {
                        if (!doneInput) {
                            val inIdx = codec.dequeueInputBuffer(TIMEOUT_US)
                            if (inIdx >= 0) {
                                val inBuf = codec.getInputBuffer(inIdx)!!
                                val size = extractor.readSampleData(inBuf, 0)
                                if (size < 0) {
                                    codec.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                                    doneInput = true
                                } else {
                                    codec.queueInputBuffer(inIdx, 0, size, extractor.sampleTime, 0)
                                    extractor.advance()
                                }
                            }
                        }

                        val outIdx = codec.dequeueOutputBuffer(bufferInfo, TIMEOUT_US)
                        when {
                            outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                                val newFormat = codec.outputFormat
                                if (newFormat.containsKey(MediaFormat.KEY_SAMPLE_RATE)) {
                                    sourceSampleRate = newFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                                }
                                if (newFormat.containsKey(MediaFormat.KEY_CHANNEL_COUNT)) {
                                    sourceChannels = newFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                                }
                                ratio = sourceSampleRate.toDouble() / targetSampleRate.toDouble()
                            }
                            outIdx >= 0 -> {
                                if (bufferInfo.size > 0) {
                                    val outBuf = codec.getOutputBuffer(outIdx)!!
                                    outBuf.position(bufferInfo.offset)
                                    outBuf.limit(bufferInfo.offset + bufferInfo.size)
                                    val shorts = outBuf.order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
                                    val frames = shorts.remaining() / sourceChannels
                                    for (f in 0 until frames) {
                                        var sum = 0
                                        for (c in 0 until sourceChannels) {
                                            sum += shorts.get(f * sourceChannels + c).toInt()
                                        }
                                        val mono = (sum / sourceChannels).toShort()
                                        srcAccum += 1.0
                                        while (srcAccum >= ratio) {
                                            srcAccum -= ratio
                                            if (emit.remaining() < 2) {
                                                val chunk = ByteArray(emit.position())
                                                emit.flip()
                                                emit.get(chunk)
                                                emit.clear()
                                                handler.post { sink.success(chunk) }
                                            }
                                            emit.putShort(mono)
                                        }
                                    }
                                }
                                codec.releaseOutputBuffer(outIdx, false)
                                if (bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                                    doneOutput = true
                                }
                            }
                            outIdx == MediaCodec.INFO_TRY_AGAIN_LATER -> {}
                        }
                    }

                    if (emit.position() > 0) {
                        val tail = ByteArray(emit.position())
                        emit.flip()
                        emit.get(tail)
                        handler.post { sink.success(tail) }
                    }

                    handler.post { sink.endOfStream() }
                } finally {
                    codec.stop()
                    codec.release()
                    extractor.release()
                }
            }
        }
    }

    private fun durationSeconds(path: String): Double {
        val mmr = MediaMetadataRetriever()
        return try {
            mmr.setDataSource(path)
            val ms = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
            ms / 1000.0
        } finally {
            mmr.release()
        }
    }

    private fun decode(
        sourcePath: String,
        outputPath: String,
        startSeconds: Double,
        durationSeconds: Double?,
        targetSampleRate: Int,
        targetChannels: Int,
    ) {
        require(targetChannels == 1) { "Only mono output supported (whisper needs mono)" }

        val extractor = MediaExtractor()
        extractor.setDataSource(sourcePath)

        val trackIndex = (0 until extractor.trackCount).firstOrNull { i ->
            extractor.getTrackFormat(i).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
        } ?: throw IllegalArgumentException("No audio track in $sourcePath")
        extractor.selectTrack(trackIndex)
        val inputFormat = extractor.getTrackFormat(trackIndex)
        val mime = inputFormat.getString(MediaFormat.KEY_MIME)!!

        val codec = MediaCodec.createDecoderByType(mime)
        codec.configure(inputFormat, null, null, 0)
        codec.start()

        // Seek before the first packet pump. SEEK_TO_PREVIOUS_SYNC ensures
        // we land at a decodable keyframe; the input PTS filter below skips
        // anything before the requested start.
        if (startSeconds > 0) {
            extractor.seekTo(
                (startSeconds * 1_000_000).toLong(),
                MediaExtractor.SEEK_TO_PREVIOUS_SYNC,
            )
        }
        val startUs = (startSeconds * 1_000_000).toLong()
        val endUs = durationSeconds?.let { ((startSeconds + it) * 1_000_000).toLong() }

        val out = BufferedOutputStream(FileOutputStream(outputFileTruncated(outputPath)))
        // Reserve 44 bytes for the WAV header; we'll rewrite it once we know
        // the final PCM byte count.
        out.write(ByteArray(44))
        var pcmBytes = 0L

        // Resampling state — accumulate fractional source samples per emitted
        // target sample. Linear nearest-neighbor is fine here; whisper is
        // robust to mild aliasing and skipping the polyphase filter keeps
        // the per-chunk latency low on long audiobooks.
        var sourceSampleRate = inputFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        var sourceChannels = inputFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
        var ratio = sourceSampleRate.toDouble() / targetSampleRate.toDouble()
        var srcAccum = 0.0

        val bufferInfo = MediaCodec.BufferInfo()
        var doneInput = false
        var doneOutput = false

        // Small reusable byte buffer for the resampled mono frames so we
        // aren't allocating per-output-buffer.
        val emit = ByteBuffer.allocate(8192).order(ByteOrder.LITTLE_ENDIAN)

        while (!doneOutput) {
            if (!doneInput) {
                val inIdx = codec.dequeueInputBuffer(TIMEOUT_US)
                if (inIdx >= 0) {
                    val inBuf = codec.getInputBuffer(inIdx)!!
                    val size = extractor.readSampleData(inBuf, 0)
                    if (size < 0) {
                        codec.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        doneInput = true
                    } else {
                        val pts = extractor.sampleTime
                        if (endUs != null && pts >= endUs) {
                            codec.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            doneInput = true
                        } else {
                            codec.queueInputBuffer(inIdx, 0, size, pts, 0)
                            extractor.advance()
                        }
                    }
                }
            }

            val outIdx = codec.dequeueOutputBuffer(bufferInfo, TIMEOUT_US)
            when {
                outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    // Some codecs change sample rate / channel layout after
                    // the first packet (e.g. parametric AAC). Re-sync.
                    val newFormat = codec.outputFormat
                    if (newFormat.containsKey(MediaFormat.KEY_SAMPLE_RATE)) {
                        sourceSampleRate = newFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                    }
                    if (newFormat.containsKey(MediaFormat.KEY_CHANNEL_COUNT)) {
                        sourceChannels = newFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                    }
                    ratio = sourceSampleRate.toDouble() / targetSampleRate.toDouble()
                }
                outIdx >= 0 -> {
                    if (bufferInfo.size > 0 && bufferInfo.presentationTimeUs >= startUs) {
                        val outBuf = codec.getOutputBuffer(outIdx)!!
                        outBuf.position(bufferInfo.offset)
                        outBuf.limit(bufferInfo.offset + bufferInfo.size)
                        val shorts = outBuf.order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
                        val frames = shorts.remaining() / sourceChannels
                        emit.clear()
                        for (f in 0 until frames) {
                            // Downmix interleaved frame → mono.
                            var sum = 0
                            for (c in 0 until sourceChannels) {
                                sum += shorts.get(f * sourceChannels + c).toInt()
                            }
                            val mono = (sum / sourceChannels).toShort()
                            srcAccum += 1.0
                            // Emit target samples while we're past the next
                            // resample tick. For upsampling (rare) this may
                            // emit the same sample more than once.
                            while (srcAccum >= ratio) {
                                srcAccum -= ratio
                                if (emit.remaining() < 2) {
                                    out.write(emit.array(), 0, emit.position())
                                    pcmBytes += emit.position()
                                    emit.clear()
                                }
                                emit.putShort(mono)
                            }
                        }
                        if (emit.position() > 0) {
                            out.write(emit.array(), 0, emit.position())
                            pcmBytes += emit.position()
                        }
                    }
                    codec.releaseOutputBuffer(outIdx, false)
                    if (bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                        doneOutput = true
                    }
                }
                outIdx == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                    // Nothing to do — loop and feed more input.
                }
            }
        }

        out.flush()
        out.close()
        codec.stop()
        codec.release()
        extractor.release()

        // Rewrite the WAV header now that we know the data length.
        RandomAccessFile(outputPath, "rw").use { raf ->
            raf.seek(0)
            raf.write(buildWavHeader(targetSampleRate, targetChannels, pcmBytes.toInt()))
        }
    }

    private fun outputFileTruncated(path: String): String {
        // FileOutputStream(path) without append=true truncates on open,
        // which is what we want. Keep the helper so the intent is explicit.
        return path
    }

    private fun buildWavHeader(sampleRate: Int, channels: Int, dataLen: Int): ByteArray {
        val bb = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
        bb.put("RIFF".toByteArray(Charsets.US_ASCII))
        bb.putInt(36 + dataLen)
        bb.put("WAVE".toByteArray(Charsets.US_ASCII))
        bb.put("fmt ".toByteArray(Charsets.US_ASCII))
        bb.putInt(16)            // fmt chunk size
        bb.putShort(1)            // PCM
        bb.putShort(channels.toShort())
        bb.putInt(sampleRate)
        bb.putInt(sampleRate * channels * 2)        // byte rate
        bb.putShort((channels * 2).toShort())       // block align
        bb.putShort(16)                              // bits per sample
        bb.put("data".toByteArray(Charsets.US_ASCII))
        bb.putInt(dataLen)
        return bb.array()
    }
}
