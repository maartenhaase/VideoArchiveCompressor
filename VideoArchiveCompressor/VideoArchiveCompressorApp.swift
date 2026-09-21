import SwiftUI

@main
struct VideoArchiveCompressorApp: App {
    @StateObject private var model = ArchiveViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 920, minHeight: 650)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1040, height: 760)
    }
}
