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
        Group {
            if scanner.state == .idle {
                ScanWelcome()
            } else {
                captureExperience
            }
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

    private var captureExperience: some View {
        ZStack {
            CameraPreview(view: scanner.sceneView).ignoresSafeArea()
            if isScanning, scanner.captureTarget == .object {
                ObjectTargetGuide().ignoresSafeArea().allowsHitTesting(false)
            }
            VStack {
                topBar
                if isScanning { meshNotice }
                Spacer()
                if isScanning, !scanner.projectedCells.isEmpty { liveMap }
                bottomPanel
            }
            .padding(.bottom, 8)
        }
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
                    Text(isScanning ? "\(scanner.captureTarget.title) · \(stateTitle)" : stateTitle)
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    if isScanning {
                        Text("\(scanner.quality.coveredCells) sterk · \(scanner.quality.weakCells) nog verbeteren")
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
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
                Text("DIT KADER").font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1)
                Text(qualityMessage).font(.system(size: 10, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                Text("rood = opnieuw\noranje = extra hoek\ngroen = klaar").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            LiveQualityMap(cells: scanner.projectedCells).frame(width: 112, height: 112)
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal)
    }

    private var meshNotice: some View {
        Label("LIVE MESH · turquoise driehoeken zijn gemeten LiDAR-oppervlak", systemImage: "triangle.inset.filled")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.black.opacity(0.62), in: Capsule())
            .padding(.top, 8)
    }

    @ViewBuilder private var bottomPanel: some View {
        switch scanner.state {
        case .idle:
            panel {
                Label("Klaar om te scannen", systemImage: "viewfinder").font(.headline)
                Text(scanner.captureTarget == .object
                     ? "Houd één voorwerp in het middenkader. De PLY-fusie volgt alleen dat venster; ruwe frames blijven volledig lokaal bewaard."
                     : "DepthForge legt de ruimte vast met LiDAR, RGB, cameraposes en RoomPlan.")
                    .font(.footnote).foregroundStyle(.secondary)
                HStack {
                    Image(systemName: scanner.captureProfile == .maximumGeometry ? "scope" : "speedometer")
                    Text("\(scanner.captureTarget.detail) · \(scanner.captureProfile.detail)").font(.caption)
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
                    Button("Nieuwe scan", action: scanner.returnToStart).buttonStyle(.bordered)
                }
            }
        case .failed(let message):
            panel {
                Label("Opslaan is onderbroken", systemImage: "exclamationmark.triangle.fill").font(.headline).foregroundStyle(.orange)
                Text(message).font(.footnote)
                Text("De fouttekst hierboven is de werkelijke iPad-fout. Start een nieuwe scan nadat je die hebt opgelost.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Naar start", action: scanner.returnToStart).buttonStyle(.borderedProminent)
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

    private var qualityMessage: String {
        switch scanner.quality.advice {
        case .moveCloser: "Nog geen bruikbare diepte"
        case .changeAngle: "Beweeg 30 cm zijwaarts"
        case .holdSteady: "Houd 1 seconde stil"
        case .revisit: "Neem twee extra hoeken"
        case .complete: "Dit beeld is sterk"
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

private struct ScanWelcome: View {
    @EnvironmentObject private var scanner: CaptureController

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.03, green: 0.06, blue: 0.09), Color(red: 0.05, green: 0.22, blue: 0.25)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Spacer(minLength: 36)
                    Label("DEPTHFORGE 3D", systemImage: "cube.transparent")
                        .font(.headline.weight(.bold)).tracking(1.4).foregroundStyle(.mint)
                    Text("Wat wil je\nscannen?")
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                    Text("Kies dit eerst. Daarna krijg je alleen de feedback die past bij jouw scan.")
                        .font(.body).foregroundStyle(.white.opacity(0.7))

                    CaptureTargetCard(
                        target: .object,
                        title: "Voorwerp",
                        subtitle: "Lamp, meubel of detailobject",
                        detail: "Middenkader + live mesh + gerichte PLY",
                        icon: "lamp.desk.fill",
                        isSelected: scanner.captureTarget == .object
                    ) { scanner.captureTarget = .object }

                    CaptureTargetCard(
                        target: .room,
                        title: "Ruimte",
                        subtitle: "Kamer of volledige omgeving",
                        detail: "Vrij rondlopen + RoomPlan + live mesh",
                        icon: "house.fill",
                        isSelected: scanner.captureTarget == .room
                    ) { scanner.captureTarget = .room }

                    Button {
                        scanner.start()
                    } label: {
                        HStack {
                            Text(scanner.captureTarget == .object ? "Start voorwerpscan" : "Start ruimtescan")
                            Spacer()
                            Image(systemName: "arrow.right")
                        }
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.black)
                        .padding()
                        .background(.mint, in: RoundedRectangle(cornerRadius: 18))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)

                    Text("LiDAR is vereist. Ruwe diepte, RGB en poses blijven lokaal op de iPad.")
                        .font(.caption).foregroundStyle(.white.opacity(0.52))
                    Spacer(minLength: 24)
                }
                .padding(24)
                .frame(maxWidth: 620, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }
}

private struct CaptureTargetCard: View {
    let target: CaptureTarget
    let title: String
    let subtitle: String
    let detail: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title2).frame(width: 40, height: 40)
                    .foregroundStyle(isSelected ? .black : .mint)
                    .background(isSelected ? .mint : .white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.subheadline).foregroundStyle(.white.opacity(0.75))
                    Text(detail).font(.caption).foregroundStyle(.white.opacity(0.48))
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundStyle(isSelected ? .mint : .white.opacity(0.45))
            }
            .foregroundStyle(.white)
            .padding(16)
            .background(isSelected ? .white.opacity(0.16) : .black.opacity(0.18), in: RoundedRectangle(cornerRadius: 20))
            .overlay {
                RoundedRectangle(cornerRadius: 20)
                    .stroke(isSelected ? Color.mint.opacity(0.9) : .white.opacity(0.11), lineWidth: isSelected ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Selecteer \(target.title)")
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
            for cell in cells {
                let x = 8 + cell.normalizedPoint.x * (size.width - 16)
                let y = 8 + cell.normalizedPoint.y * (size.height - 16)
                let color: Color = cell.quality >= 0.55 ? .green : cell.quality >= 0.35 ? .orange : .red
                context.fill(Path(roundedRect: CGRect(x: x - 4, y: y - 4, width: 8, height: 8), cornerRadius: 2), with: .color(color))
            }
        }
    }
}

private struct ObjectTargetGuide: View {
    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width * 0.64
            let height = min(proxy.size.height * 0.46, width * 1.15)
            VStack(spacing: 8) {
                Text("PLAATS HET VOORWERP IN DIT KADER")
                    .font(.caption2.weight(.bold)).tracking(0.7)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.black.opacity(0.55), in: Capsule())
                RoundedRectangle(cornerRadius: 22)
                    .stroke(.white.opacity(0.88), style: StrokeStyle(lineWidth: 2, dash: [10, 8]))
                    .frame(width: width, height: height)
                    .overlay(alignment: .bottom) {
                        Text("Beweeg daarna rustig links en rechts")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.black.opacity(0.55), in: Capsule())
                            .offset(y: 22)
                    }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
