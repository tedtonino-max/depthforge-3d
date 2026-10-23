import ARKit
import SwiftUI
import UIKit

struct CaptureScreen: View {
    @EnvironmentObject private var scanner: CaptureController

    var body: some View {
        ZStack {
            CameraPreview(view: scanner.sceneView).ignoresSafeArea()
            QualityOverlay(cells: scanner.projectedCells).ignoresSafeArea().allowsHitTesting(false)
            VStack(spacing: 12) {
                header
                Spacer()
                qualityCard
                controls
            }
            .padding(20)
        }
        .sheet(isPresented: $scanner.showShareSheet) {
            if let url = scanner.shareURL { ShareSheet(items: [url]) }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("DEPTHFORGE 3D").font(.headline.weight(.bold))
                Text(scanner.metalEnabled ? "LiDAR · RGB · RoomPlan · Metal gereed" : "LiDAR · RGB · RoomPlan · CPU-fusie")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            StateBadge(state: scanner.state)
        }
        .padding(14).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var qualityCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("Live 3D-kwaliteitskaart", systemImage: "square.3.layers.3d")
                    .font(.headline)
                Spacer()
                Text("consistentie \(Int(scanner.quality.meanConsistency * 100))%")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(scanner.quality.status).font(.subheadline.monospacedDigit())
            HStack(spacing: 12) {
                Metric(value: scanner.quality.coveredCells, label: "sterk", color: .green)
                Metric(value: scanner.quality.weakCells, label: "zwak", color: .orange)
                Metric(value: scanner.quality.usableMeasurements, label: "metingen", color: .cyan)
            }
            Divider()
            Label(scanner.statusLine, systemImage: scanner.quality.advice == .complete ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                .font(.subheadline).foregroundStyle(scanner.quality.advice == .complete ? .green : .white)
        }
        .padding(15).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var controls: some View {
        HStack(spacing: 12) {
            switch scanner.state {
            case .idle, .finished, .failed:
                Button(action: scanner.start) { Label("Nieuwe scan", systemImage: "record.circle") }.buttonStyle(PrimaryButton())
            case .recording, .paused:
                Button(action: scanner.pauseOrResume) { Label(scanner.state == .recording ? "Pauze" : "Hervat", systemImage: scanner.state == .recording ? "pause.fill" : "play.fill") }.buttonStyle(PrimaryButton())
                Button(action: scanner.finish) { Label("Afronden", systemImage: "checkmark") }.buttonStyle(SecondaryButton())
            case .finishing:
                ProgressView().tint(.white).padding()
            }
            Spacer()
            if scanner.state == .finished {
                Button(action: scanner.exportAndShare) { Label("Exporteer PLY", systemImage: "square.and.arrow.up") }.buttonStyle(SecondaryButton())
            }
        }
    }
}

private struct Metric: View {
    let value: Int; let label: String; let color: Color
    var body: some View { VStack(alignment: .leading, spacing: 1) { Text("\(value)").font(.title3.monospacedDigit().weight(.semibold)).foregroundStyle(color); Text(label).font(.caption2).foregroundStyle(.secondary) } }
}

private struct StateBadge: View {
    let state: ScanState
    var body: some View {
        let text: String = switch state { case .idle: "KLAAR"; case .recording: "OPNAME"; case .paused: "PAUZE"; case .finishing: "OPSLAAN"; case .finished: "OPGESLAGEN"; case .failed: "FOUT" }
        Text(text).font(.caption.weight(.bold)).padding(.horizontal, 10).padding(.vertical, 6)
            .background(state == .recording ? Color.red.opacity(0.8) : Color.white.opacity(0.15), in: Capsule())
    }
}

private struct PrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label.font(.headline).padding(.horizontal, 16).padding(.vertical, 12).background(Color.accentColor.opacity(configuration.isPressed ? 0.65 : 0.95), in: Capsule()).scaleEffect(configuration.isPressed ? 0.98 : 1) }
}
private struct SecondaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label.font(.headline).padding(.horizontal, 16).padding(.vertical, 12).background(.thinMaterial, in: Capsule()).scaleEffect(configuration.isPressed ? 0.98 : 1) }
}

private struct CameraPreview: UIViewRepresentable {
    let view: ARSCNView
    func makeUIView(context: Context) -> ARSCNView { view }
    func updateUIView(_ uiView: ARSCNView, context: Context) { }
}

private struct QualityOverlay: View {
    let cells: [ProjectedQualityCell]
    var body: some View {
        Canvas { context, _ in
            for cell in cells {
                let color: Color = cell.quality >= 0.72 ? .green : (cell.quality >= 0.42 ? .orange : .red)
                let radius: CGFloat = cell.quality >= 0.72 ? 4 : 6
                context.fill(Path(ellipseIn: CGRect(x: cell.point.x - radius, y: cell.point.y - radius, width: radius * 2, height: radius * 2)), with: .color(color.opacity(0.58)))
            }
        }
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) { }
}
