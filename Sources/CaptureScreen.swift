import ARKit
import SwiftUI
import UIKit

struct CaptureScreen: View {
    @EnvironmentObject private var scanner: CaptureController
    @Environment(\.scenePhase) private var scenePhase
    @State private var showGuide = false
    @State private var showPhotos = false
    @State private var exportFolder = false
    private var active: Bool { scanner.state == .recording || scanner.state == .paused || scanner.state == .review }

    var body: some View {
        Group {
            if scanner.state == .idle { welcome } else { capture }
        }
        .sheet(isPresented: $showGuide) { guide }
        .sheet(isPresented: $showPhotos) { gallery }
        .sheet(isPresented: $exportFolder) {
            if let root = scanner.scanRoot { ScanFolderExport(root: root) }
        }
        .sheet(isPresented: $scanner.showShareSheet) {
            if let url = scanner.shareURL { ShareSheet(items: [url]) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active, scanner.state == .recording { scanner.pauseOrResume() }
        }
        .statusBarHidden()
    }

    private var capture: some View {
        ZStack {
            CameraPreview(view: scanner.sceneView).ignoresSafeArea()
            if scanner.state == .framing { FloorVolumePicker().ignoresSafeArea() }
            if scanner.choosingDetail {
                Color.clear.contentShape(Rectangle()).ignoresSafeArea()
                    .gesture(DragGesture(minimumDistance: 0).onChanged { scanner.selectDetail(at: $0.location) })
            }
            VStack(spacing: 12) {
                HStack(alignment: .top) {
                    Menu {
                        Button("Scanhandleiding") { showGuide = true }
                        Toggle("Toon basismesh en detail", isOn: $scanner.showSurface)
                        Picker("Opname", selection: $scanner.captureProfile) {
                            ForEach(CaptureProfile.allCases) { Text($0.title).tag($0) }
                        }
                    } label: {
                        Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                    }.accessibilityLabel("Scanopties")
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("DEPTHFORGE 3D").font(.caption.weight(.bold)).tracking(1)
                        Text(scanner.captureTarget.title).font(.caption).foregroundStyle(.secondary)
                        if active {
                            Text("\(scanner.savedFrames) frames bewaard").font(.caption2.monospacedDigit())
                        }
                    }.padding(12).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
                if active {
                    Text("1  Basis · \(scanner.baseFaces) vlakken    →    2  Detail · \(scanner.meshFaces) vlakken")
                        .font(.caption2).padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.black.opacity(0.55), in: Capsule())
                }
                Spacer()
                if !scanner.photos.isEmpty, active || scanner.state == .finished {
                    Button { showPhotos = true } label: {
                        HStack(spacing: 8) {
                            ForEach(Array(scanner.photos.suffix(3))) { photo in
                                Image(uiImage: photo.thumbnail).resizable().scaledToFill()
                                    .frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            Text("\(scanner.photos.count) fotomomenten").font(.caption.weight(.semibold))
                        }.padding(8).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain)
                }
                bottom
            }.padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 16)
        }
    }

    @ViewBuilder private var bottom: some View {
        switch scanner.state {
        case .idle: EmptyView()
        case .framing:
            panel {
                Text("Kies je scanvolume").font(.headline)
                Text(scanner.statusLine).font(.subheadline)
                if let volume = scanner.objectScanVolume {
                    HStack {
                        Text("Hoogte \(volume.height, specifier: "%.1f") m").font(.caption).frame(width: 100, alignment: .leading)
                        Slider(value: Binding(get: { Double(scanner.objectScanVolume?.height ?? 1.5) },
                                              set: { scanner.setVolumeHeight(Float($0)) }), in: 0.2...3, step: 0.1)
                            .accessibilityLabel("Hoogte van het scanvolume")
                    }
                }
                HStack {
                    Button("Opnieuw", action: scanner.clearObjectVolume).buttonStyle(.bordered)
                    Spacer()
                    Button("Begin met meten", action: scanner.confirmObjectVolume)
                        .buttonStyle(.borderedProminent).disabled(scanner.objectScanVolume == nil)
                }
                Button("Annuleer", action: scanner.returnToStart).font(.caption)
            }
        case .preparing, .finishing:
            panel { HStack { ProgressView(); Text(scanner.statusLine) } }
        case .recording:
            panel {
                Text(scanner.statusLine).font(.headline).accessibilityAddTraits(.updatesFrequently)
                if scanner.choosingDetail {
                    Text(scanner.captureTarget == .room && scanner.selectedAreaOnly ? "Schilder welk deel van de wand, vloer of kamer in deze scan hoort." : "Schilder over het detail dat je extra wilt meten.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Wissen", action: scanner.clearPaint).buttonStyle(.bordered)
                        Slider(value: $scanner.brushRadius, in: 0.04...0.20).frame(maxWidth: 130).accessibilityLabel("Kwastgrootte")
                        Spacer()
                        Button("Verfijn selectie", action: scanner.confirmDetail)
                            .buttonStyle(.borderedProminent).disabled(scanner.pendingZone == nil)
                    }
                } else {
                    if scanner.detailZone != nil {
                        Text("Oranje = selectie · mint = gemeten detail · \(scanner.quality.stable) bevestigde metingen in beeld").font(.caption)
                    }
                    if let notice = scanner.resourceNotice {
                        Text(notice).font(.caption).foregroundStyle(.orange)
                    }
                    HStack {
                        Button(action: scanner.chooseDetail) { Label(scanner.selectedAreaOnly && scanner.captureTarget == .room ? "Gebied aanpassen" : "Detail schilderen", systemImage: "paintbrush.pointed") }
                            .buttonStyle(.bordered)
                        Button(action: scanner.pauseOrResume) { Image(systemName: "pause.fill") }
                            .buttonStyle(.bordered).accessibilityLabel("Pauzeer")
                        Spacer(minLength: 4)
                        Button("Controleer", action: scanner.review).buttonStyle(.borderedProminent)
                    }
                }
            }
        case .paused:
            panel {
                Text("Scan gepauzeerd").font(.headline)
                if let notice = scanner.resourceNotice { Text(notice).font(.caption) }
                HStack {
                    Button("Hervat", action: scanner.pauseOrResume).buttonStyle(.borderedProminent)
                    Button("Controleer", action: scanner.review).buttonStyle(.bordered)
                }
            }
        case .review:
            panel {
                Text("Controleer je scan").font(.headline)
                Text("Blauw is de basismesh. Mint is het extra gemeten detail. Oranje markeert je selectie. Open plekken zijn nog niet gereconstrueerd; controleer vooral pootjes en onderkanten.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text(scanner.quality.advice.rawValue).font(.caption.weight(.semibold))
                Toggle("Toon basismesh en detail", isOn: $scanner.showSurface)
                HStack {
                    Button("Verder scannen", action: scanner.pauseOrResume).buttonStyle(.bordered)
                    Spacer()
                    Button("Sla scan op", action: scanner.finish).buttonStyle(.borderedProminent)
                }
            }
        case .finished:
            panel {
                Label("Scan opgeslagen", systemImage: "checkmark.circle.fill").font(.headline).foregroundStyle(.mint)
                Text("\(scanner.savedFrames) ruwe frames en \(scanner.photos.count) geselecteerde fotomomenten zijn lokaal bewaard. De scanmap bevat de basismesh, detailmesh en gekleurde meetpunten als aparte PLY-bestanden.")
                    .font(.subheadline).foregroundStyle(.secondary)
                if let notice = scanner.roomNotice { Text(notice).font(.caption).foregroundStyle(.orange) }
                HStack {
                    Button("Deel basismesh", action: scanner.exportAndShare).buttonStyle(.borderedProminent)
                    Button("Bewaar scanmap") { exportFolder = true }.buttonStyle(.bordered)
                    Button("Nieuwe scan", action: scanner.returnToStart).buttonStyle(.bordered)
                }
            }
        case .failed(let message):
            panel {
                Label("Opname onderbroken", systemImage: "exclamationmark.triangle").font(.headline)
                Text(message).font(.subheadline)
                Text("Reeds geschreven frames blijven in de lokale scanmap.").font(.caption).foregroundStyle(.secondary)
                Button("Naar start", action: scanner.returnToStart).buttonStyle(.borderedProminent)
            }
        }
    }

    private var welcome: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.03, green: 0.06, blue: 0.09), Color(red: 0.05, green: 0.22, blue: 0.25)],
                           startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Label("DEPTHFORGE 3D", systemImage: "cube.transparent").font(.headline).tracking(1.4).foregroundStyle(.mint)
                    Text("Wat wil je\nscannen?").font(.system(size: 42, weight: .bold, design: .rounded))
                    targetCard(.object, icon: "lamp.desk.fill", detail: "Teken een grondcirkel rond je voorwerp. Verfijn het oppervlak vanuit meerdere hoeken.")
                    targetCard(.room, icon: "house.fill", detail: "Scan de hele kamer of schilder zelf welk gebied je wilt vastleggen.")
                    if scanner.captureTarget == .room {
                        Picker("Scangebied", selection: $scanner.selectedAreaOnly) {
                            Text("Hele kamer").tag(false)
                            Text("Gebied schilderen").tag(true)
                        }.pickerStyle(.segmented)
                    }
                    Button(action: scanner.start) {
                        HStack { Text("Start \(scanner.captureTarget == .object ? "voorwerpscan" : "ruimtescan")"); Spacer(); Image(systemName: "arrow.right") }
                            .font(.headline).foregroundStyle(.black).padding()
                            .background(.mint, in: RoundedRectangle(cornerRadius: 16))
                    }
                    Text("LiDAR vereist · Alles blijft lokaal op je iPad\nHerhaalde metingen verminderen ruis. Detail dat de sensor niet ziet, wordt niet ingevuld.")
                        .font(.caption).foregroundStyle(.white.opacity(0.6))
                }.padding(28).frame(maxWidth: 620).frame(maxWidth: .infinity)
            }
        }
    }
    private func targetCard(_ target: CaptureTarget, icon: String, detail: String) -> some View {
        Button { scanner.captureTarget = target } label: {
            HStack(spacing: 16) {
                Image(systemName: icon).font(.title2).frame(width: 36).foregroundStyle(.mint)
                VStack(alignment: .leading, spacing: 6) {
                    Text(target.title).font(.title3.weight(.semibold))
                    Text(detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: scanner.captureTarget == target ? "checkmark.circle.fill" : "circle").foregroundStyle(.mint)
            }.padding(20).background(.white.opacity(scanner.captureTarget == target ? 0.14 : 0.05), in: RoundedRectangle(cornerRadius: 20))
        }.buttonStyle(.plain)
    }
    private func panel<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .padding(18).frame(maxWidth: 540, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
    private var gallery: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 18) {
                    ForEach(scanner.photos) { photo in
                        VStack {
                            Image(uiImage: photo.thumbnail).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 12))
                            Text("Kijkhoek \(photo.angleDegrees)°").font(.caption)
                        }
                    }
                }.padding()
                Text("Geselecteerd bij een rustige pose, bruikbare belichting en een nieuwe kijkhoek. De originele foto's zijn gekoppeld aan diepte en camerapose; textuur-export volgt later.")
                    .font(.footnote).foregroundStyle(.secondary).padding()
            }.navigationTitle("Fotomomenten")
                .toolbar { Button("Gereed") { showPhotos = false } }
        }
    }
    private var guide: some View {
        NavigationStack {
            List {
                Section("Voorwerp") {
                    Text("Teken op de vloer een cirkel die het hele voorwerp omvat. Stel ook de hoogte in.")
                    Text("Blijf rustig kijken tot het oppervlak verschijnt. Beweeg daarna zijwaarts voor een tweede hoek, ook laag bij pootjes en randen.")
                }
                Section("Detailzone") {
                    Text("Schilder met je vinger op de zichtbare basis. Oranje blijft je selectie tonen. Kies Verfijn selectie en bekijk het detail vanuit meerdere hoeken.")
                }
                Section("Betrouwbare geometrie") {
                    Text("Blauw toont de blijvende basismesh, mint de extra bevestigde detailvlakken. De basis blijft zichtbaar tijdens het verfijnen.")
                    Text("De feedback geldt voor de zichtbare gekozen zone; zij bewijst niet dat de achterkant of onderkant volledig is gescand.")
                }
                Section("Foto's en export") {
                    Text("Houd de iPad kort stil vanuit een nieuwe hoek voor een automatisch fotomoment. PLY, diepte, RGB, confidence en poses blijven lokaal bewaard.")
                }
            }.navigationTitle("Scanhandleiding").toolbar { Button("Gereed") { showGuide = false } }
        }
    }
}

private struct FloorVolumePicker: View {
    @EnvironmentObject private var scanner: CaptureController
    @State private var drawing = false
    var body: some View {
        Color.clear.contentShape(Rectangle()).gesture(
            DragGesture(minimumDistance: 0).onChanged { value in
                if !drawing { drawing = true; scanner.beginObjectVolume(at: value.startLocation) }
                scanner.resizeObjectVolume(to: value.location)
            }.onEnded { _ in drawing = false }
        )
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

private struct ScanFolderExport: UIViewControllerRepresentable {
    let root: URL
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting: [root], asCopy: true)
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) { }
}
