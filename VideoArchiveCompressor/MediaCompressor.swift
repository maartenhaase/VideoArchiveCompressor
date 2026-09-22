import Foundation
import AVFoundation
import CoreMedia
import VideoToolbox

enum CompressionError: LocalizedError {
    case noVideo
    case unsupportedPreset
    case unsupportedContainer
    case exportFailed(String)
    case remuxFailed(String)
    case invalidOutput
    case durationMismatch(source: Double, output: Double)
    case frameRateMismatch(source: Float, output: Float)
    case audioTrackMismatch(source: Int, output: Int)
    case audioChannelMismatch(track: Int, source: Int, output: Int)
    case timecodeTrackMismatch(source: Int, output: Int)
    case notSmaller
    case replaceFailed(String)

    var errorDescription: String? {
        switch self {
        case .noVideo:
            return "geen videotrack"
        case .unsupportedPreset:
            return "preset niet ondersteund"
        case .unsupportedContainer:
            return "container niet veilig vervangbaar"
        case .exportFailed(let message):
            return message
        case .remuxFailed(let message):
            return "FCP-remux mislukt: \(message)"
        case .invalidOutput:
            return "nieuwe video is ongeldig"
        case .durationMismatch(let source, let output):
            return String(
                format: "duur wijkt af: bron %.3fs, nieuw %.3fs",
                source,
                output
            )
        case .frameRateMismatch(let source, let output):
            return String(
                format: "framerate wijkt af: bron %.3f fps, nieuw %.3f fps",
                source,
                output
            )
        case .audioTrackMismatch(let source, let output):
            return "aantal audiotracks wijkt af: bron \(source), nieuw \(output)"
        case .audioChannelMismatch(let track, let source, let output):
            return "audiokanalen track \(track) wijken af: bron \(source), nieuw \(output)"
        case .timecodeTrackMismatch(let source, let output):
            return "timecode-track ontbreekt of wijkt af: bron \(source), nieuw \(output)"
        case .notSmaller:
            return "nieuwe video is niet kleiner"
        case .replaceFailed(let message):
            return message
        }
    }
}

private struct PassthroughPair {
    let reader: AVAssetReader
    let output: AVAssetReaderTrackOutput
    let input: AVAssetWriterInput
    let label: String
}


private final class VTEncodeErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: Error?

    func store(_ error: Error) {
        lock.lock()
        if storedError == nil {
            storedError = error
        }
        lock.unlock()
    }

    func load() -> Error? {
        lock.lock()
        let value = storedError
        lock.unlock()
        return value
    }
}

private final class VTEncodedMovieSink: @unchecked Sendable {
    private let destination: URL
    private let transform: CGAffineTransform
    private let queue = DispatchQueue(
        label: "nl.maarten.VideoArchiveCompressor.vtEncodedSink"
    )

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?

    init(
        destination: URL,
        transform: CGAffineTransform
    ) {
        self.destination = destination
        self.transform = transform
    }

    func append(_ sampleBuffer: CMSampleBuffer) throws {
        try queue.sync {
            if writer == nil {
                guard let format = CMSampleBufferGetFormatDescription(
                    sampleBuffer
                ) else {
                    throw CompressionError.exportFailed(
                        "VideoToolbox gaf geen HEVC-formatbeschrijving"
                    )
                }

                let newWriter = try AVAssetWriter(
                    outputURL: destination,
                    fileType: .mov
                )

                let newInput = AVAssetWriterInput(
                    mediaType: .video,
                    outputSettings: nil,
                    sourceFormatHint: format
                )

                newInput.transform = transform
                newInput.expectsMediaDataInRealTime = false

                guard newWriter.canAdd(newInput) else {
                    throw CompressionError.exportFailed(
                        "HEVC-samples kunnen niet naar MOV worden geschreven"
                    )
                }

                newWriter.add(newInput)

                guard newWriter.startWriting() else {
                    throw CompressionError.exportFailed(
                        newWriter.error?.localizedDescription ??
                        "MOV-writer kon niet starten"
                    )
                }

                newWriter.startSession(atSourceTime: .zero)

                writer = newWriter
                input = newInput
            }

            guard let writer,
                  let input else {
                throw CompressionError.exportFailed(
                    "MOV-writer is niet geïnitialiseerd"
                )
            }

            while !input.isReadyForMoreMediaData &&
                    writer.status == .writing {
                Thread.sleep(forTimeInterval: 0.0005)
            }

            guard writer.status == .writing else {
                throw CompressionError.exportFailed(
                    writer.error?.localizedDescription ??
                    "MOV-writer is gestopt"
                )
            }

            guard input.append(sampleBuffer) else {
                throw CompressionError.exportFailed(
                    writer.error?.localizedDescription ??
                    "HEVC-sample kon niet worden geschreven"
                )
            }
        }
    }

    func finish() async throws {
        let pair: (AVAssetWriter, AVAssetWriterInput) = try queue.sync {
            guard let writer,
                  let input else {
                throw CompressionError.exportFailed(
                    "VideoToolbox heeft geen videoframes opgeleverd"
                )
            }

            input.markAsFinished()
            return (writer, input)
        }

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in

            pair.0.finishWriting {
                if pair.0.status == .completed {
                    continuation.resume()
                } else {
                    continuation.resume(
                        throwing: CompressionError.exportFailed(
                            pair.0.error?.localizedDescription ??
                            "MOV kon niet worden afgerond"
                        )
                    )
                }
            }
        }
    }
}

final class MediaCompressor {
    private(set) var activeExport: AVAssetExportSession?

    func cancelCurrent() {
        activeExport?.cancelExport()
    }

    func compress(
        source: URL,
        preset: ArchivePreset,
        keepBackup: Bool,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> Int64 {
        let fm = FileManager.default
        let asset = AVURLAsset(url: source)

        let sourceVideoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !sourceVideoTracks.isEmpty else {
            throw CompressionError.noVideo
        }

        if preset == .extremeOriginalResolution,
           let firstTrack = sourceVideoTracks.first,
           try await trackUsesHEVC(firstTrack) {
            throw CompressionError.notSmaller
        }

        if preset == .flash720 &&
            source.pathExtension.lowercased() == "mov" {
            return try await compressFlashMOV(
                source: source,
                keepBackup: keepBackup,
                onProgress: onProgress
            )
        }

        if preset == .extremeOriginalResolution &&
            source.pathExtension.lowercased() == "mov" {
            return try await compressExtremeMOV(
                source: source,
                keepBackup: keepBackup,
                onProgress: onProgress
            )
        }

        let compatible = AVAssetExportSession.exportPresets(compatibleWith: asset)
        guard compatible.contains(preset.exportPresetName) else {
            throw CompressionError.unsupportedPreset
        }

        guard let export = AVAssetExportSession(
            asset: asset,
            presetName: preset.exportPresetName
        ) else {
            throw CompressionError.unsupportedPreset
        }

        activeExport = export
        defer { activeExport = nil }

        let originalValues = try source.resourceValues(
            forKeys: [.fileSizeKey, .contentModificationDateKey]
        )
        let originalBytes = Int64(originalValues.fileSize ?? 0)

        let fileType = try chooseFileType(
            for: source,
            supported: export.supportedFileTypes
        )

        let encodedTemp = tempURL(for: source, marker: "VAC_ENCODE")
        let fcpTemp = tempURL(for: source, marker: "VAC_FCP")
        let backup = backupURL(for: source)

        try? fm.removeItem(at: encodedTemp)
        try? fm.removeItem(at: fcpTemp)

        export.outputURL = encodedTemp
        export.outputFileType = fileType
        export.shouldOptimizeForNetworkUse = false

        let progressTask = Task {
            while !Task.isCancelled {
                // Export is most of the work. Reserve the last 8% for the
                // QuickTime remux that restores original audio + timecode.
                onProgress(Double(export.progress) * 0.92)

                if export.status != .waiting && export.status != .exporting {
                    break
                }

                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }

        await withCheckedContinuation { continuation in
            export.exportAsynchronously {
                continuation.resume()
            }
        }

        progressTask.cancel()

        guard export.status == .completed else {
            try? fm.removeItem(at: encodedTemp)

            if export.status == .cancelled {
                throw CancellationError()
            }

            throw CompressionError.exportFailed(
                export.error?.localizedDescription ?? "export mislukt"
            )
        }

        var finalTemp = encodedTemp

        // Final Cut identifies professional camera media by more than just
        // filename + duration. MOV camera originals commonly contain a
        // dedicated QuickTime timecode track. AVAssetExportSession drops it.
        //
        // Rebuild the MOV using:
        // - the newly encoded HEVC video track
        // - ORIGINAL audio tracks unchanged (PCM stays PCM)
        // - ORIGINAL timecode track(s) unchanged
        //
        // This keeps the media range that FCP uses for relinking.
        if source.pathExtension.lowercased() == "mov" {
            onProgress(0.93)

            do {
                try await remuxMOVForFinalCut(
                    original: source,
                    encodedVideoFile: encodedTemp,
                    destination: fcpTemp
                )

                try? fm.removeItem(at: encodedTemp)
                finalTemp = fcpTemp
                onProgress(0.99)
            } catch {
                try? fm.removeItem(at: encodedTemp)
                try? fm.removeItem(at: fcpTemp)
                throw error
            }
        }

        let newBytes = Int64(
            (try finalTemp.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
        )

        guard newBytes > 256_000 else {
            try? fm.removeItem(at: finalTemp)
            throw CompressionError.invalidOutput
        }

        guard originalBytes == 0 || newBytes < originalBytes else {
            try? fm.removeItem(at: finalTemp)
            throw CompressionError.notSmaller
        }

        do {
            try await verifyFinalCutCompatibility(
                source: source,
                output: finalTemp
            )
        } catch {
            try? fm.removeItem(at: finalTemp)
            throw error
        }

        // Never destroy an existing recovery backup automatically.
        if fm.fileExists(atPath: backup.path) {
            try? fm.removeItem(at: finalTemp)
            throw CompressionError.replaceFailed(
                "er bestaat al een .VAC_ORIGINAL-backup voor dit bestand"
            )
        }

        do {
            try fm.moveItem(at: source, to: backup)

            do {
                try fm.copyItem(at: finalTemp, to: source)
                try? fm.removeItem(at: finalTemp)
            } catch {
                try? fm.moveItem(at: backup, to: source)
                try? fm.removeItem(at: finalTemp)

                throw CompressionError.replaceFailed(
                    error.localizedDescription
                )
            }

            if let modificationDate = originalValues.contentModificationDate {
                try? fm.setAttributes(
                    [.modificationDate: modificationDate],
                    ofItemAtPath: source.path
                )
            }

            if !keepBackup {
                try? fm.removeItem(at: backup)
            }
        } catch let error as CompressionError {
            throw error
        } catch {
            try? fm.removeItem(at: finalTemp)

            throw CompressionError.replaceFailed(
                error.localizedDescription
            )
        }

        onProgress(1.0)
        return newBytes
    }

    private func compressFlashMOV(
        source: URL,
        keepBackup: Bool,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> Int64 {
        let fm = FileManager.default
        let asset = AVURLAsset(url: source)

        if let track = try await asset.loadTracks(
            withMediaType: .video
        ).first {
            let sourceRate = try await track.load(.estimatedDataRate)

            // Already tiny? Do not spend minutes re-encoding it.
            if sourceRate > 0 && sourceRate <= 2_500_000 {
                throw CompressionError.notSmaller
            }
        }

        let originalValues = try source.resourceValues(
            forKeys: [.fileSizeKey, .contentModificationDateKey]
        )
        let originalBytes = Int64(originalValues.fileSize ?? 0)

        let encodedTemp = tempURL(
            for: source,
            marker: "VAC_FLASH720_ENCODE"
        )
        let fcpTemp = tempURL(
            for: source,
            marker: "VAC_FLASH720_FCP"
        )
        let backup = backupURL(for: source)

        try? fm.removeItem(at: encodedTemp)
        try? fm.removeItem(at: fcpTemp)

        try await encodeFlash720H264Video(
            source: source,
            destination: encodedTemp,
            onProgress: { value in
                onProgress(value * 0.92)
            }
        )

        onProgress(0.93)

        do {
            try await remuxMOVForFinalCut(
                original: source,
                encodedVideoFile: encodedTemp,
                destination: fcpTemp
            )
        } catch {
            try? fm.removeItem(at: encodedTemp)
            try? fm.removeItem(at: fcpTemp)
            throw error
        }

        try? fm.removeItem(at: encodedTemp)
        onProgress(0.98)

        let newBytes = Int64(
            (try fcpTemp.resourceValues(
                forKeys: [.fileSizeKey]
            )).fileSize ?? 0
        )

        guard newBytes > 256_000 else {
            try? fm.removeItem(at: fcpTemp)
            throw CompressionError.invalidOutput
        }

        guard originalBytes == 0 || newBytes < originalBytes else {
            try? fm.removeItem(at: fcpTemp)
            throw CompressionError.notSmaller
        }

        do {
            try await verifyFinalCutCompatibility(
                source: source,
                output: fcpTemp
            )
        } catch {
            try? fm.removeItem(at: fcpTemp)
            throw error
        }

        if fm.fileExists(atPath: backup.path) {
            try? fm.removeItem(at: fcpTemp)
            throw CompressionError.replaceFailed(
                "er bestaat al een .VAC_ORIGINAL-backup voor dit bestand"
            )
        }

        do {
            try fm.moveItem(at: source, to: backup)

            do {
                try fm.copyItem(at: fcpTemp, to: source)
                try? fm.removeItem(at: fcpTemp)
            } catch {
                try? fm.moveItem(at: backup, to: source)
                try? fm.removeItem(at: fcpTemp)
                throw CompressionError.replaceFailed(
                    error.localizedDescription
                )
            }

            if let modificationDate = originalValues.contentModificationDate {
                try? fm.setAttributes(
                    [.modificationDate: modificationDate],
                    ofItemAtPath: source.path
                )
            }

            if !keepBackup {
                try? fm.removeItem(at: backup)
            }
        } catch let error as CompressionError {
            throw error
        } catch {
            try? fm.removeItem(at: fcpTemp)
            throw CompressionError.replaceFailed(
                error.localizedDescription
            )
        }

        onProgress(1.0)
        return newBytes
    }

    private func encodeFlash720H264Video(
        source: URL,
        destination: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let fm = FileManager.default
        try? fm.removeItem(at: destination)

        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .video)

        guard let track = tracks.first else {
            throw CompressionError.noVideo
        }

        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let fps = try await track.load(.nominalFrameRate)
        let duration = try await asset.load(.duration)

        let sourceWidth = max(16, Int(abs(naturalSize.width).rounded()))
        let sourceHeight = max(16, Int(abs(naturalSize.height).rounded()))

        let scale = min(
            1.0,
            min(
                1280.0 / Double(sourceWidth),
                720.0 / Double(sourceHeight)
            )
        )

        func even(_ value: Double) -> Int {
            max(16, Int(value.rounded(.down)) / 2 * 2)
        }

        let width = even(Double(sourceWidth) * scale)
        let height = even(Double(sourceHeight) * scale)

        let reader: AVAssetReader

        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw CompressionError.exportFailed(
                error.localizedDescription
            )
        }

        let readerOutput = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            ]
        )

        readerOutput.alwaysCopiesSampleData = false

        guard reader.canAdd(readerOutput) else {
            throw CompressionError.exportFailed(
                "videotrack kan niet worden gelezen"
            )
        }

        reader.add(readerOutput)

        var pixelTransfer: VTPixelTransferSession?
        let transferStatus = VTPixelTransferSessionCreate(
            allocator: kCFAllocatorDefault,
            pixelTransferSessionOut: &pixelTransfer
        )

        guard transferStatus == noErr,
              let pixelTransfer else {
            throw CompressionError.exportFailed(
                "snelle 720p-scaler kon niet worden gestart (\(transferStatus))"
            )
        }

        defer {
            VTPixelTransferSessionInvalidate(pixelTransfer)
        }

        _ = VTSessionSetProperty(
            pixelTransfer,
            key: kVTPixelTransferPropertyKey_ScalingMode,
            value: kVTScalingMode_Normal
        )

        var pool: CVPixelBufferPool?

        let poolStatus = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            nil,
            [
                kCVPixelBufferPixelFormatTypeKey as String:
                    Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ] as CFDictionary,
            &pool
        )

        guard poolStatus == kCVReturnSuccess,
              let pool else {
            throw CompressionError.exportFailed(
                "720p pixelbuffer-pool kon niet worden gemaakt"
            )
        }

        var session: VTCompressionSession?

        let hardware: CFDictionary = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder:
                kCFBooleanTrue as Any
        ] as CFDictionary

        var status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: hardware,
            imageBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ] as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )

        if status != noErr || session == nil {
            let preferred: CFDictionary = [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder:
                    kCFBooleanTrue as Any
            ] as CFDictionary

            status = VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                width: Int32(width),
                height: Int32(height),
                codecType: kCMVideoCodecType_H264,
                encoderSpecification: preferred,
                imageBufferAttributes: nil,
                compressedDataAllocator: nil,
                outputCallback: nil,
                refcon: nil,
                compressionSessionOut: &session
            )
        }

        guard status == noErr,
              let session else {
            throw CompressionError.exportFailed(
                "H.264 hardwareencoder kon niet worden gestart (\(status))"
            )
        }

        defer {
            VTCompressionSessionInvalidate(session)
        }

        func set(
            _ key: CFString,
            _ value: CFTypeRef
        ) {
            _ = VTSessionSetProperty(
                session,
                key: key,
                value: value
            )
        }

        let bitrate = fps > 30 ? 2_200_000 : 1_500_000

        set(
            kVTCompressionPropertyKey_AverageBitRate,
            NSNumber(value: bitrate)
        )
        set(
            kVTCompressionPropertyKey_RealTime,
            kCFBooleanTrue
        )
        set(
            kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,
            kCFBooleanTrue
        )
        set(
            kVTCompressionPropertyKey_AllowFrameReordering,
            kCFBooleanFalse
        )
        set(
            kVTCompressionPropertyKey_MaxFrameDelayCount,
            NSNumber(value: 0)
        )
        set(
            kVTCompressionPropertyKey_ExpectedFrameRate,
            NSNumber(value: max(1, fps))
        )
        set(
            kVTCompressionPropertyKey_MaxKeyFrameInterval,
            NSNumber(value: max(30, Int(max(fps, 25) * 2)))
        )
        set(
            kVTCompressionPropertyKey_ProfileLevel,
            kVTProfileLevel_H264_Main_AutoLevel
        )

        let prepare = VTCompressionSessionPrepareToEncodeFrames(
            session
        )

        guard prepare == noErr else {
            throw CompressionError.exportFailed(
                "H.264 hardwareencoder kon niet worden voorbereid (\(prepare))"
            )
        }

        guard reader.startReading() else {
            throw CompressionError.exportFailed(
                reader.error?.localizedDescription ??
                "videoreader kon niet starten"
            )
        }

        let sink = VTEncodedMovieSink(
            destination: destination,
            transform: transform
        )

        let errorBox = VTEncodeErrorBox()
        let group = DispatchGroup()
        let totalSeconds = max(
            0.001,
            CMTimeGetSeconds(duration)
        )

        while reader.status == .reading,
              let sample = readerOutput.copyNextSampleBuffer() {
            if let pendingError = errorBox.load() {
                reader.cancelReading()
                throw pendingError
            }

            guard let sourceBuffer = CMSampleBufferGetImageBuffer(
                sample
            ) else {
                continue
            }

            var scaledBuffer: CVPixelBuffer?
            let createResult = CVPixelBufferPoolCreatePixelBuffer(
                kCFAllocatorDefault,
                pool,
                &scaledBuffer
            )

            guard createResult == kCVReturnSuccess,
                  let scaledBuffer else {
                reader.cancelReading()
                throw CompressionError.exportFailed(
                    "720p framebuffer kon niet worden gemaakt"
                )
            }

            let scaleStatus = VTPixelTransferSessionTransferImage(
                pixelTransfer,
                from: sourceBuffer,
                to: scaledBuffer
            )

            guard scaleStatus == noErr else {
                reader.cancelReading()
                throw CompressionError.exportFailed(
                    "720p hardware-scaling mislukt (\(scaleStatus))"
                )
            }

            let pts = CMSampleBufferGetPresentationTimeStamp(
                sample
            )
            let frameDuration = CMSampleBufferGetDuration(
                sample
            )

            group.enter()
            var infoFlags = VTEncodeInfoFlags()

            let encodeStatus = VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: scaledBuffer,
                presentationTimeStamp: pts,
                duration: frameDuration.isValid
                    ? frameDuration
                    : .invalid,
                frameProperties: nil,
                infoFlagsOut: &infoFlags
            ) {
                status,
                flags,
                encodedSample in

                defer {
                    group.leave()
                }

                guard status == noErr else {
                    errorBox.store(
                        CompressionError.exportFailed(
                            "H.264 encode-fout \(status)"
                        )
                    )
                    return
                }

                if flags.contains(.frameDropped) {
                    errorBox.store(
                        CompressionError.exportFailed(
                            "hardwareencoder heeft een frame laten vallen"
                        )
                    )
                    return
                }

                guard let encodedSample else {
                    errorBox.store(
                        CompressionError.exportFailed(
                            "hardwareencoder gaf geen H.264-frame terug"
                        )
                    )
                    return
                }

                do {
                    try sink.append(encodedSample)
                } catch {
                    errorBox.store(error)
                }
            }

            if encodeStatus != noErr {
                group.leave()
                reader.cancelReading()
                throw CompressionError.exportFailed(
                    "hardwareencoder accepteerde frame niet (\(encodeStatus))"
                )
            }

            let seconds = CMTimeGetSeconds(pts)

            if seconds.isFinite {
                onProgress(
                    min(
                        0.995,
                        max(0, seconds / totalSeconds)
                    )
                )
            }
        }

        if reader.status == .failed {
            throw CompressionError.exportFailed(
                reader.error?.localizedDescription ??
                "videoreader is mislukt"
            )
        }

        let complete = VTCompressionSessionCompleteFrames(
            session,
            untilPresentationTimeStamp: .invalid
        )

        guard complete == noErr else {
            throw CompressionError.exportFailed(
                "hardwareencoder kon niet afronden (\(complete))"
            )
        }

        group.wait()

        if let pendingError = errorBox.load() {
            throw pendingError
        }

        try await sink.finish()
        onProgress(1.0)
    }

    private func compressExtremeMOV(
        source: URL,
        keepBackup: Bool,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> Int64 {
        let fm = FileManager.default

        // Do not waste hours re-encoding material that is already close to
        // our aggressive archive bitrate.
        let sourceAsset = AVURLAsset(url: source)
        if let sourceTrack = try await sourceAsset
            .loadTracks(withMediaType: .video)
            .first {
            let size = try await sourceTrack.load(.naturalSize)
            let fps = try await sourceTrack.load(.nominalFrameRate)
            let sourceRate = try await sourceTrack.load(.estimatedDataRate)

            let targetRate = nitroTargetBitrate(
                width: max(16, Int(abs(size.width).rounded())),
                height: max(16, Int(abs(size.height).rounded())),
                fps: fps
            )

            if sourceRate > 0 &&
                Double(sourceRate) <= Double(targetRate) * 1.20 {
                throw CompressionError.notSmaller
            }
        }

        let originalValues = try source.resourceValues(
            forKeys: [.fileSizeKey, .contentModificationDateKey]
        )
        let originalBytes = Int64(originalValues.fileSize ?? 0)

        let encodedTemp = tempURL(
            for: source,
            marker: "VAC_EXTREME_ENCODE"
        )
        let fcpTemp = tempURL(
            for: source,
            marker: "VAC_EXTREME_FCP"
        )
        let backup = backupURL(for: source)

        try? fm.removeItem(at: encodedTemp)
        try? fm.removeItem(at: fcpTemp)

        try await encodeExtremeHEVCVideo(
            source: source,
            destination: encodedTemp,
            onProgress: { value in
                onProgress(value * 0.92)
            }
        )

        onProgress(0.93)

        do {
            try await remuxMOVForFinalCut(
                original: source,
                encodedVideoFile: encodedTemp,
                destination: fcpTemp
            )
        } catch {
            try? fm.removeItem(at: encodedTemp)
            try? fm.removeItem(at: fcpTemp)
            throw error
        }

        try? fm.removeItem(at: encodedTemp)
        onProgress(0.98)

        let newBytes = Int64(
            (try fcpTemp.resourceValues(
                forKeys: [.fileSizeKey]
            )).fileSize ?? 0
        )

        guard newBytes > 256_000 else {
            try? fm.removeItem(at: fcpTemp)
            throw CompressionError.invalidOutput
        }

        guard originalBytes == 0 || newBytes < originalBytes else {
            try? fm.removeItem(at: fcpTemp)
            throw CompressionError.notSmaller
        }

        do {
            try await verifyFinalCutCompatibility(
                source: source,
                output: fcpTemp
            )
        } catch {
            try? fm.removeItem(at: fcpTemp)
            throw error
        }

        if fm.fileExists(atPath: backup.path) {
            try? fm.removeItem(at: fcpTemp)
            throw CompressionError.replaceFailed(
                "er bestaat al een .VAC_ORIGINAL-backup voor dit bestand"
            )
        }

        do {
            try fm.moveItem(at: source, to: backup)

            do {
                try fm.moveItem(at: fcpTemp, to: source)
            } catch {
                try? fm.moveItem(at: backup, to: source)
                try? fm.removeItem(at: fcpTemp)
                throw CompressionError.replaceFailed(
                    error.localizedDescription
                )
            }

            if let modificationDate = originalValues.contentModificationDate {
                try? fm.setAttributes(
                    [.modificationDate: modificationDate],
                    ofItemAtPath: source.path
                )
            }

            if !keepBackup {
                try? fm.removeItem(at: backup)
            }
        } catch let error as CompressionError {
            throw error
        } catch {
            try? fm.removeItem(at: fcpTemp)
            throw CompressionError.replaceFailed(
                error.localizedDescription
            )
        }

        onProgress(1.0)
        return newBytes
    }

    private func encodeExtremeHEVCVideo(
        source: URL,
        destination: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let fm = FileManager.default
        try? fm.removeItem(at: destination)

        let asset = AVURLAsset(url: source)
        let videoTracks = try await asset.loadTracks(
            withMediaType: .video
        )

        guard let track = videoTracks.first else {
            throw CompressionError.noVideo
        }

        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let fps = try await track.load(.nominalFrameRate)
        let duration = try await asset.load(.duration)

        let width = max(
            16,
            Int(abs(naturalSize.width).rounded())
        )
        let height = max(
            16,
            Int(abs(naturalSize.height).rounded())
        )

        let bitrate = nitroTargetBitrate(
            width: width,
            height: height,
            fps: fps
        )

        let reader: AVAssetReader

        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw CompressionError.exportFailed(
                error.localizedDescription
            )
        }

        // NV12 is the native fast path for Apple's hardware decoder/encoder.
        let readerOutput = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            ]
        )

        readerOutput.alwaysCopiesSampleData = false

        guard reader.canAdd(readerOutput) else {
            throw CompressionError.exportFailed(
                "videotrack kan niet via de hardware-pipeline worden gelezen"
            )
        }

        reader.add(readerOutput)

        var session: VTCompressionSession?

        // First demand Apple's hardware media engine. Only if a Mac truly
        // cannot provide it do we fall back to "hardware preferred".
        let requiredHardware: CFDictionary = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder:
                kCFBooleanTrue as Any
        ] as CFDictionary

        var status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: requiredHardware,
            imageBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ] as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )

        if status != noErr || session == nil {
            let preferredHardware: CFDictionary = [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder:
                    kCFBooleanTrue as Any
            ] as CFDictionary

            status = VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                width: Int32(width),
                height: Int32(height),
                codecType: kCMVideoCodecType_HEVC,
                encoderSpecification: preferredHardware,
                imageBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String:
                        Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:]
                ] as CFDictionary,
                compressedDataAllocator: nil,
                outputCallback: nil,
                refcon: nil,
                compressionSessionOut: &session
            )
        }

        guard status == noErr,
              let session else {
            throw CompressionError.exportFailed(
                "VideoToolbox HEVC-hardwareencoder kon niet worden gestart (\(status))"
            )
        }

        defer {
            VTCompressionSessionInvalidate(session)
        }

        func set(
            _ key: CFString,
            _ value: CFTypeRef,
            required: Bool = false
        ) throws {
            let result = VTSessionSetProperty(
                session,
                key: key,
                value: value
            )

            if required && result != noErr {
                throw CompressionError.exportFailed(
                    "VideoToolbox-instelling \(key) kon niet worden toegepast (\(result))"
                )
            }
        }

        try set(
            kVTCompressionPropertyKey_AverageBitRate,
            NSNumber(value: bitrate),
            required: true
        )

        try set(
            kVTCompressionPropertyKey_RealTime,
            kCFBooleanTrue,
            required: false
        )

        try set(
            kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,
            kCFBooleanTrue,
            required: false
        )

        try set(
            kVTCompressionPropertyKey_AllowFrameReordering,
            kCFBooleanFalse,
            required: false
        )

        try set(
            kVTCompressionPropertyKey_ExpectedFrameRate,
            NSNumber(value: max(1, fps)),
            required: false
        )

        try set(
            kVTCompressionPropertyKey_MaxKeyFrameInterval,
            NSNumber(
                value: max(
                    30,
                    Int(max(fps, 25) * 2)
                )
            ),
            required: false
        )

        try set(
            kVTCompressionPropertyKey_MaxFrameDelayCount,
            NSNumber(value: 0),
            required: false
        )

        try set(
            kVTCompressionPropertyKey_ProfileLevel,
            kVTProfileLevel_HEVC_Main_AutoLevel,
            required: false
        )

        let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(
            session
        )

        guard prepareStatus == noErr else {
            throw CompressionError.exportFailed(
                "VideoToolbox kon de hardwareencoder niet voorbereiden (\(prepareStatus))"
            )
        }

        guard reader.startReading() else {
            throw CompressionError.exportFailed(
                reader.error?.localizedDescription ??
                "videoreader kon niet starten"
            )
        }

        let sink = VTEncodedMovieSink(
            destination: destination,
            transform: transform
        )

        let errorBox = VTEncodeErrorBox()
        let group = DispatchGroup()

        let totalSeconds = max(
            0.001,
            CMTimeGetSeconds(duration)
        )

        while reader.status == .reading,
              let sample = readerOutput.copyNextSampleBuffer() {
            if let pendingError = errorBox.load() {
                reader.cancelReading()
                throw pendingError
            }

            guard let imageBuffer = CMSampleBufferGetImageBuffer(
                sample
            ) else {
                reader.cancelReading()
                throw CompressionError.exportFailed(
                    "videoframe bevat geen pixelbuffer"
                )
            }

            let pts = CMSampleBufferGetPresentationTimeStamp(
                sample
            )

            let frameDuration = CMSampleBufferGetDuration(
                sample
            )

            group.enter()

            var infoFlags = VTEncodeInfoFlags()

            let encodeStatus = VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: imageBuffer,
                presentationTimeStamp: pts,
                duration: frameDuration.isValid
                    ? frameDuration
                    : .invalid,
                frameProperties: nil,
                infoFlagsOut: &infoFlags
            ) {
                status,
                flags,
                encodedSample in

                defer {
                    group.leave()
                }

                guard status == noErr else {
                    errorBox.store(
                        CompressionError.exportFailed(
                            "VideoToolbox encode-fout \(status)"
                        )
                    )
                    return
                }

                if flags.contains(.frameDropped) {
                    errorBox.store(
                        CompressionError.exportFailed(
                            "VideoToolbox heeft een frame laten vallen"
                        )
                    )
                    return
                }

                guard let encodedSample else {
                    errorBox.store(
                        CompressionError.exportFailed(
                            "VideoToolbox gaf geen HEVC-frame terug"
                        )
                    )
                    return
                }

                do {
                    try sink.append(encodedSample)
                } catch {
                    errorBox.store(error)
                }
            }

            if encodeStatus != noErr {
                group.leave()
                reader.cancelReading()

                throw CompressionError.exportFailed(
                    "VideoToolbox accepteerde frame niet (\(encodeStatus))"
                )
            }

            let seconds = CMTimeGetSeconds(pts)

            if seconds.isFinite {
                onProgress(
                    min(
                        0.995,
                        max(0, seconds / totalSeconds)
                    )
                )
            }
        }

        if reader.status == .failed {
            throw CompressionError.exportFailed(
                reader.error?.localizedDescription ??
                "videoreader is mislukt"
            )
        }

        let completeStatus = VTCompressionSessionCompleteFrames(
            session,
            untilPresentationTimeStamp: .invalid
        )

        guard completeStatus == noErr else {
            throw CompressionError.exportFailed(
                "VideoToolbox kon de laatste frames niet afronden (\(completeStatus))"
            )
        }

        group.wait()

        if let pendingError = errorBox.load() {
            throw pendingError
        }

        try await sink.finish()
        onProgress(1.0)
    }

    private func nitroTargetBitrate(
        width: Int,
        height: Int,
        fps: Float
    ) -> Int {
        let pixels = width * height
        let highFrameRate = fps > 30

        // MAX COMPRESSIE: keep every source pixel, but accept visible
        // archive artefacts in exchange for drastically smaller files.
        if pixels <= 1920 * 1080 {
            return highFrameRate ? 2_500_000 : 1_800_000
        } else if pixels <= 2560 * 1440 {
            return highFrameRate ? 4_000_000 : 3_000_000
        } else if pixels <= 3840 * 2160 {
            return highFrameRate ? 6_000_000 : 4_500_000
        } else {
            return highFrameRate ? 9_000_000 : 7_000_000
        }
    }

    private func remuxMOVForFinalCut(
        original: URL,
        encodedVideoFile: URL,
        destination: URL
    ) async throws {
        let fm = FileManager.default
        try? fm.removeItem(at: destination)

        let originalAsset = AVURLAsset(url: original)
        let encodedAsset = AVURLAsset(url: encodedVideoFile)

        let encodedVideos = try await encodedAsset.loadTracks(withMediaType: .video)
        guard let encodedVideo = encodedVideos.first else {
            throw CompressionError.remuxFailed(
                "HEVC-export bevat geen videotrack"
            )
        }

        let originalAudio = try await originalAsset.loadTracks(withMediaType: .audio)
        let originalTimecode = try await originalAsset.loadTracks(withMediaType: .timecode)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        } catch {
            throw CompressionError.remuxFailed(error.localizedDescription)
        }

        var pairs: [PassthroughPair] = []

        // Encoded HEVC video: stream-copy it, so there is no second encode.
        let videoPair = try await makePassthroughPair(
            asset: encodedAsset,
            track: encodedVideo,
            writer: writer,
            label: "video"
        )

        let videoTransform = try await encodedVideo.load(.preferredTransform)
        videoPair.input.transform = videoTransform
        pairs.append(videoPair)

        // Original audio: preserve codec, sample rate, channel layout and
        // number of tracks exactly. This is especially important for FCP.
        for (index, track) in originalAudio.enumerated() {
            let pair = try await makePassthroughPair(
                asset: originalAsset,
                track: track,
                writer: writer,
                label: "audio \(index + 1)"
            )
            pairs.append(pair)
        }

        // Original QuickTime timecode track(s). Apple documents timecode as a
        // separate 'tmcd' media track associated with the video track.
        for (index, track) in originalTimecode.enumerated() {
            let pair = try await makePassthroughPair(
                asset: originalAsset,
                track: track,
                writer: writer,
                label: "timecode \(index + 1)"
            )

            let associationType = AVAssetTrack.AssociationType.timecode.rawValue

            guard videoPair.input.canAddTrackAssociation(
                withTrackOf: pair.input,
                type: associationType
            ) else {
                throw CompressionError.remuxFailed(
                    "timecode kan niet aan videotrack worden gekoppeld"
                )
            }

            videoPair.input.addTrackAssociation(
                withTrackOf: pair.input,
                type: associationType
            )

            pairs.append(pair)
        }

        guard writer.startWriting() else {
            throw CompressionError.remuxFailed(
                writer.error?.localizedDescription ?? "writer kon niet starten"
            )
        }

        writer.startSession(atSourceTime: .zero)

        for pair in pairs {
            guard pair.reader.startReading() else {
                writer.cancelWriting()
                throw CompressionError.remuxFailed(
                    pair.reader.error?.localizedDescription ??
                    "\(pair.label)-reader kon niet starten"
                )
            }
        }

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in

            let group = DispatchGroup()
            let lock = NSLock()
            var firstError: Error?

            func setFirstError(_ error: Error) {
                lock.lock()
                if firstError == nil {
                    firstError = error
                }
                lock.unlock()
            }

            for (index, pair) in pairs.enumerated() {
                group.enter()

                let queue = DispatchQueue(
                    label: "nl.maarten.VideoArchiveCompressor.remux.\(index)"
                )

                pair.input.requestMediaDataWhenReady(on: queue) {
                    while pair.input.isReadyForMoreMediaData {
                        if let sample = pair.output.copyNextSampleBuffer() {
                            if !pair.input.append(sample) {
                                let error = writer.error ??
                                    CompressionError.remuxFailed(
                                        "\(pair.label) kon niet worden geschreven"
                                    )

                                setFirstError(error)
                                pair.input.markAsFinished()
                                group.leave()
                                return
                            }
                        } else {
                            if pair.reader.status == .failed {
                                setFirstError(
                                    pair.reader.error ??
                                    CompressionError.remuxFailed(
                                        "\(pair.label) kon niet worden gelezen"
                                    )
                                )
                            }

                            pair.input.markAsFinished()
                            group.leave()
                            return
                        }
                    }
                }
            }

            group.notify(queue: DispatchQueue.global(qos: .userInitiated)) {
                lock.lock()
                let copyError = firstError
                lock.unlock()

                if let copyError {
                    writer.cancelWriting()
                    continuation.resume(throwing: copyError)
                    return
                }

                writer.finishWriting {
                    if writer.status == .completed {
                        continuation.resume()
                    } else {
                        continuation.resume(
                            throwing: CompressionError.remuxFailed(
                                writer.error?.localizedDescription ??
                                "MOV kon niet worden afgerond"
                            )
                        )
                    }
                }
            }
        }
    }

    private func makePassthroughPair(
        asset: AVAsset,
        track: AVAssetTrack,
        writer: AVAssetWriter,
        label: String
    ) async throws -> PassthroughPair {
        let reader: AVAssetReader

        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw CompressionError.remuxFailed(
                "\(label): \(error.localizedDescription)"
            )
        }

        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: nil
        )

        output.alwaysCopiesSampleData = false

        guard reader.canAdd(output) else {
            throw CompressionError.remuxFailed(
                "\(label): reader-output niet ondersteund"
            )
        }

        reader.add(output)

        let descriptions = try await track.load(.formatDescriptions)
        let formatHint = descriptions.first

        let input = AVAssetWriterInput(
            mediaType: track.mediaType,
            outputSettings: nil,
            sourceFormatHint: formatHint
        )

        input.expectsMediaDataInRealTime = false

        guard writer.canAdd(input) else {
            throw CompressionError.remuxFailed(
                "\(label): writer-input niet ondersteund"
            )
        }

        writer.add(input)

        return PassthroughPair(
            reader: reader,
            output: output,
            input: input,
            label: label
        )
    }

    private func verifyFinalCutCompatibility(
        source: URL,
        output: URL
    ) async throws {
        let oldAsset = AVURLAsset(url: source)
        let newAsset = AVURLAsset(url: output)

        let oldVideoTracks = try await oldAsset.loadTracks(withMediaType: .video)
        let newVideoTracks = try await newAsset.loadTracks(withMediaType: .video)

        guard let oldVideo = oldVideoTracks.first,
              let newVideo = newVideoTracks.first else {
            throw CompressionError.invalidOutput
        }

        let oldDuration = try await oldAsset.load(.duration)
        let newDuration = try await newAsset.load(.duration)

        let oldSeconds = CMTimeGetSeconds(oldDuration)
        let newSeconds = CMTimeGetSeconds(newDuration)

        if oldSeconds.isFinite && newSeconds.isFinite && oldSeconds > 0 {
            // Replacement media must cover the complete original range.
            let tolerance = 0.005

            guard newSeconds + tolerance >= oldSeconds else {
                throw CompressionError.durationMismatch(
                    source: oldSeconds,
                    output: newSeconds
                )
            }
        }

        let oldFPS = try await oldVideo.load(.nominalFrameRate)
        let newFPS = try await newVideo.load(.nominalFrameRate)

        if oldFPS > 0 && newFPS > 0 {
            guard abs(oldFPS - newFPS) < 0.01 else {
                throw CompressionError.frameRateMismatch(
                    source: oldFPS,
                    output: newFPS
                )
            }
        }

        let oldAudio = try await oldAsset.loadTracks(withMediaType: .audio)
        let newAudio = try await newAsset.loadTracks(withMediaType: .audio)

        guard oldAudio.count == newAudio.count else {
            throw CompressionError.audioTrackMismatch(
                source: oldAudio.count,
                output: newAudio.count
            )
        }

        for index in oldAudio.indices {
            let oldChannels = try await channelCount(for: oldAudio[index])
            let newChannels = try await channelCount(for: newAudio[index])

            if let oldChannels, let newChannels {
                guard oldChannels == newChannels else {
                    throw CompressionError.audioChannelMismatch(
                        track: index + 1,
                        source: oldChannels,
                        output: newChannels
                    )
                }
            }
        }

        let oldTimecode = try await oldAsset.loadTracks(withMediaType: .timecode)
        let newTimecode = try await newAsset.loadTracks(withMediaType: .timecode)

        guard oldTimecode.count == newTimecode.count else {
            throw CompressionError.timecodeTrackMismatch(
                source: oldTimecode.count,
                output: newTimecode.count
            )
        }
    }

    private func trackUsesHEVC(
        _ track: AVAssetTrack
    ) async throws -> Bool {
        let descriptions = try await track.load(.formatDescriptions)

        for description in descriptions {
            let subtype = CMFormatDescriptionGetMediaSubType(description)

            if subtype == kCMVideoCodecType_HEVC {
                return true
            }
        }

        return false
    }

    private func channelCount(
        for track: AVAssetTrack
    ) async throws -> Int? {
        let descriptions = try await track.load(.formatDescriptions)

        for description in descriptions {
            guard CMFormatDescriptionGetMediaType(description) == kCMMediaType_Audio else {
                continue
            }

            guard let basic = CMAudioFormatDescriptionGetStreamBasicDescription(
                description
            ) else {
                continue
            }

            return Int(basic.pointee.mChannelsPerFrame)
        }

        return nil
    }

    private func chooseFileType(
        for url: URL,
        supported: [AVFileType]
    ) throws -> AVFileType {
        let ext = url.pathExtension.lowercased()

        let desired: AVFileType

        switch ext {
        case "mov":
            desired = .mov
        case "mp4":
            desired = .mp4
        case "m4v":
            desired = .m4v
        default:
            throw CompressionError.unsupportedContainer
        }

        guard supported.contains(desired) else {
            throw CompressionError.unsupportedContainer
        }

        return desired
    }

    private func tempURL(
        for source: URL,
        marker: String
    ) -> URL {
        // Deliberately use the Mac's internal temporary storage instead of
        // writing the temporary encode beside the source. With mechanical
        // archive HDDs this prevents simultaneous read/write head seeking,
        // which can otherwise dominate total encoding time.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "VideoArchiveCompressorScratch",
                isDirectory: true
            )

        try? FileManager.default.createDirectory(
            at: scratch,
            withIntermediateDirectories: true
        )

        return scratch
            .appendingPathComponent(
                "\(UUID().uuidString)_\(marker)_\(source.deletingPathExtension().lastPathComponent)"
            )
            .appendingPathExtension(source.pathExtension)
    }

    private func backupURL(for source: URL) -> URL {
        source
            .deletingLastPathComponent()
            .appendingPathComponent(".\(source.lastPathComponent).VAC_ORIGINAL")
    }
}
