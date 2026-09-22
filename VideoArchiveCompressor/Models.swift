import AVFoundation
import Foundation

enum ArchivePreset: String, CaseIterable, Identifiable {
    case extremeOriginalResolution
    case tinyHD
    case compact4K
    case preserveResolution

    var id: String { rawValue }

    var title: String {
        switch self {
        case .extremeOriginalResolution: return "NITRO MAX • resolutie behouden"
        case .tinyHD: return "Tiny HD"
        case .compact4K: return "Compact 4K"
        case .preserveResolution: return "Resolutie behouden"
        }
    }

    var subtitle: String {
        switch self {
        case .extremeOriginalResolution:
            return "Zelfde resolutie • directe VideoToolbox HEVC • speed priority • agressieve bitrate"
        case .tinyHD:
            return "Max. 1080p HEVC • kleinste archief"
        case .compact4K:
            return "Max. 4K HEVC • scherper • grotere bestanden"
        case .preserveResolution:
            return "HEVC hoogste kwaliteit • minste ruimtewinst"
        }
    }

    var exportPresetName: String {
        switch self {
        case .extremeOriginalResolution:
            return AVAssetExportPresetHEVCHighestQuality
        case .tinyHD:
            return AVAssetExportPresetHEVC1920x1080
        case .compact4K:
            return AVAssetExportPresetHEVC3840x2160
        case .preserveResolution:
            return AVAssetExportPresetHEVCHighestQuality
        }
    }
}

enum JobState: Equatable {
    case queued
    case encoding
    case done
    case skipped(String)
    case failed(String)

    var label: String {
        switch self {
        case .queued: return "Wachten"
        case .encoding: return "Comprimeren"
        case .done: return "Klaar"
        case .skipped(let reason): return "Overgeslagen: \(reason)"
        case .failed(let reason): return "Fout: \(reason)"
        }
    }
}

struct MediaJob: Identifiable {
    let id = UUID()
    let url: URL
    let originalBytes: Int64
    var outputBytes: Int64?
    var state: JobState = .queued
    var progress: Double = 0

    var fileName: String { url.lastPathComponent }

    var savedBytes: Int64 {
        guard let outputBytes else { return 0 }
        return max(0, originalBytes - outputBytes)
    }
}

struct ScanResult {
    let jobs: [MediaJob]
    let unsupportedCount: Int
    let backupCount: Int
}

extension Int64 {
    var storageString: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
