// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import os.log

private let abwLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "SpeechText",
                             category: "AudioBufferWriter")

/// Collects the segment's audio for the batch STT providers and writes it out as a file
/// they can ingest — FLAC by default, WAV when FLAC can't be produced (see `UploadCodec`).
///
/// The writer owns the one `PCMDownsampler` for the session and converts each tap buffer
/// to 16 kHz mono Int16 *as it arrives*, so that (a) a ten-minute dictation holds ~19 MB
/// rather than 100–230 MB of native float32, and (b) `writeAudioFile()` is a single pass
/// over bytes that already exist — the resampling is no longer paid all at once at stop,
/// which is exactly when the user is waiting for the paste. `append` hands the converted bytes
/// back so the streaming provider can send the same bytes instead of converting a second
/// time; the writer owns the converter (rather than the engine) because it is the one
/// consumer that must exist for every session, streaming or not.
///
/// If no converter can be built for the hardware format (it happens on exotic devices),
/// the writer falls back to what it did before: native buffer copies, converted at stop,
/// with a native-format WAV as the last resort. Losing the recording is never an option.
///
/// `@unchecked Sendable`: the tap's thread appends while main and the stop's task read and
/// write the file, and every stored `var` is read and written under `lock` only.
public final class AudioBufferWriter: @unchecked Sendable {
    /// Speech-to-text APIs downsample to 16 kHz mono internally, so uploading the mic's
    /// native format (typically 48 kHz float32 ≈ 192 KB/s) wastes ~12x the bytes for no
    /// accuracy gain — and blows past provider upload limits after ~2 minutes of speech.
    static let uploadSampleRate: Double = 16000

    /// The container the upload is written in. FLAC is lossless, so the providers hear
    /// exactly what a WAV would give them, but it packs 16 kHz speech into roughly half
    /// the bytes: uploads finish sooner and a long dictation sits further from Groq's
    /// 25 MB ceiling. Both Groq Whisper and ElevenLabs Scribe accept it (verified with
    /// real requests). Flip this to `.wav` to go back to raw PCM uploads everywhere —
    /// the providers pick the MIME type from the file's extension, so nothing else
    /// needs to change.
    static let preferredUploadCodec: UploadCodec = .flac

    /// Frames in one block of Core Audio's FLAC encoder at 16 kHz. A recording shorter
    /// than this is written as a 42-byte file with no `fLaC` header and no samples:
    /// nothing can open it, a provider answers "Audio file might be corrupted", and the
    /// History archive can never be retried. Measured: 3 200 frames (0.2 s) broke,
    /// 4 608 and up (one block, 0.29 s) were valid. Below it the file is a WAV — a few
    /// kilobytes, so FLAC's saving is nothing there anyway.
    static let flacBlockFrames = 4_608

    /// The codec for a file of `frames` 16 kHz frames: the preferred one, unless the
    /// recording is too short for it to encode.
    static func uploadCodec(forFrames frames: Int) -> UploadCodec {
        preferredUploadCodec == .flac && frames < flacBlockFrames ? .wav : preferredUploadCodec
    }

    /// The two containers `writeAudioFile` can produce. Both hold 16 kHz mono 16-bit
    /// samples; only the encoding differs. Everything downstream — the multipart filename
    /// and MIME type, the History archive's filename — is driven by `fileExtension`, so
    /// a `.wav` archived before FLAC existed still retries fine.
    enum UploadCodec {
        case flac
        case wav

        var fileExtension: String {
            switch self {
            case .flac: "flac"
            case .wav: "wav"
            }
        }

        /// `AVAudioFile` settings for a 16 kHz mono 16-bit file in this container.
        var fileSettings: [String: Any] {
            switch self {
            case .flac:
                [AVFormatIDKey: kAudioFormatFLAC,
                 AVSampleRateKey: AudioBufferWriter.uploadSampleRate,
                 AVNumberOfChannelsKey: 1,
                 AVLinearPCMBitDepthKey: 16]
            case .wav:
                AudioBufferWriter.uploadFormat()?.settings ?? [:]
            }
        }
    }

    /// Guards everything below, the converter included. The stop is asynchronous
    /// (`SpeechEngine.stopAudioEngine`), so a tap callback can still be inside `append`
    /// while the stop's task flushes the converter in `writeAudioFile`: two threads
    /// driving one `AVAudioConverter`, whose output buffer the flush may reallocate under
    /// the conversion.
    private let lock = NSLock()

    // Primary path: converted samples.
    /// Set by `prepare`, used by `append` and flushed by `writeAudioFile`, all under
    /// `lock`. `reset()` leaves it alone: the writer is dropped right after.
    private var downsampler: PCMDownsampler?
    private var pcm16 = Data()
    private var pcm16Frames = 0
    /// The loudest converted sample so far, as a fraction of full scale.
    private var pcm16Peak: Float = 0
    /// The converter's delay line has been drained into `pcm16`; `append` must not run again.
    private var flushed = false

    // Fallback path: native copies, converted at stop. Also where audio goes after a
    // mid-session converter error, so that in `writeAudioFile` it follows the converted
    // bytes in order — the archive exists to keep every frame, not the convenient ones.
    private var nativeBuffers: [AVAudioPCMBuffer] = []
    private var nativeFormat: AVAudioFormat?

    /// True while the session's converter is producing 16 kHz bytes. Cleared by `append`
    /// (on the audio thread) if the converter ever errors, after which the buffers are
    /// kept natively and the stream — which only ever gets converted bytes — is starved;
    /// the engine watches for that and lets the batch fallback take the segment. Read from
    /// main and from the tap's thread, so under `lock` like the rest.
    public var isConvertingLive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return convertingLive
    }
    private var convertingLive = false

    public init() {}

    /// Builds the session's converter for the tap's format. Called before the tap is
    /// installed — and again, with no tap in place, when the engine is rebuilt on a new
    /// device mid-segment; without it `append` takes the native-copy fallback path.
    public func prepare(sourceFormat: AVAudioFormat) {
        let downsampler = PCMDownsampler(sourceFormat: sourceFormat, targetRate: Self.uploadSampleRate)
        lock.lock()
        self.downsampler = downsampler
        convertingLive = downsampler != nil
        lock.unlock()
        if downsampler == nil {
            dlog("Audio", "prepare: no converter for \(sourceFormat) — keeping native copies, converting at stop", level: .notice)
        }
    }

    /// Appends one tap buffer and returns its 16 kHz mono Int16 bytes, or nil on the
    /// fallback path (or if this particular buffer failed to convert, or arrived after the
    /// stop's flush). Runs on the tap's thread — never Core Audio's render thread — and
    /// converts under the lock, which the stop's flush takes too. That holds the lock for
    /// about 22 µs per 4 800-frame buffer and 6 µs per 1 024 (medians, Debug build, M1
    /// Pro), against the 100 or 21 ms of audio each holds; the lock was already taken once
    /// per buffer before.
    @discardableResult
    public func append(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard buffer.frameLength > 0 else { return nil }
        lock.lock()
        defer { lock.unlock() }
        // After the stop: the file is written, or being written, from what came before,
        // and the converter has been told the stream ended.
        guard !flushed else { return nil }

        if let downsampler {
            if let pcm = downsampler.convert(buffer) {
                pcm16.append(pcm)
                pcm16Frames += pcm.count / MemoryLayout<Int16>.size
                pcm16Peak = max(pcm16Peak, Self.peak(ofPCM16: pcm))
                return pcm
            }
            // A genuine converter error (priming returns empty bytes, not nil). Keep this
            // and every later buffer natively rather than dropping it: the converted bytes
            // so far and the native tail are written back to back at stop.
            abwLog.error("append: converter failed on a \(buffer.frameLength) frame buffer — keeping native copies from here on")
            self.downsampler = nil
            convertingLive = false
        }

        appendNative(buffer)
        return nil
    }

    /// Drains the resampler's delay line into `pcm16`. `AVAudioConverter` holds back a few
    /// milliseconds of audio between calls and only releases it on `.endOfStream`, so
    /// without this the last frames of every recording — the tail of the final syllable —
    /// would be missing from the file. Runs when the stop's task writes the file, which may
    /// be before the asynchronous stop has removed the tap: `flushed`, set under the same
    /// lock `append` converts under, is what keeps a late buffer out. A no-op on the
    /// native path.
    private func flushConverter() {
        lock.lock()
        defer { lock.unlock() }
        guard !flushed else { return }
        flushed = true
        guard let downsampler, let tail = downsampler.flush(), !tail.isEmpty else { return }
        pcm16.append(tail)
        pcm16Frames += tail.count / MemoryLayout<Int16>.size
    }

    /// Called by `append` with `lock` held.
    private func appendNative(_ buffer: AVAudioPCMBuffer) {
        guard let src = buffer.floatChannelData else {
            abwLog.error("append: buffer has nil floatChannelData, skipping")
            return
        }
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format,
                                          frameCapacity: buffer.frameLength) else {
            abwLog.error("append: failed to create copy buffer")
            return
        }
        copy.frameLength = buffer.frameLength

        guard let dst = copy.floatChannelData else {
            abwLog.error("append: copy buffer has nil floatChannelData")
            return
        }

        for ch in 0 ..< Int(buffer.format.channelCount) {
            memcpy(dst[ch], src[ch], Int(buffer.frameLength) * MemoryLayout<Float>.size)
        }

        if nativeFormat == nil {
            nativeFormat = buffer.format
        }
        nativeBuffers.append(copy)
    }

    /// Writes the buffered audio to a temp file for upload (or for the History archive)
    /// and returns its URL. The extension tells the caller what it got: `.flac` on the
    /// normal path, `.wav` if the FLAC encoder refused (logged) or if the recording is on
    /// the native-format last resort. Throws `noAudio` if nothing was buffered.
    public func writeAudioFile() throws -> URL {
        flushConverter()

        lock.lock()
        let capturedPCM = pcm16
        let capturedFrames = pcm16Frames
        let capturedFormat = nativeFormat
        let capturedBuffers = nativeBuffers
        lock.unlock()

        let tempURL: URL
        let nativeFrames = capturedBuffers.reduce(0) { $0 + Int($1.frameLength) }
        let hasNative = capturedFormat != nil && nativeFrames > 0
        let totalFrames = capturedFrames + nativeFrames
        let duration = Double(capturedFrames) / Self.uploadSampleRate
            + (capturedFormat.map { Double(nativeFrames) / $0.sampleRate } ?? 0)
        let codec = Self.uploadCodec(forFrames: Int((duration * Self.uploadSampleRate).rounded()))

        if capturedFrames > 0 || hasNative {
            dlog("Audio", "writeAudioFile: \(capturedPCM.count) converted bytes, \(capturedBuffers.count) native buffer(s)")
            do {
                // The converted bytes go first, then any native buffers (the whole
                // recording on the fallback path, or the tail after a converter error)
                // downsampled into the same file, so the timeline stays in order.
                tempURL = try Self.writeWithCodecFallback(preferred: codec) { codec, url in
                    let outputFile = try Self.makeOutputFile(codec: codec, at: url)
                    if capturedFrames > 0 {
                        try Self.writeConverted(pcm16: capturedPCM, frames: capturedFrames, to: outputFile)
                    }
                    if let capturedFormat, hasNative {
                        try Self.writeDownsampled(buffers: capturedBuffers, sourceFormat: capturedFormat,
                                                  to: outputFile)
                    }
                }
            } catch {
                if capturedFrames > 0, hasNative {
                    // The mixed path exists because the live converter already errored
                    // mid-session, so the fresh converter over the same native tail
                    // erroring again is the likely case — and the converted bytes are
                    // fine. Rewrite the file from them alone: losing the tail beats
                    // losing the recording.
                    dlog("Audio", "writeAudioFile: native tail failed to downsample (\(error.localizedDescription)) — dropping it, keeping \(capturedFrames) converted frames", level: .error)
                    tempURL = try Self.writeWithCodecFallback(preferred: codec) { codec, url in
                        let outputFile = try Self.makeOutputFile(codec: codec, at: url)
                        try Self.writeConverted(pcm16: capturedPCM, frames: capturedFrames, to: outputFile)
                    }
                } else {
                    // Falls back to the native format (always a WAV — the encoder was never
                    // the problem here) if the converter can't be built, so a conversion
                    // problem degrades to a big file rather than losing the recording entirely.
                    // Only reachable when nothing was converted live: a native WAV cannot
                    // also hold the 16 kHz bytes.
                    guard capturedFrames == 0, let capturedFormat else { throw error }
                    dlog("Audio", "writeAudioFile: downsample failed (\(error.localizedDescription)) — falling back to native format", level: .error)
                    tempURL = try Self.writeAttempt(codec: .wav) { url in
                        try Self.writeNative(buffers: capturedBuffers, format: capturedFormat, to: url)
                    }
                }
            }
        } else {
            dlog("Audio", "writeAudioFile: nothing buffered — throwing noAudio")
            throw AudioBufferWriterError.noAudio
        }

        let bytes = (try? FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? Int) ?? nil
        dlog("Audio", "writeAudioFile: wrote \(totalFrames) frames (\(String(format: "%.1f", duration))s) → \(bytes.map { "\($0) bytes" } ?? "unknown size") at \(tempURL.lastPathComponent)")
        return tempURL
    }

    private static func makeTempURL(codec: UploadCodec) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(codec.fileExtension)
    }

    /// Runs `write` with `preferred` and, if that throws, once more as WAV. The FLAC
    /// encoder lives in Core Audio and has never been seen to throw for 16 kHz mono
    /// Int16 (a recording under one block fails *silently*, which is why
    /// `uploadCodec(forFrames:)` routes it here as WAV to begin with), but a lost
    /// recording is the one outcome this file exists to prevent, so the plain-PCM path
    /// stays one step behind it. Each attempt gets its own temp URL so a half-written
    /// FLAC never carries a `.wav` name, and one that throws leaves no file behind.
    static func writeWithCodecFallback(preferred: UploadCodec,
                                       _ write: (UploadCodec, URL) throws -> Void) throws -> URL {
        do {
            return try writeAttempt(codec: preferred) { try write(preferred, $0) }
        } catch {
            guard preferred != .wav else { throw error }
            dlog("Audio", "writeAudioFile: \(preferred.fileExtension) encoding failed (\(error.localizedDescription)) — falling back to wav", level: .error)
            return try writeAttempt(codec: .wav) { try write(.wav, $0) }
        }
    }

    /// Runs `write` into a fresh temp file of `codec`, removing whatever it wrote there if
    /// it throws: a half-written file is the user's speech left in the temp folder, with
    /// no History row pointing at it and nothing to clean it up.
    private static func writeAttempt(codec: UploadCodec, _ write: (URL) throws -> Void) throws -> URL {
        let url = makeTempURL(codec: codec)
        do {
            try write(url)
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// Total duration of the buffered audio, in seconds.
    /// False only when every sample of the segment stayed under
    /// `STTTuning.silencePeakFloor` — a muted or dead microphone, a hotkey pressed and
    /// nothing said. Audio kept on the native fallback path is not measured and counts
    /// as audible: the guard may skip an upload, never lose speech to a guess.
    var hasAudibleSignal: Bool {
        lock.lock()
        defer { lock.unlock() }
        if nativeBuffers.contains(where: { $0.frameLength > 0 }) { return true }
        return pcm16Peak >= STTTuning.silencePeakFloor
    }

    static func peak(ofPCM16 data: Data) -> Float {
        data.withUnsafeBytes { raw in
            var peak: Int32 = 0
            for sample in raw.bindMemory(to: Int16.self) {
                peak = max(peak, abs(Int32(sample)))
            }
            return Float(peak) / Float(Int16.max)
        }
    }

    /// The segment's audio as 16 kHz mono floats, for the voice activity detector; nil
    /// once any of it fell back to native buffers, which were never converted.
    public var convertedSamples: [Float]? {
        lock.lock()
        let pcm = pcm16
        let unconverted = nativeFormat != nil && !nativeBuffers.isEmpty
        lock.unlock()
        guard !unconverted else { return nil }
        return pcm.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).map { Float($0) / 32_768 }
        }
    }

    public var bufferedDuration: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        var seconds = Double(pcm16Frames) / Self.uploadSampleRate
        if let nativeFormat {
            let frames = nativeBuffers.reduce(0) { $0 + Int($1.frameLength) }
            seconds += Double(frames) / nativeFormat.sampleRate
        }
        return seconds
    }

    static func uploadFormat() -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatInt16,
                      sampleRate: uploadSampleRate,
                      channels: 1,
                      interleaved: true)
    }

    /// Opens the output file for a codec. The *client* format (what `write(from:)` is
    /// handed) is always 16 kHz mono Int16; `AVAudioFile` encodes to the container in
    /// `codec.fileSettings` on the way out, which for FLAC is where the compression happens.
    private static func makeOutputFile(codec: UploadCodec, at url: URL) throws -> AVAudioFile {
        try AVAudioFile(
            forWriting: url,
            settings: codec.fileSettings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
    }

    /// The samples are already in the client format, so this is a single pass through
    /// `AVAudioFile` — no sample-rate converter involved, only the container's encoder.
    ///
    /// Written in fixed-size chunks through one reused buffer: a buffer sized to the
    /// whole recording doubled the audio in memory (≈19 MB more for ten minutes) at the
    /// stop, which is exactly when the user is waiting for the paste.
    private static func writeConverted(pcm16: Data, frames: Int, to outputFile: AVAudioFile) throws {
        guard let targetFormat = uploadFormat() else {
            throw AudioBufferWriterError.conversionFailed("could not create 16 kHz mono format")
        }
        let chunkFrames = min(frames, 65_536)
        guard chunkFrames > 0 else { return }
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat,
                                               frameCapacity: AVAudioFrameCount(chunkFrames)),
              let channel = outBuffer.int16ChannelData else {
            throw AudioBufferWriterError.conversionFailed("could not allocate output buffer")
        }
        let bytesPerFrame = MemoryLayout<Int16>.size
        try pcm16.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < frames {
                let count = min(chunkFrames, frames - offset)
                memcpy(channel[0], base + offset * bytesPerFrame, count * bytesPerFrame)
                outBuffer.frameLength = AVAudioFrameCount(count)
                try outputFile.write(from: outBuffer)
                offset += count
            }
        }
    }

    private static func writeDownsampled(buffers: [AVAudioPCMBuffer],
                                         sourceFormat: AVAudioFormat,
                                         to outputFile: AVAudioFile) throws {
        guard let targetFormat = uploadFormat() else {
            throw AudioBufferWriterError.conversionFailed("could not create 16 kHz mono format")
        }
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw AudioBufferWriterError.conversionFailed("no converter from \(sourceFormat) to \(targetFormat)")
        }
        // Fold multi-channel input down to mono rather than just taking channel 0.
        converter.downmix = true

        var inputIndex = 0
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            guard inputIndex < buffers.count else {
                outStatus.pointee = .endOfStream
                return nil
            }
            let buffer = buffers[inputIndex]
            inputIndex += 1
            outStatus.pointee = .haveData
            return buffer
        }

        while true {
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 8192) else {
                throw AudioBufferWriterError.conversionFailed("could not allocate output buffer")
            }
            var conversionError: NSError?
            let status = converter.convert(to: outBuffer, error: &conversionError, withInputFrom: inputBlock)

            if let conversionError {
                throw AudioBufferWriterError.conversionFailed(conversionError.localizedDescription)
            }
            if outBuffer.frameLength > 0 {
                try outputFile.write(from: outBuffer)
            }
            if status == .endOfStream || status == .error { break }
            if status == .inputRanDry && outBuffer.frameLength == 0 { break }
        }
    }

    private static func writeNative(buffers: [AVAudioPCMBuffer],
                                    format: AVAudioFormat,
                                    to url: URL) throws {
        let outputFile = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        for buffer in buffers {
            try outputFile.write(from: buffer)
        }
    }

    public func reset() {
        lock.lock()
        pcm16 = Data()
        pcm16Frames = 0
        pcm16Peak = 0
        nativeBuffers.removeAll()
        nativeFormat = nil
        flushed = false
        lock.unlock()
        // `downsampler` is not touched here: the writer is dropped right after, and the
        // converter dies with it.
    }

    public static func cleanup(fileURL: URL) {
        try? FileManager.default.removeItem(at: fileURL)
    }

    enum AudioBufferWriterError: LocalizedError {
        case noAudio
        case conversionFailed(String)

        var errorDescription: String? {
            switch self {
            case .noAudio: "No audio was recorded"
            case .conversionFailed(let reason): "Audio conversion failed: \(reason)"
            }
        }
    }
}

// MARK: - Live Downsampler

/// Converts the microphone's native buffers to mono 16-bit PCM at a fixed rate, one
/// buffer at a time, keeping the converter's resampling state between calls. Meant to be
/// driven from the audio tap: the output buffer is reused across calls (grown only if a
/// larger tap buffer arrives) so the realtime thread isn't allocating a fresh
/// `AVAudioPCMBuffer` per callback.
final class PCMDownsampler {
    private let converter: AVAudioConverter
    private let targetFormat: AVAudioFormat
    private let ratio: Double
    private var out: AVAudioPCMBuffer?

    init?(sourceFormat: AVAudioFormat, targetRate: Double) {
        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: targetRate,
                                         channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: sourceFormat, to: target) else {
            return nil
        }
        converter.downmix = true
        self.converter = converter
        self.targetFormat = target
        self.ratio = targetRate / sourceFormat.sampleRate
    }

    /// Converts one buffer. Returns nil only when the converter reports an error; an
    /// empty `Data` is a normal answer while the rate converter primes on the first
    /// buffer (it has consumed the audio, it just hasn't emitted any yet).
    func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        return run(capacity: capacity) { consumed, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            status.pointee = .haveData
            return buffer
        }
    }

    /// Releases the frames the resampler still holds in its delay line by telling it the
    /// stream has ended. Call once, after the last `convert`; the converter is not
    /// reusable afterwards.
    func flush() -> Data? {
        run(capacity: 4096) { _, status in
            status.pointee = .endOfStream
            return nil
        }
    }

    private func run(capacity: AVAudioFrameCount,
                     input: @escaping (_ consumed: Bool, _ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioPCMBuffer?) -> Data? {
        if out == nil || out!.frameCapacity < capacity {
            out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity)
        }
        guard let out else { return nil }
        out.frameLength = 0

        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            let result = input(consumed, status)
            consumed = true
            return result
        }
        guard error == nil, let channel = out.int16ChannelData else {
            return nil
        }
        return Data(bytes: channel[0], count: Int(out.frameLength) * MemoryLayout<Int16>.size)
    }
}
