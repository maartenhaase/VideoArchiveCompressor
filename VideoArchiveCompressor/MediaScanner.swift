import Foundation

enum MediaScanner {
    static let supportedExtensions: Set<String> = ["mov", "mp4", "m4v"]
    static let recognizedButUnsupported: Set<String> = ["mts", "m2ts", "mxf", "avi"]

    static func scan(root: URL) -> ScanResult {
        let fm = FileManager.default
        var jobs: [MediaJob] = []
        var unsupported = 0
        var backups = 0

        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ]

        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return ScanResult(jobs: [], unsupportedCount: 0, backupCount: 0)
        }

        while let url = enumerator.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: Set(keys))

            if values?.isDirectory == true {
                let name = url.lastPathComponent.lowercased()

                if ["render files", "transcoded media", "analysis files"].contains(name) {
                    enumerator.skipDescendants()
                    continue
                }
            }

            guard values?.isRegularFile == true else { continue }

            let lowerPath = url.path.lowercased()

            if lowerPath.contains(".vac_original") {
                backups += 1
                continue
            }
            if lowerPath.contains(".vac_temp") {
                continue
            }

            if lowerPath.contains(".fcpbundle/") && !lowerPath.contains("/original media/") {
                continue
            }

            let ext = url.pathExtension.lowercased()

            if recognizedButUnsupported.contains(ext) {
                unsupported += 1
                continue
            }

            guard supportedExtensions.contains(ext) else { continue }

            if values?.isSymbolicLink == true {
                unsupported += 1
                continue
            }

            let size = Int64(values?.fileSize ?? 0)
            guard size > 0 else { continue }

            jobs.append(MediaJob(url: url, originalBytes: size))
        }

        jobs.sort { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
        return ScanResult(jobs: jobs, unsupportedCount: unsupported, backupCount: backups)
    }
}
