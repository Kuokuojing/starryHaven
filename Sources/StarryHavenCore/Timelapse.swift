import Foundation
import AVFoundation

public struct TimelapseRequest: Sendable {
    public var frames: [URL] = []
    public var deflickerWindow = 15
    public var fps: Int32 = 24
    public var outputVideoURL: URL?
    public var keyframeDirectory: URL?
    public var keyframeEvery = 0
    public var applyStretch = true
    public init() {}
}

public struct TimelapseResult: Sendable {
    public var videoURL: URL?
    public var keyframes: [URL]
    public var frameCount: Int
    public var log: [String]
    public var firstPreview: ImageBuffer?
    public var flickerBefore: Double = 0
    public var flickerAfter: Double = 0
    public var videoBytes: Int = 0
    public var videoDuration: Double = 0
}

public enum TimelapseError: Error, CustomStringConvertible {
    case noFrames
    case encoder(String)
    public var description: String {
        switch self {
        case .noFrames: return "没有可用的延时帧"
        case .encoder(let s): return "视频编码失败：\(s)"
        }
    }
}

public enum TimelapseProcessor {
    /// Exposure-deflicker: each frame is scaled to the moving average of the
    /// sequence's robust background level. Stars do not affect the estimate.
    public static func deflicker(_ frames: [ImageBuffer], window: Int) -> [ImageBuffer] {
        guard !frames.isEmpty else { return [] }
        var levels: [Double] = []
        for f in frames {
            let bg = Calibration.background(f)
            levels.append(Double(0.2126 * bg.x + 0.7152 * bg.y + 0.0722 * bg.z))
        }
        let half = max(1, window / 2)
        var targets = [Double](repeating: 0, count: levels.count)
        for i in 0..<levels.count {
            let lo = max(0, i - half), hi = min(levels.count - 1, i + half)
            var s = 0.0
            for j in lo...hi { s += levels[j] }
            targets[i] = s / Double(hi - lo + 1)
        }
        var out: [ImageBuffer] = []
        out.reserveCapacity(frames.count)
        for i in 0..<frames.count {
            let target = targets[i]
            let gain = levels[i] > 1e-7 ? target / levels[i] : 1
            let g = Float(min(max(gain, 0.4), 2.5))
            var f = frames[i]
            for p in f.pixels.indices { f.pixels[p] = min(max(f.pixels[p] * g, 0), 1) }
            out.append(f)
        }
        return out
    }

    public static func run(_ request: TimelapseRequest,
                           progress: ((Double, String) -> Void)? = nil) throws -> TimelapseResult {
        guard !request.frames.isEmpty else { throw TimelapseError.noFrames }
        var log: [String] = []
        func report(_ p: Double, _ s: String) { log.append(s); progress?(p, s) }
        var frames: [ImageBuffer] = []
        for (i, url) in request.frames.enumerated() {
            frames.append(try ImageLoader.load(url: url))
            report(0.02 + 0.5 * Double(i + 1) / Double(request.frames.count), "读取 \(url.lastPathComponent)")
        }
        func flicker(_ images: [ImageBuffer]) -> Double {
            let levels = images.map { Double(Calibration.background($0).x) }
            let mean = levels.reduce(0, +) / Double(max(levels.count, 1))
            let sd = sqrt(levels.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(max(levels.count, 1)))
            return sd / max(mean, 1e-9)
        }
        let before = flicker(frames)
        if request.deflickerWindow > 1 {
            report(0.6, "去闪（窗口 \(request.deflickerWindow)）")
            frames = deflicker(frames, window: request.deflickerWindow)
        }
        let after = flicker(frames)
        if request.applyStretch { frames = frames.map { PostProcess.stretch($0) } }
        var keyframes: [URL] = []
        if let dir = request.keyframeDirectory, request.keyframeEvery > 0 {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for i in stride(from: 0, to: frames.count, by: request.keyframeEvery) {
                let url = dir.appendingPathComponent(String(format: "frame-%05d.png", i))
                try ImageWriter.saveDisplay(frames[i], url: url, format: .png8)
                keyframes.append(url)
            }
            report(0.68, "导出 \(keyframes.count) 张关键帧")
        }
        var videoURL: URL?
        if let url = request.outputVideoURL {
            report(0.72, "编码 H.264 视频…")
            try writeVideo(frames: frames, url: url, fps: request.fps, applyGamma: !request.applyStretch)
            videoURL = url
            report(0.98, "已写入 \(url.path)")
        }
        var bytes = 0
        var duration = 0.0
        if let videoURL = videoURL {
            bytes = (try? FileManager.default.attributesOfItem(atPath: videoURL.path)[.size] as? Int) ?? 0
            duration = AVURLAsset(url: videoURL).duration.seconds
            log.append(String(format: "视频：%d 字节，%.2f 秒", bytes, duration))
        }
        report(1.0, "完成：\(frames.count) 帧")
        return TimelapseResult(videoURL: videoURL, keyframes: keyframes, frameCount: frames.count,
                               log: log, firstPreview: frames.first,
                               flickerBefore: before, flickerAfter: after,
                               videoBytes: bytes, videoDuration: duration)
    }

    /// Encodes display-referred frames into an H.264 MP4 using AVFoundation.
    public static func writeVideo(frames: [ImageBuffer], url: URL, fps: Int32, applyGamma: Bool = false) throws {
        guard let first = frames.first else { throw TimelapseError.noFrames }
        let width = first.width & ~1
        let height = first.height & ~1
        guard width > 1, height > 1 else { throw TimelapseError.encoder("frame too small") }
        try? FileManager.default.removeItem(at: url)
        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: url, fileType: .mp4) }
        catch { throw TimelapseError.encoder("\(error)") }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attrs)
        guard writer.canAdd(input) else { throw TimelapseError.encoder("cannot add video input") }
        writer.add(input)
        guard writer.startWriting() else {
            throw TimelapseError.encoder(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)
        let timescale = max(fps, 1)
        for (index, frame) in frames.enumerated() {
            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.003)
            }
            var pb: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb) == kCVReturnSuccess,
                  let buffer = pb else { throw TimelapseError.encoder("pixel buffer") }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let stride = CVPixelBufferGetBytesPerRow(buffer)
                let ptr = base.assumingMemoryBound(to: UInt8.self)
                let scaled = (frame.width == width && frame.height == height) ? frame : frame.resized(toWidth: width, toHeight: height)
                for y in 0..<height {
                    for x in 0..<width {
                        let i = (y * width + x) * 3
                        func byte(_ v: Float) -> UInt8 {
                            let d = applyGamma ? SRGB.encode(v) : v
                            return UInt8(min(max(d, 0), 1) * 255 + 0.5)
                        }
                        let o = y * stride + x * 4
                        ptr[o] = byte(scaled.pixels[i + 2])
                        ptr[o + 1] = byte(scaled.pixels[i + 1])
                        ptr[o + 2] = byte(scaled.pixels[i])
                        ptr[o + 3] = 255
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            if !adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: timescale)) {
                throw TimelapseError.encoder(writer.error?.localizedDescription ?? "append failed")
            }
        }
        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        if writer.status != .completed {
            throw TimelapseError.encoder(writer.error?.localizedDescription ?? "writer status \(writer.status.rawValue)")
        }
    }
}

/// Convenience wrapper used by the CLI.
public enum TimelapseEncoder {
    public static func encode(frames: [ImageBuffer], url: URL, fps: Int32) throws {
        try TimelapseProcessor.writeVideo(frames: frames, url: url, fps: fps)
    }
}
