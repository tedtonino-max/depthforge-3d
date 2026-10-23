import ARKit
import SwiftUI
import UIKit

/// Capture UI follows the supplied 3D Model Anything layout: camera-first,
/// compact material controls, a persistent live map and one clear next action.
struct CaptureScreen: View {
    @EnvironmentObject private var scanner: CaptureController
    @Environment(\.scenePhase) private var scenePhase
    @State private var showGuide = false

    private var isScanning: Bool { scanner.state == .recording || scanner.state == .paused }

    var body: some View {
        ZStack {
            CameraPreview(view: scanner.sceneView).ignoresSafeArea()
            QualityOverlay(cells: scanner.projectedCells).ignoresSafeArea().allowsHitTesting(false)
            VStack {
                topBar
                Spacer()
                if isScanning, !scanner.projectedCells.isEmpty { liveMap }
                bottomPanel
            }
            .padding(.bottom, 8)
        }
        .sheet(isPresented: $showGuide) { ScanGuide() }
        .sheet(isPresented: $scanner.showShareSheet) {
            if let url = scanner.shareURL { ShareSheet(items: [url]) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active, scanner.state == .recording { scanner.pauseOrResume() }
        }
        .statusBarHidden()
    }

    private var topBar: some View {
        HStack(alignment: .top) {
            Menu {
                Button("Hoe scan ik goed?") { showGuide = true }
                Divider()
                Section("Opnameprofiel") {
                    ForEach(CaptureProfile.allCases) { profile in
                        Button {
                            scanner.captureProfile = profile
                        } label: {
                            Label(profile.title, systemImage: scanner.captureProfile == profile ? "checkmark" : "")
                        }
                    }
                }
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.headline).frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Scanopties")

            Spacer()

            HStack(spacing: 10) {
                if isScanning { QualityRing(percent: scanner.quality.meanConsistency).frame(width: 44, height: 44) }
                VStack(alignment: .trailing, spacing: 2) {
                    Text("DEPTHFORGE 3D").font(.caption.weight(.bold)).tracking(1)
                    Text(stateTitle).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    if isScanning {
                        Text("\(scanner.quality.usableMeasurements) metingen · \(Int(scanner.quality.meanViewDiversity * 100))% hoeken")
                            .font(.caption2.monospacedDigit())
                    } else {
                        Text(scanner.captureProfile.title).font(.caption2)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(.horizontal).padding(.top, 8)
    }

    private var liveMap: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("LIVE 3D-KAART").font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1)
                Text("groen is sterk\noranje opnieuw").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            LiveQualityMap(cells: scanner.projectedCells).frame(width: 112, height: 112)
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal)
    }

    @ViewBuilder private var bottomPanel: some View {
        switch scanner.state {
        case .idle:
            panel {
                Label("Klaar om te scannen", systemImage: "viewfinder").font(.headline)
                Text("DepthForge legt LiDAR-diepte, confidence, RGB, cameraposes en calibratie lokaal vast.")
                    .font(.footnote).foregroundStyle(.secondary)
                HStack {
                    Image(systemName: scanner.captureProfile == .maximumGeometry ? "scope" : "speedometer")
                    Text(scanner.captureProfile.detail).font(.caption)
                    Spacer()
                    Button("Start scan", action: scanner.start).buttonStyle(.borderedProminent).controlSize(.large)
                }
            }
        case .recording:
            VStack(spacing: 10) {
                tip(scanner.statusLine)
                HStack(spacing: 14) {
                    ScanLegend()
                    Button(action: scanner.pauseOrResume) { Image(systemName: "pause.fill") }
                        .buttonStyle(.bordered).controlSize(.large).accessibilityLabel("Pauzeer scan")
                    ScanPulse(quality: scanner.quality)
                    Button(scanner.quality.advice == .complete ? "Opslaan ✓" : "Scan opslaan", action: scanner.finish)
                        .buttonStyle(.borderedProminent)
                        .tint(scanner.quality.advice == .complete ? .green : .accentColor)
                        .controlSize(.large)
                }
            }
            .padding(.horizontal)
        case .paused:
            panel {
                Label("Scan gepauzeerd", systemImage: "pause.circle.fill").font(.headline)
                Text("Er worden geen nieuwe frames opgeslagen. Hervat wanneer je klaar bent voor de volgende hoek.")
                    .font(.footnote).foregroundStyle(.secondary)
                HStack {
                    Button("Hervat", action: scanner.pauseOrResume).buttonStyle(.borderedProminent)
                    Button("Nu opslaan", action: scanner.finish).buttonStyle(.bordered)
                }
            }
        case .finishing:
            panel { HStack(spacing: 12) { ProgressView(); Text("Scan wordt lokaal opgeslagen…") } }
        case .finished:
            panel {
                Label("Scan opgeslagen", systemImage: "checkmark.seal.fill").font(.headline).foregroundStyle(.green)
                Text("Ruwe diepteframes, poses en de PLY-export zijn lokaal bewaard.").font(.footnote).foregroundStyle(.secondary)
                HStack {
                    Button("Exporteer PLY", action: scanner.exportAndShare).buttonStyle(.borderedProminent)
                    Button("Nieuwe scan", action: scanner.start).buttonStyle(.bordered)
                }
            }
        case .failed(let message):
            panel {
                Label("Opslaan is onderbroken", systemImage: "exclamationmark.triangle.fill").font(.headline).foregroundStyle(.orange)
                Text(message).font(.footnote)
                Text("De fouttekst hierboven is de werkelijke iPad-fout. Start een nieuwe scan nadat je die hebt opgelost.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Nieuwe scan", action: scanner.start).buttonStyle(.borderedProminent)
            }
        }
    }

    private var stateTitle: String {
        switch scanner.state {
        case .idle: "Klaar voor LiDAR"
        case .recording: "Opnemen"
        case .paused: "Gepauzeerd"
        case .finishing: "Opslaan"
        case .finished: "Opgeslagen"
        case .failed: "Actie nodig"
        }
    }

    private func tip(_ text: String) -> some View {
        Text(text).font(.caption).multilineTextAlignment(.center)
            .padding(8).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .padding().frame(maxWidth: 500, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            .padding(.horizontal)
    }
}

private struct QualityRing: View {
    let percent: Float
    var body: some View {
        let value = min(1, max(0, percent))
        ZStack {
            Circle().stroke(.white.opacity(0.25), lineWidth: 5)
            Circle().trim(from: 0, to: CGFloat(value))
                .stroke(value > 0.7 ? .green : value > 0.35 ? .orange : .red, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int(value * 100))%").font(.caption2.monospacedDigit().weight(.bold))
        }
    }
}

private struct ScanPulse: View {
    let quality: QualitySummary
    var body: some View {
        ZStack {
            Circle().fill(.white.opacity(0.92)).frame(width: 60, height: 60)
            Circle().stroke(quality.advice == .complete ? .green : .orange, lineWidth: 3).frame(width: 52, height: 52)
            Image(systemName: "cube.transparent").font(.title3).foregroundStyle(.black)
        }
        .accessibilityLabel("Live geometrie wordt opgenomen")
    }
}

private struct ScanLegend: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            LegendRow(color: .red, text: "onvoldoende")
            LegendRow(color: .orange, text: "opnieuw")
            LegendRow(color: .green, text: "sterk")
        }
        .padding(6).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct LegendRow: View {
    let color: Color; let text: String
    var body: some View { HStack(spacing: 4) { Circle().fill(color).frame(width: 7, height: 7); Text(text).font(.system(size: 9)) } }
}

private struct LiveQualityMap: View {
    let cells: [ProjectedQualityCell]
    var body: some View {
        Canvas { context, size in
            context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 8), with: .color(.black.opacity(0.18)))
            guard let first = cells.first else { return }
            let minX = cells.map(\.point.x).min() ?? first.point.x
            let maxX = cells.map(\.point.x).max() ?? first.point.x + 1
            let minY = cells.map(\.point.y).min() ?? first.point.y
            let maxY = cells.map(\.point.y).max() ?? first.point.y + 1
            let spanX = max(1, maxX - minX), spanY = max(1, maxY - minY)
            for cell in cells {
                let x = 8 + (cell.point.x - minX) / spanX * (size.width - 16)
                let y = 8 + (cell.point.y - minY) / spanY * (size.height - 16)
                let color: Color = cell.quality >= 0.72 ? .green : cell.quality >= 0.42 ? .orange : .red
                context.fill(Path(ellipseIn: CGRect(x: x - 3, y: y - 3, width: 6, height: 6)), with: .color(color))
            }
        }
    }
}

private struct QualityOverlay: View {
    let cells: [ProjectedQualityCell]
    var body: some View {
        Canvas { context, _ in
            for cell in cells {
                let color: Color = cell.quality >= 0.72 ? .green : cell.quality >= 0.42 ? .orange : .red
                let radius: CGFloat = cell.quality >= 0.72 ? 4 : 6
                context.fill(Path(ellipseIn: CGRect(x: cell.point.x - radius, y: cell.point.y - radius, width: radius * 2, height: radius * 2)), with: .color(color.opacity(0.62)))
            }
        }
    }
}

private struct ScanGuide: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("Voor het beste model") {
                    Label("Begin 20–40 cm van een oppervlak.", systemImage: "ruler")
                    Label("Beweeg rustig zijwaarts voor meerdere kijkhoeken.", systemImage: "arrow.left.and.right")
                    Label("Volg rood en oranje op de kwaliteitskaart.", systemImage: "square.3.layers.3d")
                }
                Section("Wat wordt bewaard") {
                    Text("Ruwe LiDAR-diepte, confidence, RGB, cameraposes, calibratie, RoomPlan en PLY blijven lokaal op de iPad.")
                }
            }
            .navigationTitle("Scanhandleiding")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Gereed") { dismiss() } } }
        }
    }
}

private struct CameraPreview: UIViewRepresentable {
    let view: ARSCNView
    func makeUIView(context: Context) -> ARSCNView { view }
    func updateUIView(_ uiView: ARSCNView, context: Context) { }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) { }
}
