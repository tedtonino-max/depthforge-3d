import SwiftUI

@main
struct DepthForge3DApp: App {
    @StateObject private var scanner = CaptureController()

    var body: some Scene {
        WindowGroup {
            CaptureScreen()
                .environmentObject(scanner)
                .preferredColorScheme(.dark)
        }
    }
}
