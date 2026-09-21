import Foundation
import AppKit

@MainActor
final class ArchiveViewModel: ObservableObject {
    @Published var sourceURL: URL?
    @Published var jobs: [MediaJob] = []
    @Published var preset: ArchivePreset = .tinyHD
    @Published var isScanning = false
    @Published var isRunning = false
    @Published var stopAfterCurrent = false
    @Published var unsupportedCount = 0
    @Published var existingBackupCount = 0
    @Published var statusText = "Kies een FCP Library, map of harde schijf."
    @Published var lastError: String?

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

        jobs = result.jobs
        unsupportedCount = result.unsupportedCount
        existingBackupCount = result.backupCount
        isScanning = false

        if jobs.isEmpty {
            statusText = "Geen MOV/MP4/M4V in Original Media gevonden."
        } else {
            statusText = "\(jobs.count) video's • \(totalBytes.storageString)"
        }
    }

    func startTest() {
        start(limit: 3, keepBackups: true)
    }

    func startFullBatch() {
        // Safety-first: keep every original until the user has opened the
        // library in Final Cut and explicitly deletes the backups.
        start(limit: nil, keepBackups: true)
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

    private func start(limit: Int?, keepBackups: Bool) {
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
            let indices = Array(jobs.indices.prefix(limit ?? jobs.count))

            for (position, index) in indices.enumerated() {
                if stopAfterCurrent { break }

                jobs[index].state = .encoding
                jobs[index].progress = 0
                statusText = "\(position + 1) / \(indices.count) • \(jobs[index].fileName)"

                do {
                    let newBytes = try await compressor.compress(
                        source: jobs[index].url,
                        preset: preset,
                        keepBackup: keepBackups,
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
                } catch is CancellationError {
                    jobs[index].state = .failed("geannuleerd")
                    break
                } catch let error as CompressionError {
                    switch error {
                    case .notSmaller:
                        jobs[index].state = .skipped(
                            error.localizedDescription
                        )
                    default:
                        jobs[index].state = .failed(
                            error.localizedDescription
                        )

                        if keepBackups {
                            lastError = """
                            Testclip \(jobs[index].fileName) kon niet worden geconverteerd:
                            \(error.localizedDescription)
                            """
                            break
                        }
                    }
                } catch {
                    jobs[index].state = .failed(error.localizedDescription)

                    if keepBackups {
                        lastError = "Testclip mislukt:\n\(error.localizedDescription)"
                        break
                    }
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
}
