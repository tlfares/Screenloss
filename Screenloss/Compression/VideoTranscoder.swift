import AVFoundation
import VideoToolbox

/// Re-encodes a video to HEVC at a chosen bit rate. Audio is passed through
/// untouched, HDR stays HDR (10-bit, same color tags), rotation and the
/// file's metadata (location, date, device) are carried over.
nonisolated final class VideoTranscoder: @unchecked Sendable {
    struct Request: Sendable {
        var recipe: CompressionRecipe
        var originalSize: Int64
        var isScreenRecording: Bool
        /// Copies timed metadata tracks too. A Live Photo's video marks the
        /// frame its photo was taken at in one of them.
        var keepsTimedMetadata = false
    }

    private final class Pump: @unchecked Sendable {
        let output: AVAssetReaderOutput
        let input: AVAssetWriterInput
        let isVideo: Bool
        let queue: DispatchQueue
        var isFinished = false
        var lastReported = -1.0

        init(output: AVAssetReaderOutput, input: AVAssetWriterInput, isVideo: Bool, label: String) {
            self.output = output
            self.input = input
            self.isVideo = isVideo
            queue = DispatchQueue(label: label, qos: .userInitiated)
        }
    }

    private let asset: AVAsset
    private let outputURL: URL
    private let request: Request
    private let lock = NSLock()
    private var isCancelled = false
    private var reader: AVAssetReader?
    private var writer: AVAssetWriter?
    private var pumps: [Pump] = []
    private var group: DispatchGroup?

    init(asset: AVAsset, outputURL: URL, request: Request) {
        self.asset = asset
        self.outputURL = outputURL
        self.request = request
    }

    /// Stops reading; the writer is cancelled once every track has let go,
    /// never while one could still be appending.
    func cancel() {
        let reader = lock.withLock {
            isCancelled = true
            return self.reader
        }
        reader?.cancelReading()
        abortAll()
    }

    /// Ends every track from its own queue. A writer that failed or stopped
    /// doesn't ask for more data, so the tracks would otherwise wait forever.
    private func abortAll() {
        let (pumps, group) = lock.withLock { (self.pumps, self.group) }
        guard let group else { return }
        for pump in pumps {
            pump.queue.async { [self] in finish(pump, group: group) }
        }
    }

    private var cancelled: Bool { lock.withLock { isCancelled } }

    @concurrent
    func transcode(progress: @escaping @Sendable (Double) -> Void) async throws -> Int64 {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw TranscodeError.unreadable }
        let (naturalSize, transform, frameRate, dataRate, formats, timeScale) = try await track.load(
            .naturalSize, .preferredTransform, .nominalFrameRate, .estimatedDataRate, .formatDescriptions, .naturalTimeScale
        )
        let duration = try await asset.load(.duration).seconds
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let metadataTracks = request.keepsTimedMetadata ? try await asset.loadTracks(withMediaType: .metadata) : []
        let metadata = try await asset.load(.metadata)
        guard let format = formats.first, duration > 0 else { throw TranscodeError.unreadable }

        let recipe = request.recipe
        let width = Int(abs(naturalSize.width).rounded())
        let height = Int(abs(naturalSize.height).rounded())
        guard width > 0, height > 0 else { throw TranscodeError.unreadable }
        let size = VideoPlan.dimensions(width: width, height: height, limit: recipe.videoLimit)
        let downscaled = size.width < width
        let isHEVC = CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC

        if recipe.videoQuality == .convert, !downscaled, isHEVC { throw TranscodeError.alreadyEfficient }

        let fps = frameRate > 0 ? Double(frameRate) : (request.isScreenRecording ? 60 : 30)
        let sourceBitrate = dataRate > 0 ? Double(dataRate) : Double(request.originalSize) * 8 / duration
        let bitrate = VideoPlan.bitrate(
            sourceBitrate: sourceBitrate, width: size.width, height: size.height,
            fps: fps, quality: recipe.videoQuality, downscaled: downscaled
        )
        if !downscaled, bitrate >= sourceBitrate * (1 - recipe.minimumSaving) { throw TranscodeError.noGain }
        if cancelled { throw TranscodeError.cancelled }

        let color = ColorTags(format)
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

        // Video: decoded to YUV at the source's depth, encoded to HEVC.
        let pixelFormat = color.isTenBit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let videoOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        videoOutput.alwaysCopiesSampleData = false

        var videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(bitrate),
                AVVideoExpectedSourceFrameRateKey: Int(fps.rounded()),
                AVVideoProfileLevelKey: (color.isTenBit ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel) as String,
            ] as [String: Any],
        ]
        if downscaled { videoSettings[AVVideoScalingModeKey] = AVVideoScalingModeResizeAspectFill }
        if let properties = color.properties { videoSettings[AVVideoColorPropertiesKey] = properties }
        if !writer.canApply(outputSettings: videoSettings, forMediaType: .video) {
            // Untagged HDR would play back washed out: better to not convert.
            guard !color.isHDR else { throw TranscodeError.encoderUnavailable }
            videoSettings.removeValue(forKey: AVVideoColorPropertiesKey)
            guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else { throw TranscodeError.encoderUnavailable }
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.transform = transform
        videoInput.expectsMediaDataInRealTime = false
        if timeScale > 0 { videoInput.mediaTimeScale = timeScale }
        guard reader.canAdd(videoOutput), writer.canAdd(videoInput) else { throw TranscodeError.encoderUnavailable }
        reader.add(videoOutput)
        writer.add(videoInput)
        var pumps = [Pump(output: videoOutput, input: videoInput, isVideo: true, label: "video")]

        // Audio: copied as is; re-encoded to AAC only if the container
        // refuses the original codec.
        for (index, audioTrack) in audioTracks.enumerated() {
            let hint = try await audioTrack.load(.formatDescriptions).first
            let passOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            let passInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: hint)
            if hint != nil, reader.canAdd(passOutput), writer.canAdd(passInput) {
                reader.add(passOutput)
                writer.add(passInput)
                pumps.append(Pump(output: passOutput, input: passInput, isVideo: false, label: "audio.\(index)"))
                continue
            }
            let sampleRate = hint.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mSampleRate } ?? 48_000
            let pcmOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            let aacSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000,
            ]
            guard writer.canApply(outputSettings: aacSettings, forMediaType: .audio) else { throw TranscodeError.encoderUnavailable }
            let aacInput = AVAssetWriterInput(mediaType: .audio, outputSettings: aacSettings)
            guard reader.canAdd(pcmOutput), writer.canAdd(aacInput) else { throw TranscodeError.encoderUnavailable }
            reader.add(pcmOutput)
            writer.add(aacInput)
            pumps.append(Pump(output: pcmOutput, input: aacInput, isVideo: false, label: "audio.\(index)"))
        }

        for (index, metadataTrack) in metadataTracks.enumerated() {
            let hint = try await metadataTrack.load(.formatDescriptions).first
            let output = AVAssetReaderTrackOutput(track: metadataTrack, outputSettings: nil)
            let input = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: hint)
            guard hint != nil, reader.canAdd(output), writer.canAdd(input) else { throw TranscodeError.encoderUnavailable }
            reader.add(output)
            writer.add(input)
            pumps.append(Pump(output: output, input: input, isVideo: false, label: "metadata.\(index)"))
        }

        writer.metadata = metadata.filter {
            $0.keySpace == .quickTimeMetadata || $0.keySpace == .quickTimeUserData || $0.keySpace == .isoUserData
        }

        lock.withLock {
            self.reader = reader
            self.writer = writer
            self.pumps = pumps
        }
        if cancelled { throw TranscodeError.cancelled }

        guard reader.startReading() else { throw TranscodeError.writerFailed(reader.error?.localizedDescription ?? "Reading failed.") }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw TranscodeError.writerFailed(writer.error?.localizedDescription ?? "Writing failed.")
        }
        writer.startSession(atSourceTime: .zero)

        await pumpAll(duration: duration, progress: progress)

        if reader.status == .reading, writer.status != .writing || cancelled { reader.cancelReading() }
        if cancelled {
            if writer.status == .writing { writer.cancelWriting() }
            try? FileManager.default.removeItem(at: outputURL)
            throw TranscodeError.cancelled
        }
        if reader.status == .failed || writer.status == .failed {
            let reason = (writer.error ?? reader.error)?.localizedDescription ?? "Encoding failed."
            if writer.status == .writing { writer.cancelWriting() }
            try? FileManager.default.removeItem(at: outputURL)
            throw TranscodeError.writerFailed(reason)
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: outputURL)
            throw TranscodeError.writerFailed(writer.error?.localizedDescription ?? "Encoding failed.")
        }

        try await verify(expectedDuration: duration, audioTrackCount: audioTracks.count, metadataTrackCount: metadataTracks.count)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
        guard bytes > 0 else { throw TranscodeError.encodingFailed }
        return bytes
    }

    /// Feeds every track on its own queue, so a track waiting on the writer
    /// can never hold up another one.
    private func pumpAll(duration: Double, progress: @escaping @Sendable (Double) -> Void) async {
        let pumps = lock.withLock { self.pumps }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            for _ in pumps { group.enter() }
            lock.withLock { self.group = group }
            for pump in pumps {
                pump.input.requestMediaDataWhenReady(on: pump.queue) { [self] in
                    guard !pump.isFinished else { return }
                    while pump.input.isReadyForMoreMediaData {
                        guard !cancelled, let sample = pump.output.copyNextSampleBuffer() else {
                            finish(pump, group: group)
                            return
                        }
                        if pump.isVideo {
                            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                            let fraction = time.isFinite ? min(1, max(0, time / duration)) : pump.lastReported
                            if fraction - pump.lastReported >= 0.005 {
                                pump.lastReported = fraction
                                progress(fraction)
                            }
                        }
                        if !pump.input.append(sample) {
                            finish(pump, group: group)
                            abortAll()
                            return
                        }
                    }
                }
            }
            group.notify(queue: .global(qos: .userInitiated)) { continuation.resume() }
            if cancelled { abortAll() }
        }
    }

    private func finish(_ pump: Pump, group: DispatchGroup) {
        guard !pump.isFinished else { return }
        pump.isFinished = true
        pump.input.markAsFinished()
        group.leave()
    }

    /// Opens the new file before anything is saved: the copy must play for
    /// as long as the original and keep every audio track.
    private func verify(expectedDuration: Double, audioTrackCount: Int, metadataTrackCount: Int) async throws {
        let output = AVURLAsset(url: outputURL)
        let duration = try await output.load(.duration).seconds
        let videoTracks = try await output.loadTracks(withMediaType: .video)
        let audioTracks = try await output.loadTracks(withMediaType: .audio)
        let metadataTracks = request.keepsTimedMetadata ? try await output.loadTracks(withMediaType: .metadata) : []
        let tolerance = max(0.5, expectedDuration * 0.02)
        guard duration.isFinite, abs(duration - expectedDuration) <= tolerance,
              videoTracks.count == 1, audioTracks.count == audioTrackCount,
              metadataTracks.count == metadataTrackCount
        else {
            try? FileManager.default.removeItem(at: outputURL)
            throw TranscodeError.verificationFailed
        }
    }
}

/// A video's color description, read from its format.
nonisolated private struct ColorTags {
    let primaries: String?
    let transfer: String?
    let matrix: String?
    let bitsPerComponent: Int?

    init(_ format: CMFormatDescription) {
        func value(_ key: CFString) -> String? {
            CMFormatDescriptionGetExtension(format, extensionKey: key) as? String
        }
        primaries = value(kCMFormatDescriptionExtension_ColorPrimaries)
        transfer = value(kCMFormatDescriptionExtension_TransferFunction)
        matrix = value(kCMFormatDescriptionExtension_YCbCrMatrix)
        bitsPerComponent = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent) as? Int
    }

    var isHDR: Bool {
        transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
            || transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
    }

    var isTenBit: Bool { isHDR || (bitsPerComponent ?? 8) > 8 }

    var properties: [String: Any]? {
        guard let primaries, let transfer, let matrix else { return nil }
        return [
            AVVideoColorPrimariesKey: primaries,
            AVVideoTransferFunctionKey: transfer,
            AVVideoYCbCrMatrixKey: matrix,
        ]
    }
}
