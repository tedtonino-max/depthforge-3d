import ARKit
import SwiftUI
import UIKit

struct CaptureScreen: View {
    @EnvironmentObject private var scanner: CaptureController

    var body: some View {
        ZStack {
            CameraPreview(view: scanner.sceneView).ignoresSafeArea()
            QualityOverlay(cells: scanner.projectedCells).ignoresSafeArea().allowsHitTesting(false)
            VStack(spacing: 0) {
                header.padding(.horizontal, 20).padding(.top, 16)
                Spacer()
                if scanner.state == .recording || scanner.state == .paused { liveMap.padding(.horizontal, 20) }
                bottomPanel
            }
        }
        .background(Fieldwork.paper)
        .sheet(isPresented: $scanner.showShareSheet) {
            if let url = scanner.shareURL { ShareSheet(items: [url]) }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                FieldworkEyebrow(text: "DepthForge · field scan")
                Text("3D capture").font(.title2.weight(.bold)).tracking(-0.5)
                Text(scanner.metalEnabled ? "LiDAR · RGB · RoomPlan · Metal" : "LiDAR · RGB · RoomPlan")
                    .font(.caption).foregroundStyle(Fieldwork.secondary)
            }
            Spacer()
            StateBadge(state: scanner.state)
        }
        .foregroundStyle(Fieldwork.ink)
        .padding(16)
        .background(Fieldwork.paper.opacity(0.96), in: RoundedRectangle(cornerRadius: 14))
        .overlay(FieldworkCorners().stroke(Fieldwork.orange, lineWidth: 1.5))
    }

    private var liveMap: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                FieldworkEyebrow(text: "live geometry")
                Text("Quality map").font(.headline)
                Text(scanner.quality.status).font(.caption.monospacedDigit()).foregroundStyle(Fieldwork.secondary)
            }
            Spacer()
            QualityRing(quality: scanner.quality)
        }
        .foregroundStyle(Fieldwork.ink)
        .padding(14)
        .background(Fieldwork.paper.opacity(0.96), in: RoundedRectangle(cornerRadius: 14))
        .overlay(FieldworkCorners().stroke(Fieldwork.orange, lineWidth: 1.25))
    }

    private var bottomPanel: some View {
        VStack(alignment: .leading, spacing: 13) {
            FieldworkRule()
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    FieldworkEyebrow(text: scanner.state == .recording ? "next pass" : "scan status")
                    Text(scanner.statusLine).font(.subheadline.weight(.medium))
                }
                Spacer(minLength: 12)
                if scanner.state == .recording || scanner.state == .paused {
                    Text("\(Int(scanner.quality.meanConsistency * 100))%")
                        .font(.title3.monospacedDigit().weight(.bold))
                }
            }
            if scanner.state == .recording || scanner.state == .paused {
                metrics
                qualitySignals
            }
            controls
        }
        .foregroundStyle(Fieldwork.ink)
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 20)
        .background(Fieldwork.paper)
    }

    private var metrics: some View {
        HStack(spacing: 0) {
            Metric(value: scanner.quality.coveredCells, label: "sterk", color: .green)
            divider
            Metric(value: scanner.quality.weakCells, label: "opnieuw", color: Fieldwork.orange)
            divider
            Metric(value: scanner.quality.usableMeasurements, label: "metingen", color: Fieldwork.ink)
        }
    }

    private var divider: some View { FieldworkRule().frame(width: 1, height: 38).padding(.horizontal, 16) }

    private var qualitySignals: some View {
        HStack(spacing: 14) {
            Label("Consistentie \(Int(scanner.quality.meanConsistency * 100))%", systemImage: "checkmark.circle")
            Label("Kijkhoeken \(Int(scanner.quality.meanViewDiversity * 100))%", systemImage: "arrow.triangle.branch")
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(Fieldwork.secondary)
    }

    @ViewBuilder private var controls: some View {
        switch scanner.state {
        case .idle, .finished, .failed:
            Button(action: scanner.start) { Label("Nieuwe scan", systemImage: "viewfinder") }
                .buttonStyle(FieldworkButtonStyle())
            if scanner.state == .finished {
                Button(action: scanner.exportAndShare) { Label("Exporteer PLY", systemImage: "square.and.arrow.up") }
                    .buttonStyle(FieldworkButtonStyle(filled: false))
            }
        case .recording:
            HStack(spacing: 10) {
                Button(action: scanner.pauseOrResume) { Label("Pauze", systemImage: "pause.fill") }
                    .buttonStyle(FieldworkButtonStyle(filled: false))
                Button(action: scanner.finish) { Label("Scan opslaan", systemImage: "checkmark") }
                    .buttonStyle(FieldworkButtonStyle())
            }
        case .paused:
            HStack(spacing: 10) {
                Button(action: scanner.pauseOrResume) { Label("Hervat", systemImage: "play.fill") }
                    .buttonStyle(FieldworkButtonStyle())
                Button(action: scanner.finish) { Label("Nu opslaan", systemImage: "checkmark") }
                    .buttonStyle(FieldworkButtonStyle(filled: false))
            }
        case .finishing:
            HStack(spacing: 12) {
                ProgressView().tint(Fieldwork.orange)
                Text("Scan wordt lokaal opgeslagen…").font(.subheadline.weight(.medium))
            }.frame(maxWidth: .infinity, minHeight: 52)
        }
    }
}

private struct Metric: View {
    let value: Int; let label: String; let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)").font(.title3.monospacedDigit().weight(.bold)).foregroundStyle(color)
            Text(label.uppercased()).font(.system(.caption2, design: .monospaced)).foregroundStyle(Fieldwork.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct QualityRing: View {
    let quality: QualitySummary
    var body: some View {
        let percent = min(1, max(0, quality.meanConsistency))
        ZStack {
            Circle().stroke(Fieldwork.rule, lineWidth: 5)
            Circle().trim(from: 0, to: CGFloat(percent))
                .stroke(quality.advice == .complete ? .green : Fieldwork.orange, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int(percent * 100))% ").font(.caption2.monospacedDigit().weight(.bold))
        }.frame(width: 48, height: 48)
    }
}

private struct StateBadge: View {
    let state: ScanState
    var body: some View {
        let value: (String, Color) = switch state {
        case .idle: ("KLAAR", Fieldwork.secondary)
        case .recording: ("OPNAME", Fieldwork.orange)
        case .paused: ("PAUZE", Fieldwork.orange)
        case .finishing: ("OPSLAAN", Fieldwork.secondary)
        case .finished: ("OPGESLAGEN", .green)
        case .failed: ("FOUT", .red)
        }
        Text(value.0).font(.system(.caption, design: .monospaced).weight(.bold)).tracking(1)
            .foregroundStyle(value.1).padding(.horizontal, 9).padding(.vertical, 7)
            .overlay(Capsule().stroke(value.1.opacity(0.7), lineWidth: 1))
    }
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
                let color: Color = cell.quality >= 0.72 ? .green : (cell.quality >= 0.42 ? Fieldwork.orange : .red)
                let radius: CGFloat = cell.quality >= 0.72 ? 4 : 6
                context.fill(Path(ellipseIn: CGRect(x: cell.point.x - radius, y: cell.point.y - radius, width: radius * 2, height: radius * 2)), with: .color(color.opacity(0.66)))
            }
        }
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) { }
}
