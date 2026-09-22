import Foundation
import AppKit

@MainActor
final class ArchiveViewModel: ObservableObject {
    @Published var sourceURL: URL?
    @Published var jobs: [MediaJob] = []
    @Published var preset: ArchivePreset = .extremeOriginalResolution
    @Published var isScanning = false
    @Published var isRunning = false
    @Published var stopAfterCurrent = false
    @Published var unsupportedCount = 0
    @Published var existingBackupCount = 0
    @Published var statusText = "Kies een FCP Library, map of harde schijf."
    @Published var lastError: String?
    @Published var extremeSummary: String?
    @Published var utilitySummary: String?
    @Published var utilityProgress: Double = 0

    private let compressor = MediaCompressor()

    var totalBytes: Int64 {
        jobs.reduce(0) { $0 + $1.originalBytes }
    }

    var savedBytes: Int64 {
        jobs.reduce(0) { $0 + $1.savedBytes }
    }

    var completedCount: Int {
        jobs.filter {
            switch $0.state {
            case .done, .skipped, .failed:
                return true
            default:
                return false
            }
        }.count
    }

    var overallProgress: Double {
        guard !jobs.isEmpty else { return 0 }

        let finished = Double(completedCount)
        let running = jobs.first(where: {
            if case .encoding = $0.state { return true }
            return false
        })?.progress ?? 0

        return min(1, (finished + running) / Double(jobs.count))
    }

    var finalCutIsRunning: Bool {
        !NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.FinalCut"
        ).isEmpty
    }

    func chooseSource() {
        let panel = NSOpenPanel()
        panel.title = "Kies Final Cut Library, map of harde schijf"
        panel.prompt = "Kies"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.resolvesAliases = true

        if panel.runModal() == .OK, let url = panel.url {
            acceptSource(url)
        }
    }

    func acceptSource(_ url: URL) {
        guard !isRunning else { return }

        if url.pathExtension.lowercased() == "fcpbundle" || url.hasDirectoryPath {
            sourceURL = url
            extremeSummary = nil
            utilitySummary = nil
            utilityProgress = 0
            Task { await scan() }
        } else {
            lastError = "Kies een .fcpbundle, map of harde schijf."
        }
    }

    func scan() async {
        guard let sourceURL else { return }

        isScanning = true
        statusText = "Scannen…"
        jobs = []
        unsupportedCount = 0
        existingBackupCount = 0

        let result = await Task.detached(priority: .userInitiated) {
            MediaScanner.scan(root: sourceURL)
        }.value

        applyScanResult(result)
        isScanning = false
    }

    func startTest() {
        start(limit: 3, keepBackups: true)
    }

    func startFullBatch() {
        start(limit: nil, keepBackups: true)
    }

    func startNitroVideoOnly() {
        guard let root = sourceURL else {
            lastError = "Kies eerst een harde schijf, hoofdmap of FCP Library."
            return
        }

        guard !isRunning else { return }

        if finalCutIsRunning {
            lastError = "Sluit Final Cut Pro eerst."
            return
        }

        if existingBackupCount > 0 {
            lastError = """
            Er staan nog .VAC_ORIGINAL herstelbestanden op deze bron.
            Herstel of verwijder die eerst voordat NITRO wordt gestart.
            """
            return
        }

        isRunning = true
        stopAfterCurrent = false
        preset = .extremeOriginalResolution
        utilitySummary = nil
        utilityProgress = 0

        Task {
            statusText = "NITRO • video's scannen…"

            let result = await Task.detached(priority: .userInitiated) {
                MediaScanner.scan(root: root)
            }.value

            applyScanResult(result)

            for i in jobs.indices {
                jobs[i].state = .queued
                jobs[i].progress = 0
                jobs[i].outputBytes = nil
            }

            if jobs.isEmpty {
                isRunning = false
                utilitySummary = "Geen nieuwe MOV/MP4/M4V-video's gevonden."
                return
            }

            // Safety canary: first three actually converted files keep their
            // originals. After they pass all FCP checks, those temporary
            // backups are removed and the rest runs at full speed.
            var verifiedURLs: [URL] = []
            var processedIndices = Set<Int>()

            statusText = "NITRO • automatische veiligheidstest…"

            for index in jobs.indices {
                if verifiedURLs.count >= 3 { break }
                if stopAfterCurrent { break }

                let outcome = await compressOne(
                    index: index,
                    keepBackup: true
                )

                processedIndices.insert(index)

                switch outcome {
                case .converted:
                    verifiedURLs.append(jobs[index].url)

                case .skipped:
                    continue

                case .failed(let message):
                    isRunning = false
                    lastError = """
                    NITRO is gestopt tijdens de automatische veiligheidstest.

                    \(jobs[index].fileName)
                    \(message)

                    Eventuele geslaagde testclips hebben hun .VAC_ORIGINAL-backup behouden.
                    """
                    return
                }
            }

            if stopAfterCurrent {
                isRunning = false
                statusText = "Gestopt."
                return
            }

            for url in verifiedURLs {
                deleteBackup(for: url)
            }

            let totalCount = max(1, jobs.count)
            statusText = "NITRO • hardware-HEVC comprimeren…"

            for index in jobs.indices {
                if processedIndices.contains(index) { continue }
                if stopAfterCurrent { break }

                _ = await compressOne(
                    index: index,
                    keepBackup: false
                )

                utilityProgress = Double(index + 1) /
                    Double(totalCount)
            }

            isRunning = false
            utilityProgress = 1

            let convertedCount = jobs.reduce(0) { count, job in
                if case .done = job.state {
                    return count + 1
                }
                return count
            }

            utilitySummary = """
            NITRO klaar.
            \(convertedCount) video's gecomprimeerd.
            \(savedBytes.storageString) ruimte bespaard.
            """

            statusText = "NITRO klaar • \(savedBytes.storageString) bespaard"
        }
    }

    func startOrganizeOnly() {
        guard let root = sourceURL else {
            lastError = "Kies eerst een harde schijf of hoofdmap."
            return
        }

        guard !isRunning else { return }

        if finalCutIsRunning {
            lastError = "Sluit Final Cut Pro eerst voordat libraries worden verplaatst."
            return
        }

        if root.pathExtension.lowercased() == "fcpbundle" {
            lastError = "Opruimen & herstructureren is bedoeld voor een hele schijf of hoofdmap."
            return
        }

        isRunning = true
        utilitySummary = nil
        utilityProgress = 0

        Task {
            statusText = "OPRUIMEN • projecten herkennen…"

            let projects = await Task.detached(priority: .userInitiated) {
                ArchiveOrganizer.discoverProjects(in: root)
            }.value

            utilityProgress = 0.25
            statusText = "OPRUIMEN • FCP-cache verwijderen…"

            let cacheBytes = await Task.detached(priority: .userInitiated) {
                ArchiveOrganizer.purgeGeneratedFinalCutMedia(in: root)
            }.value

            utilityProgress = 0.5
            statusText = "OPRUIMEN • losse bestanden sorteren…"

            let loose = await Task.detached(priority: .userInitiated) {
                ArchiveOrganizer.sortLooseFiles(
                    in: root,
                    protecting: projects
                )
            }.value

            utilityProgress = 0.75
            statusText = "OPRUIMEN • projecten per jaar/type ordenen…"

            let organized = await Task.detached(priority: .userInitiated) {
                ArchiveOrganizer.organizeProjects(
                    projects,
                    in: root
                )
            }.value

            utilityProgress = 1
            isRunning = false

            utilitySummary = """
            Opruimen klaar.
            FCP-cache verwijderd: \(cacheBytes.storageString)
            Projecten verplaatst: \(organized.moved)
            Losse bestanden gesorteerd: \(loose.moved)
            Overgeslagen: \(organized.skipped + loose.skipped)

            Alles staat onder \(ArchiveOrganizer.archiveFolderName).
            """

            statusText = "Opruimen klaar"
        }
    }

    func startPhotoCompressionOnly() {
        guard let root = sourceURL else {
            lastError = "Kies eerst een harde schijf of hoofdmap."
            return
        }

        guard !isRunning else { return }

        isRunning = true
        utilitySummary = nil
        utilityProgress = 0

        Task {
            statusText = "FOTO TURBO • JPEG/HEIC zoeken…"

            let photos = await Task.detached(priority: .userInitiated) {
                PhotoCompressor.discover(in: root)
            }.value

            guard !photos.isEmpty else {
                isRunning = false
                utilitySummary = "Geen JPEG/HEIC-foto's gevonden."
                statusText = "Geen foto's gevonden."
                return
            }

            statusText = "FOTO TURBO • \(photos.count) foto's comprimeren…"

            var iterator = photos.makeIterator()
            var completed = 0
            var compressed = 0
            var saved: Int64 = 0
            var failed = 0

            // Photos are small enough to benefit from parallel processing,
            // unlike large videos on a mechanical archive HDD.
            await withTaskGroup(
                of: PhotoCompressionResult.self
            ) { group in
                let workers = min(6, photos.count)

                for _ in 0..<workers {
                    if let url = iterator.next() {
                        group.addTask(priority: .userInitiated) {
                            PhotoCompressor.compress(url)
                        }
                    }
                }

                while let result = await group.next() {
                    completed += 1

                    if result.didCompress {
                        compressed += 1
                        saved += result.savedBytes
                    } else if result.error != nil {
                        failed += 1
                    }

                    utilityProgress = Double(completed) /
                        Double(photos.count)

                    statusText = """
                    FOTO TURBO • \(completed)/\(photos.count) • \(saved.storageString) bespaard
                    """

                    if let next = iterator.next() {
                        group.addTask(priority: .userInitiated) {
                            PhotoCompressor.compress(next)
                        }
                    }
                }
            }

            utilityProgress = 1
            isRunning = false

            utilitySummary = """
            Foto-compressie klaar.
            \(compressed) foto's kleiner gemaakt.
            \(saved.storageString) bespaard.
            \(failed) mislukt.
            Resolutie is behouden.
            """

            statusText = "Foto's klaar • \(saved.storageString) bespaard"
        }
    }

    func startExtremeOneClick() {
        guard let root = sourceURL else {
            lastError = "Kies eerst een harde schijf of hoofdmap."
            return
        }

        guard !isRunning else { return }

        if finalCutIsRunning {
            lastError = "Sluit Final Cut Pro eerst."
            return
        }

        if root.pathExtension.lowercased() == "fcpbundle" {
            lastError = """
            Extreme One Click is bedoeld voor een hele schijf of hoofdmap.
            Voor één FCP Library kun je TEST 3 CLIPS / START HELE BATCH gebruiken.
            """
            return
        }

        if existingBackupCount > 0 {
            lastError = """
            Er staan nog .VAC_ORIGINAL herstelbestanden op deze bron.
            Herstel of verwijder die eerst voordat je Extreme One Click gebruikt.
            """
            return
        }

        isRunning = true
        stopAfterCurrent = false
        extremeSummary = nil
        preset = .extremeOriginalResolution

        Task {
            statusText = "Stap 1/5 • Projecten herkennen…"

            let projects = await Task.detached(priority: .userInitiated) {
                ArchiveOrganizer.discoverProjects(in: root)
            }.value

            statusText = "Stap 2/5 • FCP render/proxy/cache opruimen…"

            let cacheBytes = await Task.detached(priority: .userInitiated) {
                ArchiveOrganizer.purgeGeneratedFinalCutMedia(in: root)
            }.value

            statusText = "Stap 3/5 • Video's scannen…"

            let scanResult = await Task.detached(priority: .userInitiated) {
                MediaScanner.scan(root: root)
            }.value

            applyScanResult(scanResult)

            for i in jobs.indices {
                jobs[i].state = .queued
                jobs[i].progress = 0
                jobs[i].outputBytes = nil
            }

            // Automatic safety canary: first make 3 genuinely converted
            // files while keeping originals. If one fails compatibility,
            // stop before the drive is reorganized.
            var verifiedURLs: [URL] = []
            var processedIndices = Set<Int>()

            if !jobs.isEmpty {
                statusText = "Stap 3/5 • Veiligheidstest op eerste video's…"

                for index in jobs.indices {
                    if verifiedURLs.count >= 3 { break }
                    if stopAfterCurrent { break }

                    let outcome = await compressOne(
                        index: index,
                        keepBackup: true
                    )

                    processedIndices.insert(index)

                    switch outcome {
                    case .converted:
                        verifiedURLs.append(jobs[index].url)

                    case .skipped:
                        continue

                    case .failed(let message):
                        isRunning = false
                        lastError = """
                        Extreme One Click is gestopt tijdens de automatische veiligheidstest.

                        \(jobs[index].fileName)
                        \(message)

                        Succesvolle testclips hebben hun .VAC_ORIGINAL-backup behouden.
                        """
                        return
                    }
                }

                if stopAfterCurrent {
                    isRunning = false
                    statusText = "Gestopt."
                    return
                }

                // Canary passed. Remove only the backups made by this run.
                for url in verifiedURLs {
                    deleteBackup(for: url)
                }

                statusText = "Stap 3/5 • Alle video's extreem comprimeren…"

                for index in jobs.indices {
                    if processedIndices.contains(index) { continue }
                    if stopAfterCurrent { break }

                    _ = await compressOne(
                        index: index,
                        keepBackup: false
                    )
                }
            }

            if stopAfterCurrent {
                isRunning = false
                statusText = "Gestopt • \(savedBytes.storageString) bespaard"
                return
            }

            statusText = "Stap 4/5 • Losse bestanden sorteren…"

            let loose = await Task.detached(priority: .userInitiated) {
                ArchiveOrganizer.sortLooseFiles(
                    in: root,
                    protecting: projects
                )
            }.value

            statusText = "Stap 5/5 • Projecten per jaar/type ordenen…"

            let organized = await Task.detached(priority: .userInitiated) {
                ArchiveOrganizer.organizeProjects(
                    projects,
                    in: root
                )
            }.value

            let totalSaved = savedBytes + cacheBytes
            let convertedCount = jobs.reduce(0) { count, job in
                if case .done = job.state {
                    return count + 1
                }
                return count
            }

            extremeSummary = """
            Klaar.

            Ruimte bespaard: \(totalSaved.storageString)
            Video's verwerkt: \(convertedCount)
            Projecten verplaatst: \(organized.moved)
            Losse bestanden gesorteerd: \(loose.moved)
            Overgeslagen / handmatig controleren: \(organized.skipped + loose.skipped + unsupportedCount)

            Alles staat onder:
            \(ArchiveOrganizer.archiveFolderName)
            """

            statusText = "Extreme opruimbeurt klaar • \(totalSaved.storageString) bespaard"
            isRunning = false
        }
    }

    func stop() {
        stopAfterCurrent = true
        statusText = "Stopt na huidige clip…"
    }

    func cancelCurrent() {
        stopAfterCurrent = true
        compressor.cancelCurrent()
        statusText = "Huidige clip annuleren…"
    }

    private enum CompressionOutcome {
        case converted
        case skipped
        case failed(String)
    }

    private func compressOne(
        index: Int,
        keepBackup: Bool
    ) async -> CompressionOutcome {
        jobs[index].state = .encoding
        jobs[index].progress = 0

        do {
            let newBytes = try await compressor.compress(
                source: jobs[index].url,
                preset: preset,
                keepBackup: keepBackup,
                onProgress: { [weak self] value in
                    Task { @MainActor in
                        guard let self else { return }

                        if self.jobs.indices.contains(index) {
                            self.jobs[index].progress = value
                        }
                    }
                }
            )

            jobs[index].outputBytes = newBytes
            jobs[index].progress = 1
            jobs[index].state = .done
            return .converted
        } catch is CancellationError {
            jobs[index].state = .failed("geannuleerd")
            return .failed("geannuleerd")
        } catch let error as CompressionError {
            if case .notSmaller = error {
                jobs[index].state = .skipped(
                    "al HEVC of geen zinvolle ruimtewinst"
                )
                return .skipped
            }

            jobs[index].state = .failed(error.localizedDescription)
            return .failed(error.localizedDescription)
        } catch {
            jobs[index].state = .failed(error.localizedDescription)
            return .failed(error.localizedDescription)
        }
    }

    private func start(
        limit: Int?,
        keepBackups: Bool
    ) {
        guard !isRunning, !jobs.isEmpty else { return }

        if finalCutIsRunning {
            lastError = "Sluit Final Cut Pro eerst. De app vervangt media ín de library."
            return
        }

        isRunning = true
        stopAfterCurrent = false

        for i in jobs.indices {
            jobs[i].state = .queued
            jobs[i].progress = 0
            jobs[i].outputBytes = nil
        }

        Task {
            let indices = Array(
                jobs.indices.prefix(limit ?? jobs.count)
            )

            for (position, index) in indices.enumerated() {
                if stopAfterCurrent { break }

                statusText = "\(position + 1) / \(indices.count) • \(jobs[index].fileName)"

                let outcome = await compressOne(
                    index: index,
                    keepBackup: keepBackups
                )

                if case .failed(let message) = outcome,
                   keepBackups {
                    lastError = """
                    Testclip \(jobs[index].fileName) kon niet worden geconverteerd:
                    \(message)
                    """
                    break
                }
            }

            isRunning = false

            if stopAfterCurrent {
                statusText = "Gestopt • \(savedBytes.storageString) bespaard"
            } else {
                statusText = "Klaar • \(savedBytes.storageString) bespaard"
            }

            await scan()
        }
    }

    func restoreTestBackups() {
        guard let sourceURL, !isRunning else { return }

        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default

            guard let enumerator = fm.enumerator(
                at: sourceURL,
                includingPropertiesForKeys: nil
            ) else {
                return
            }

            while let url = enumerator.nextObject() as? URL {
                guard url.lastPathComponent.contains(".VAC_ORIGINAL") else {
                    continue
                }

                var restoredName = url.lastPathComponent

                if restoredName.hasPrefix(".") {
                    restoredName.removeFirst()
                }

                restoredName = restoredName.replacingOccurrences(
                    of: ".VAC_ORIGINAL",
                    with: ""
                )

                let target = url
                    .deletingLastPathComponent()
                    .appendingPathComponent(restoredName)

                try? fm.removeItem(at: target)
                try? fm.moveItem(at: url, to: target)
            }
        }

        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            await scan()
        }
    }

    func deleteTestBackups() {
        guard let sourceURL, !isRunning else { return }

        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default

            guard let enumerator = fm.enumerator(
                at: sourceURL,
                includingPropertiesForKeys: nil
            ) else {
                return
            }

            while let url = enumerator.nextObject() as? URL {
                if url.lastPathComponent.contains(".VAC_ORIGINAL") {
                    try? fm.removeItem(at: url)
                }
            }
        }

        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            await scan()
        }
    }

    private func deleteBackup(for source: URL) {
        let backup = source
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".\(source.lastPathComponent).VAC_ORIGINAL"
            )

        try? FileManager.default.removeItem(at: backup)
    }

    private func applyScanResult(_ result: ScanResult) {
        jobs = result.jobs
        unsupportedCount = result.unsupportedCount
        existingBackupCount = result.backupCount

        if jobs.isEmpty {
            statusText = "Geen nieuwe MOV/MP4/M4V-video's gevonden."
        } else {
            statusText = "\(jobs.count) video's • \(totalBytes.storageString)"
        }
    }
}
