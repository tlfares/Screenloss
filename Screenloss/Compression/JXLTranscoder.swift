import CJXL
import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import UniformTypeIdentifiers

/// Lossless JPEG XL, with libjxl. A JPEG is repacked as it is (it can be
/// rebuilt byte for byte); anything else is stored pixel for pixel. Every
/// file is decoded again and compared before it's kept.
nonisolated enum JXLTranscoder {
    static func transcode(_ request: ImageTranscoder.Request, to url: URL) throws -> Int64 {
        guard let source = CGImageSourceCreateWithData(request.data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let sourceType = CGImageSourceGetType(source).flatMap({ UTType($0 as String) })
        else { throw TranscodeError.unreadable }

        // HEIF can't be made smaller without loss, and a JPEG XL is done.
        if sourceType.conforms(to: .heif) || sourceType.conforms(to: .heic) || sourceType.identifier == "public.jpeg-xl" {
            throw TranscodeError.alreadyEfficient
        }
        // An HDR gain map would be dropped: the photo would look flat.
        for type in [kCGImageAuxiliaryDataTypeHDRGainMap, kCGImageAuxiliaryDataTypeISOGainMap] {
            if CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, type) != nil { throw TranscodeError.notLossless }
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let encoder = try Encoder()
        if sourceType.conforms(to: .jpeg) {
            try encoder.addJPEG(request.data)
        } else {
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let pixels = Pixels(image)
            else { throw TranscodeError.notLossless }
            let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
            try encoder.addPixels(pixels, icc: image.colorSpace?.copyICCData() as Data?, orientation: orientation) {
                if let exif = exifBox(properties, request: request) { try $0.addBox("Exif", exif) }
                if let xmp = CGImageSourceCopyMetadataAtIndex(source, 0, nil).flatMap({ CGImageMetadataCreateXMPData($0, nil) }) {
                    try $0.addBox("xml ", xmp as Data)
                }
            }
            try encoder.write(to: url)
            do {
                try Decoder.verify(url: url, pixels: pixels)
                try verifyWithImageIO(url: url, source: source, properties: properties, tolerance: 0.5)
            } catch {
                try? FileManager.default.removeItem(at: url)
                throw error
            }
            return size(of: url)
        }
        try encoder.write(to: url)
        do {
            try Decoder.verify(url: url, jpeg: request.data)
            // The file rebuilds the JPEG byte for byte; iOS draws it with
            // another decoder, whose color upsampling differs slightly.
            try verifyWithImageIO(url: url, source: source, properties: properties, tolerance: 6)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return size(of: url)
    }

    private static func size(of url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    // MARK: Metadata

    /// The source's Exif, GPS and TIFF fields as an Exif block. ImageIO
    /// writes it into a tiny JPEG, and the block is lifted from there.
    private static func exifBox(_ properties: [CFString: Any], request: ImageTranscoder.Request) -> Data? {
        var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        if request.isScreenshot { exif[kCGImagePropertyExifUserComment] = "Screenshot" }
        if exif[kCGImagePropertyExifDateTimeOriginal] == nil, let date = request.creationDate {
            exif[kCGImagePropertyExifDateTimeOriginal] = ExifDate.string(from: date)
            exif[kCGImagePropertyExifOffsetTimeOriginal] = ExifDate.offset(for: date)
        }
        var fields: [CFString: Any] = [kCGImagePropertyExifDictionary: exif]
        for key in [kCGImagePropertyGPSDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyMakerAppleDictionary, kCGImagePropertyOrientation] {
            if let value = properties[key] { fields[key] = value }
        }

        let data = NSMutableData()
        guard let space = CGColorSpace(name: CGColorSpace.linearGray),
              let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 8, space: space, bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let tiny = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, tiny, fields as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }

        // Walk the JPEG's segments to the APP1 that starts with "Exif\0\0".
        let bytes = [UInt8](data as Data)
        var index = 2
        while index + 4 <= bytes.count, bytes[index] == 0xFF {
            let marker = bytes[index + 1]
            let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            let start = index + 4
            if marker == 0xE1, start + 6 <= bytes.count, Array(bytes[start..<start + 6]) == [0x45, 0x78, 0x69, 0x66, 0, 0] {
                // The box opens with the offset of the TIFF header: zero.
                return Data([0, 0, 0, 0]) + Data(bytes[(start + 6)..<min(bytes.count, index + 2 + length)])
            }
            if marker == 0xDA { break }
            index += 2 + length
        }
        return nil
    }

    // MARK: Checks

    /// What iOS will read: decodable, the same size and orientation, and
    /// the same picture (a swapped channel or byte order would show here).
    private static func verifyWithImageIO(url: URL, source: CGImageSource, properties: [CFString: Any], tolerance: Double) throws {
        guard let output = CGImageSourceCreateWithURL(url as CFURL, nil),
              let copied = CGImageSourceCopyPropertiesAtIndex(output, 0, nil) as? [CFString: Any],
              copied[kCGImagePropertyPixelWidth] as? Int == properties[kCGImagePropertyPixelWidth] as? Int,
              copied[kCGImagePropertyPixelHeight] as? Int == properties[kCGImagePropertyPixelHeight] as? Int,
              (copied[kCGImagePropertyOrientation] as? Int ?? 1) == (properties[kCGImagePropertyOrientation] as? Int ?? 1),
              let before = thumbnail(source), let after = thumbnail(output),
              before.count == after.count
        else { throw TranscodeError.verificationFailed }
        let difference = zip(before, after).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        guard Double(difference) / Double(before.count) < tolerance else { throw TranscodeError.verificationFailed }
    }

    /// A grid of the image's own pixels, picked without resampling: two
    /// decodes of the same pixels give the same grid.
    private static func thumbnail(_ source: CGImageSource) -> [UInt8]? {
        let side = 96
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data else { return nil }
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: side * side * 4))
    }
}

// MARK: - Pixels

/// An image's decoded samples, packed the way libjxl takes them: color
/// channels then alpha, 8 or 16 bits each. Only reordered, never converted,
/// so they are exactly what ImageIO read from the file.
nonisolated private struct Pixels {
    let width: Int
    let height: Int
    let colorChannels: Int
    let hasAlpha: Bool
    let premultiplied: Bool
    let bytesPerSample: Int
    let littleEndian: Bool
    let data: Data

    var channels: Int { colorChannels + (hasAlpha ? 1 : 0) }
    var stride: Int { width * channels * bytesPerSample }

    var format: JxlPixelFormat {
        JxlPixelFormat(
            num_channels: UInt32(channels),
            data_type: bytesPerSample == 1 ? JXL_TYPE_UINT8 : JXL_TYPE_UINT16,
            endianness: littleEndian ? JXL_LITTLE_ENDIAN : JXL_BIG_ENDIAN,
            align: 0
        )
    }

    init?(_ image: CGImage) {
        let info = image.bitmapInfo
        guard !info.contains(.floatComponents),
              image.bitsPerComponent == 8 || image.bitsPerComponent == 16,
              let model = image.colorSpace?.model, model == .rgb || model == .monochrome,
              let source = image.dataProvider?.data as Data?
        else { return nil }

        let bytesPerSample = image.bitsPerComponent / 8
        let colorChannels = model == .rgb ? 3 : 1
        let alpha = image.alphaInfo
        // Each pixel's samples in memory order: color channels as c0…, alpha
        // as a, padding as nil.
        var layout: [Int?]
        switch alpha {
        case .none: layout = Array(0..<colorChannels)
        case .last, .premultipliedLast: layout = Array(0..<colorChannels) + [colorChannels]
        case .first, .premultipliedFirst: layout = [colorChannels] + Array(0..<colorChannels)
        case .noneSkipLast: layout = Array(0..<colorChannels) + [nil]
        case .noneSkipFirst: layout = [nil] + Array(0..<colorChannels)
        default: return nil
        }
        let byteOrder = CGImageByteOrderInfo(rawValue: info.rawValue & CGBitmapInfo.byteOrderMask.rawValue) ?? .orderDefault
        let littleOrder = byteOrder == .order16Little || byteOrder == .order32Little
        // 8-bit samples in a little-endian word come in reverse (BGRA).
        if bytesPerSample == 1, littleOrder { layout.reverse() }
        guard layout.count * image.bitsPerComponent == image.bitsPerPixel else { return nil }

        let hasAlpha = layout.contains(colorChannels)
        let channels = colorChannels + (hasAlpha ? 1 : 0)
        let width = image.width, height = image.height
        let pixelBytes = image.bitsPerPixel / 8
        let sourceStride = image.bytesPerRow
        let stride = width * channels * bytesPerSample
        guard source.count >= sourceStride * (height - 1) + width * pixelBytes else { return nil }

        // Where each output sample sits within a source pixel.
        var offsets = [Int](repeating: 0, count: channels)
        for (position, sample) in layout.enumerated() {
            if let sample { offsets[sample] = position * bytesPerSample }
        }

        var packed = Data(count: stride * height)
        packed.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
            source.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
                guard let to = out.baseAddress, let from = input.baseAddress else { return }
                let isPacked = offsets == Array(Swift.stride(from: 0, to: channels * bytesPerSample, by: bytesPerSample)) && pixelBytes == channels * bytesPerSample
                for y in 0..<height {
                    let row = from + y * sourceStride
                    let target = to + y * stride
                    if isPacked {
                        target.copyMemory(from: row, byteCount: stride)
                        continue
                    }
                    for x in 0..<width {
                        let pixel = row + x * pixelBytes
                        let destination = target + x * channels * bytesPerSample
                        for channel in 0..<channels {
                            (destination + channel * bytesPerSample).copyMemory(from: pixel + offsets[channel], byteCount: bytesPerSample)
                        }
                    }
                }
            }
        }

        self.width = width
        self.height = height
        self.colorChannels = colorChannels
        self.hasAlpha = hasAlpha
        self.premultiplied = alpha == .premultipliedLast || alpha == .premultipliedFirst
        self.bytesPerSample = bytesPerSample
        self.littleEndian = bytesPerSample == 2 && littleOrder
        self.data = packed
    }
}

// MARK: - libjxl

nonisolated private final class Encoder {
    private let encoder: OpaquePointer
    private let runner: UnsafeMutableRawPointer
    private var settings: OpaquePointer?

    init() throws {
        guard let encoder = JxlEncoderCreate(nil),
              let runner = JxlThreadParallelRunnerCreate(nil, JxlThreadParallelRunnerDefaultNumWorkerThreads())
        else { throw TranscodeError.encoderUnavailable }
        self.encoder = encoder
        self.runner = runner
        try check(JxlEncoderSetParallelRunner(encoder, JxlThreadParallelRunner, runner))
        try check(JxlEncoderUseContainer(encoder, JXL_TRUE))
        try check(JxlEncoderUseBoxes(encoder))
    }

    deinit {
        JxlEncoderDestroy(encoder)
        JxlThreadParallelRunnerDestroy(runner)
    }

    private func frameSettings() throws -> OpaquePointer {
        if let settings { return settings }
        guard let settings = JxlEncoderFrameSettingsCreate(encoder, nil) else { throw TranscodeError.encodingFailed }
        try check(JxlEncoderSetFrameLossless(settings, JXL_TRUE))
        try check(JxlEncoderFrameSettingsSetOption(settings, JXL_ENC_FRAME_SETTING_EFFORT, 7))
        self.settings = settings
        return settings
    }

    /// The JPEG's own data, kept so it can be rebuilt byte for byte. Its
    /// Exif and XMP come along as boxes.
    func addJPEG(_ data: Data) throws {
        try check(JxlEncoderStoreJPEGMetadata(encoder, JXL_TRUE))
        let settings = try frameSettings()
        try data.withUnsafeBytes { bytes in
            try check(JxlEncoderAddJPEGFrame(settings, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count), or: .notLossless)
        }
        JxlEncoderCloseInput(encoder)
    }

    func addPixels(_ pixels: Pixels, icc: Data?, orientation: Int, boxes: (Encoder) throws -> Void) throws {
        var info = JxlBasicInfo()
        JxlEncoderInitBasicInfo(&info)
        info.xsize = UInt32(pixels.width)
        info.ysize = UInt32(pixels.height)
        info.bits_per_sample = UInt32(pixels.bytesPerSample * 8)
        info.num_color_channels = UInt32(pixels.colorChannels)
        info.uses_original_profile = JXL_TRUE
        info.orientation = JxlOrientation(rawValue: UInt32((1...8).contains(orientation) ? orientation : 1))
        if pixels.hasAlpha {
            info.num_extra_channels = 1
            info.alpha_bits = info.bits_per_sample
            info.alpha_premultiplied = pixels.premultiplied ? JXL_TRUE : JXL_FALSE
        }
        try check(JxlEncoderSetBasicInfo(encoder, &info))
        if pixels.hasAlpha {
            var alpha = JxlExtraChannelInfo()
            JxlEncoderInitExtraChannelInfo(JXL_CHANNEL_ALPHA, &alpha)
            alpha.bits_per_sample = info.bits_per_sample
            alpha.alpha_premultiplied = info.alpha_premultiplied
            try check(JxlEncoderSetExtraChannelInfo(encoder, 0, &alpha))
        }

        if let icc, !icc.isEmpty {
            try icc.withUnsafeBytes { bytes in
                try check(JxlEncoderSetICCProfile(encoder, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count))
            }
        } else {
            var color = JxlColorEncoding()
            JxlColorEncodingSetToSRGB(&color, pixels.colorChannels == 1 ? JXL_TRUE : JXL_FALSE)
            try check(JxlEncoderSetColorEncoding(encoder, &color))
        }

        try boxes(self)
        var format = pixels.format
        let settings = try frameSettings()
        try pixels.data.withUnsafeBytes { bytes in
            try check(JxlEncoderAddImageFrame(settings, &format, bytes.baseAddress, bytes.count))
        }
        JxlEncoderCloseInput(encoder)
    }

    func addBox(_ type: String, _ contents: Data) throws {
        let code = Array(type.utf8).map { CChar(bitPattern: $0) }
        guard code.count == 4 else { return }
        try contents.withUnsafeBytes { bytes in
            try code.withUnsafeBufferPointer { name in
                try check(JxlEncoderAddBox(encoder, name.baseAddress, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, JXL_FALSE))
            }
        }
    }

    /// Streams the file out in chunks: a large one never sits whole in memory.
    func write(to url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url)
        else { throw TranscodeError.encodingFailed }
        defer { try? handle.close() }
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            var status = JXL_ENC_ERROR
            let written = buffer.withUnsafeMutableBufferPointer { chunk in
                var next = chunk.baseAddress
                var available = chunk.count
                status = JxlEncoderProcessOutput(encoder, &next, &available)
                return chunk.count - available
            }
            if written > 0 { try handle.write(contentsOf: buffer[0..<written]) }
            if status == JXL_ENC_SUCCESS { return }
            guard status == JXL_ENC_NEED_MORE_OUTPUT else {
                try? FileManager.default.removeItem(at: url)
                throw TranscodeError.encodingFailed
            }
            if Task.isCancelled {
                try? FileManager.default.removeItem(at: url)
                throw TranscodeError.cancelled
            }
        }
    }

    private func check(_ status: JxlEncoderStatus, or error: TranscodeError = .encodingFailed) throws {
        guard status == JXL_ENC_SUCCESS else { throw error }
    }
}

/// Decodes the file with libjxl and holds it against what went in.
nonisolated private enum Decoder {
    /// Every sample, compared as libjxl hands rows over.
    static func verify(url: URL, pixels: Pixels) throws {
        let checker = PixelChecker(pixels)
        try decode(url: url, events: JXL_DEC_BASIC_INFO.rawValue | JXL_DEC_FULL_IMAGE.rawValue) { decoder, status in
            switch status {
            case JXL_DEC_BASIC_INFO:
                var info = JxlBasicInfo()
                guard JxlDecoderGetBasicInfo(decoder, &info) == JXL_DEC_SUCCESS,
                      Int(info.xsize) == pixels.width, Int(info.ysize) == pixels.height
                else { throw TranscodeError.verificationFailed }
            case JXL_DEC_NEED_IMAGE_OUT_BUFFER:
                var format = pixels.format
                let opaque = Unmanaged.passUnretained(checker).toOpaque()
                guard JxlDecoderSetImageOutCallback(decoder, &format, { opaque, x, y, count, samples in
                    guard let opaque, let samples else { return }
                    Unmanaged<PixelChecker>.fromOpaque(opaque).takeUnretainedValue().compare(x: x, y: y, count: count, samples: samples)
                }, opaque) == JXL_DEC_SUCCESS else { throw TranscodeError.verificationFailed }
            default: break
            }
        }
        withExtendedLifetime(checker) {}
        guard checker.isIdentical else { throw TranscodeError.verificationFailed }
    }

    /// The JPEG rebuilt from the file, byte for byte.
    static func verify(url: URL, jpeg: Data) throws {
        var output = [UInt8](repeating: 0, count: jpeg.count + 4096)
        var filled = 0
        try decode(url: url, events: JXL_DEC_JPEG_RECONSTRUCTION.rawValue | JXL_DEC_FULL_IMAGE.rawValue) { decoder, status in
            switch status {
            case JXL_DEC_JPEG_RECONSTRUCTION:
                let result = output.withUnsafeMutableBufferPointer { JxlDecoderSetJPEGBuffer(decoder, $0.baseAddress, $0.count) }
                guard result == JXL_DEC_SUCCESS else { throw TranscodeError.verificationFailed }
            case JXL_DEC_JPEG_NEED_MORE_OUTPUT:
                filled = output.count - JxlDecoderReleaseJPEGBuffer(decoder)
                output += [UInt8](repeating: 0, count: output.count)
                let result = output.withUnsafeMutableBufferPointer { JxlDecoderSetJPEGBuffer(decoder, $0.baseAddress! + filled, $0.count - filled) }
                guard result == JXL_DEC_SUCCESS else { throw TranscodeError.verificationFailed }
            case JXL_DEC_FULL_IMAGE:
                filled = output.count - JxlDecoderReleaseJPEGBuffer(decoder)
            case JXL_DEC_NEED_IMAGE_OUT_BUFFER:
                // Only reached when there's no JPEG to rebuild.
                throw TranscodeError.verificationFailed
            default: break
            }
        }
        guard filled == jpeg.count, output.prefix(filled).elementsEqual(jpeg) else { throw TranscodeError.verificationFailed }
    }

    private static func decode(url: URL, events: UInt32, handle: (OpaquePointer, JxlDecoderStatus) throws -> Void) throws {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped),
              let decoder = JxlDecoderCreate(nil),
              let runner = JxlThreadParallelRunnerCreate(nil, JxlThreadParallelRunnerDefaultNumWorkerThreads())
        else { throw TranscodeError.verificationFailed }
        defer {
            JxlDecoderDestroy(decoder)
            JxlThreadParallelRunnerDestroy(runner)
        }
        guard JxlDecoderSubscribeEvents(decoder, Int32(events)) == JXL_DEC_SUCCESS,
              JxlDecoderSetParallelRunner(decoder, JxlThreadParallelRunner, runner) == JXL_DEC_SUCCESS,
              JxlDecoderSetKeepOrientation(decoder, JXL_TRUE) == JXL_DEC_SUCCESS
        else { throw TranscodeError.verificationFailed }

        try data.withUnsafeBytes { bytes in
            guard JxlDecoderSetInput(decoder, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count) == JXL_DEC_SUCCESS else {
                throw TranscodeError.verificationFailed
            }
            JxlDecoderCloseInput(decoder)
            while true {
                let status = JxlDecoderProcessInput(decoder)
                switch status {
                case JXL_DEC_SUCCESS: return
                case JXL_DEC_ERROR, JXL_DEC_NEED_MORE_INPUT: throw TranscodeError.verificationFailed
                default: try handle(decoder, status)
                }
                if Task.isCancelled { throw TranscodeError.cancelled }
            }
        }
    }
}

/// Compares decoded rows with the samples that were encoded. libjxl calls
/// it from several threads at once.
nonisolated private final class PixelChecker: Sendable {
    private let pixels: Pixels
    private let mismatch = Atomic(false)
    private let covered = Atomic(0)

    init(_ pixels: Pixels) { self.pixels = pixels }

    var isIdentical: Bool {
        !mismatch.load(ordering: .relaxed) && covered.load(ordering: .relaxed) == pixels.width * pixels.height
    }

    func compare(x: Int, y: Int, count: Int, samples: UnsafeRawPointer) {
        let pixelBytes = pixels.channels * pixels.bytesPerSample
        let length = count * pixelBytes
        let offset = y * pixels.stride + x * pixelBytes
        let same = pixels.data.withUnsafeBytes { original in
            offset + length <= original.count && memcmp(original.baseAddress! + offset, samples, length) == 0
        }
        if !same { mismatch.store(true, ordering: .relaxed) }
        covered.add(count, ordering: .relaxed)
    }
}
