@preconcurrency import AVFoundation
import CoreMedia
import CoreML
import Foundation
import WhisperKit

/// Feeds VoxBox capture buffers into WhisperKit’s `AudioStreamTranscriber`
/// without opening a second microphone.
nonisolated final class LiveAudioSampleSink: AudioProcessing, @unchecked Sendable {
    private let lock = NSLock()
    private var samples = ContiguousArray<Float>()
    private var converter: AVAudioConverter?

    var relativeEnergy: [Float] = []
    var relativeEnergyWindow: Int = 20

    var audioSamples: ContiguousArray<Float> {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    func append(_ chunk: [Float]) {
        lock.lock()
        samples.append(contentsOf: chunk)
        lock.unlock()
    }

    func ingest(_ sampleBuffer: CMSampleBuffer) {
        guard let pcm = Self.pcmBuffer(from: sampleBuffer),
            let floats = convertToWhisperSamples(pcm)
        else { return }
        append(floats)
    }

    private func convertToWhisperSamples(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(WhisperKit.sampleRate),
            channels: 1,
            interleaved: false
        )
        guard let target else { return nil }
        let source = buffer.format
        if source == target, let channel = buffer.floatChannelData?[0] {
            return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        }
        if converter == nil || converter?.outputFormat != target || converter?.inputFormat != source {
            converter = AVAudioConverter(from: source, to: target)
        }
        guard let converter else { return nil }
        let ratio = target.sampleRate / source.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up) + 32)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            return nil
        }
        var error: NSError?
        var consumed = false
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = out.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
    }

    static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
            var asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee,
            let format = AVAudioFormat(streamDescription: &asbd)
        else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return nil
        }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frames),
            into: buffer.mutableAudioBufferList
        )
        return status == noErr ? buffer : nil
    }

    func purgeAudioSamples(keepingLast keep: Int) {
        lock.lock()
        if samples.count > keep {
            samples.removeFirst(samples.count - keep)
        }
        lock.unlock()
    }

    func startRecordingLive(inputDeviceID: DeviceID?, callback: (([Float]) -> Void)?) throws {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    /// The sink is fed externally via `ingest`; the stream never opens a
    /// microphone. Consumers we use poll `audioSamples` instead.
    func startStreamingRecordingLive(
        inputDeviceID: DeviceID?
    ) -> (AsyncThrowingStream<[Float], Error>, AsyncThrowingStream<[Float], Error>.Continuation) {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lock.unlock()
        return AsyncThrowingStream<[Float], Error>.makeStream(bufferingPolicy: .unbounded)
    }

    func pauseRecording() {}
    func stopRecording() {}
    func resumeRecordingLive(inputDeviceID: DeviceID?, callback: (([Float]) -> Void)?) throws {}

    static func loadAudio(
        fromPath audioFilePath: String,
        channelMode: ChannelMode,
        startTime: Double?,
        endTime: Double?,
        maxReadFrameSize: AVAudioFrameCount?
    ) throws -> AVAudioPCMBuffer {
        try AudioProcessor.loadAudio(
            fromPath: audioFilePath,
            channelMode: channelMode,
            startTime: startTime,
            endTime: endTime,
            maxReadFrameSize: maxReadFrameSize
        )
    }

    static func loadAudio(
        at audioPaths: [String],
        channelMode: ChannelMode
    ) async -> [Result<[Float], Swift.Error>] {
        await AudioProcessor.loadAudio(at: audioPaths, channelMode: channelMode)
    }

    static func padOrTrimAudio(
        fromArray audioArray: [Float],
        startAt startIndex: Int,
        toLength frameLength: Int,
        saveSegment: Bool
    ) -> MLMultiArray? {
        AudioProcessor.padOrTrimAudio(
            fromArray: audioArray,
            startAt: startIndex,
            toLength: frameLength,
            saveSegment: saveSegment
        )
    }

    func padOrTrim(
        fromArray audioArray: [Float],
        startAt startIndex: Int,
        toLength frameLength: Int
    ) -> (any AudioProcessorOutputType)? {
        Self.padOrTrimAudio(
            fromArray: audioArray,
            startAt: startIndex,
            toLength: frameLength,
            saveSegment: false
        )
    }
}
