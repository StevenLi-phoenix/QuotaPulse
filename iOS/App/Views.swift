import AVFoundation
import QuotaCore
import QuotaUI
import SwiftUI

// MARK: - Home

struct HomeView: View {
    @Environment(ClientModel.self) private var model
    @State private var showSettings = false
    @State private var showPair = false

    var body: some View {
        let now = model.ticker.now
        ScrollView {
            LazyVStack(spacing: 14) {
                if let err = model.lastError {
                    banner(err, symbol: "wifi.exclamationmark")
                } else if model.snapshot.isStale(now: now) {
                    // Unlike a dead hub, a silent Mac produces no error: without this the numbers just quietly age.
                    banner(L("Your Mac hasn't published anything recently. Check that QuotaPulse is running there and has internet access."), symbol: "clock.badge.exclamationmark")
                }
                if model.snapshot.providers.isEmpty { emptyState }
                ForEach(model.snapshot.providers) { p in
                    NavigationLink(value: p.id) {
                        ProviderCard(snapshot: p, sparkline: model.sparklines[p.id] ?? [], style: .full, now: now)
                    }
                    .buttonStyle(.plain)
                }
                if model.snapshot.generatedAt != .distantPast {
                    Text(Present.updatedText(model.snapshot.generatedAt, now: now) + (model.source.map { " · \($0.rawValue)" } ?? ""))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(16)
            .animation(QPDesign.spring, value: model.snapshot.providers.map(\.id))
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .refreshable { await model.refresh(reason: "pull") }
        .navigationTitle("QuotaPulse")
        .navigationDestination(for: ProviderID.self) { ProviderDetailView(provider: $0) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
            }
            ToolbarItem(placement: .topBarLeading) {
                if model.isRefreshing { ProgressView() }
            }
        }
        .sheet(isPresented: $showSettings) { NavigationStack { SettingsView() } }
        .sheet(isPresented: $showPair) { NavigationStack { PairView() } }
    }

    private func banner(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption).foregroundStyle(UsageLevel.hot.color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(UsageLevel.hot.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private var emptyState: some View {
        switch model.cloudAccount {
        case .available, .unknown:
            EmptyStateView(title: L("Waiting for your Mac"), message: L("Run QuotaPulse on a Mac signed in to this iCloud account. Your numbers appear here as soon as it publishes."), symbol: "icloud")
        case .noAccount:
            EmptyStateView(title: L("Sign in to iCloud"), message: L("QuotaPulse gets your numbers from your Mac through iCloud. Sign in to the same account as your Mac, or connect to it directly."), symbol: "person.icloud")
        case .restricted, .temporarilyUnavailable, .notEntitled:
            EmptyStateView(title: Present.cloudAccountText(model.cloudAccount), message: L("You can still connect directly to your Mac over your network or Tailscale."), symbol: "xmark.icloud")
        }
        Button(L("Connect directly to your Mac")) { showPair = true }.buttonStyle(.bordered)
    }
}

// MARK: - Detail

struct ProviderDetailView: View {
    @Environment(ClientModel.self) private var model
    let provider: ProviderID
    @State private var rangeHours: Double = 24
    @State private var samples: [Sample] = []

    var body: some View {
        let now = model.ticker.now
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let p = model.snapshot.provider(provider) {
                    ProviderCard(snapshot: p, sparkline: [], style: .full, now: now)
                    Picker(L("Range"), selection: $rangeHours) {
                        Text(L("6 h")).tag(6.0); Text(L("24 h")).tag(24.0); Text(L("7 d")).tag(168.0)
                    }
                    .pickerStyle(.segmented)
                    HistoryChart(samples: samples, provider: provider, windows: p.windows, range: rangeHours * 3600, now: now)
                        .padding(14)
                        .background(QPDesign.cardBackground, in: RoundedRectangle(cornerRadius: QPDesign.cardRadius, style: .continuous))
                    Link(destination: provider.dashboardURL) {
                        Label(L("Open the provider's usage dashboard"), systemImage: "safari")
                    }
                    .font(.callout)
                }
            }
            .padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(provider.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: rangeHours) { samples = await model.history(provider, hours: rangeHours) }
    }
}

// MARK: - Pairing

struct PairView: View {
    @Environment(ClientModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var urlText = "https://llm.lishuyu.app/llm/hub"
    @State private var token = ""
    @State private var name = "llmgateway"
    @State private var testing = false
    @State private var error: String?
    @State private var showScanner = false

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "gauge.with.dots.needle.33percent").font(.system(size: 40, weight: .light)).foregroundStyle(.tint)
                    Text(L("Connect to your Mac")).font(.title2.weight(.semibold))
                    Text(L("Optional while iCloud works. A direct link uses your network or Tailscale and also sends this device's logs to your Mac. Open QuotaPulse on the Mac → Hub & Devices, then scan the QR code or type the address and token below."))
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }
            Section {
                Button { showScanner = true } label: { Label(L("Scan QR code"), systemImage: "qrcode.viewfinder") }
            }
            Section(L("Manual")) {
                TextField(L("Hub URL"), text: $urlText).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField(L("Token"), text: $token)
                TextField(L("Name"), text: $name)
            }
            if let error { Section { Label(error, systemImage: "xmark.octagon").foregroundStyle(UsageLevel.critical.color) } }
            Section {
                Button {
                    Task { await connect() }
                } label: {
                    HStack { Text(L("Connect")); if testing { Spacer(); ProgressView() } }
                }
                .disabled(testing || token.isEmpty || URL(string: urlText) == nil)
            }
        }
        .navigationTitle(L("Direct connection"))
        .sheet(isPresented: $showScanner) {
            QRScannerView { code in
                showScanner = false
                if let url = URL(string: code), let p = HubPairing.parse(url) {
                    urlText = p.baseURL.absoluteString; token = p.token; name = p.hubName
                    Task { await connect() }
                } else {
                    error = L("That QR code isn't a QuotaPulse pairing code.")
                }
            }
        }
    }

    private func connect() async {
        guard let url = URL(string: urlText) else { return }
        testing = true
        defer { testing = false }
        let p = HubPairing(baseURL: url, token: token, hubName: name)
        if let e = await model.test(p) { error = e } else { error = nil; model.pair(p); dismiss() }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @Environment(ClientModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                LabeledContent(L("Status"), value: Present.cloudAccountText(model.cloudAccount))
                if model.snapshot.generatedAt != .distantPast {
                    LabeledContent(L("Publishing Mac"), value: model.snapshot.hubName)
                    LabeledContent(L("Last update"), value: Present.updatedText(model.snapshot.generatedAt, now: model.ticker.now))
                }
                if let id = model.cloudAccountID { LabeledContent(L("iCloud account ID"), value: id) }
            } header: { Text(L("iCloud")) } footer: {
                Text(L("Your Mac publishes to your private iCloud database and this device reads it from anywhere. If nothing arrives, compare the account ID with the one shown on your Mac."))
            }
            Section {
                if let p = model.pairing {
                    LabeledContent(L("Name"), value: p.hubName)
                    LabeledContent(L("URL"), value: p.baseURL.absoluteString)
                    Button(L("Forget this hub"), role: .destructive) { model.unpair(); dismiss() }
                } else {
                    NavigationLink(L("Connect directly to your Mac")) { PairView() }
                }
            } header: { Text(L("Direct connection")) } footer: {
                Text(L("Optional. Works without iCloud over your network or Tailscale, and sends this device's logs to your Mac."))
            }
            Section(L("Widgets & Watch")) {
                Text(L("Widgets refresh from iCloud about every 15 minutes, or sooner when your Mac publishes. The watch reads iCloud too, and this iPhone also forwards data to it."))
                    .font(.caption).foregroundStyle(.secondary)
                Button(L("Push to Apple Watch now")) { model.pushToWatch() }
            }
            DiagnosticsSection()
            Section(L("About")) {
                Text(L("QuotaPulse never sees your provider credentials on this device — only the numbers your Mac publishes."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(L("Settings"))
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { dismiss() } } }
    }
}

// MARK: - Diagnostics

struct DiagnosticsSection: View {
    @Environment(ClientModel.self) private var model
    @State private var exportURL: URL?
    @State private var exportError: String?
    @State private var uploading = false

    var body: some View {
        Section {
            LabeledContent(L("Device"), value: model.logger.identity.name)
            LabeledContent(L("Log size"), value: ByteCountFormatter.string(fromByteCount: Int64(model.logger.totalBytes), countStyle: .file))
            LabeledContent(L("Lines waiting for the hub"), value: "\(model.pendingTelemetryLines)")
            if let u = model.lastTelemetryUpload {
                LabeledContent(L("Last upload")) {
                    VStack(alignment: .trailing) {
                        Text(u.error == nil ? String(localized: "\(u.count) lines · \(u.at.formatted(date: .omitted, time: .shortened))") : L("Failed")).foregroundStyle(u.error == nil ? .secondary : UsageLevel.critical.color)
                        if let e = u.error { Text(e).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
                    }
                }
            }
            LabeledContent(L("MetricKit payloads"), value: "\(DiagnosticsCollector.storedPayloadCount)")
            Button {
                uploading = true
                Task { await model.syncTelemetry(); uploading = false }
            } label: { HStack { Text(L("Upload logs to hub now")); if uploading { Spacer(); ProgressView() } } }
            .disabled(model.pairing == nil || uploading)
            if let exportURL {
                ShareLink(item: exportURL) { Label(L("Share diagnostics zip"), systemImage: "square.and.arrow.up") }
            } else {
                Button {
                    do { exportURL = try DiagnosticsCollector.exportZip(logger: model.logger); exportError = nil }
                    catch { exportError = error.localizedDescription }
                } label: { Label(L("Export diagnostics"), systemImage: "doc.zipper") }
            }
            if let exportError { Text(exportError).font(.caption).foregroundStyle(UsageLevel.critical.color) }
        } header: { Text(L("Diagnostics")) } footer: {
            Text(L("JSON Lines logs live in Files → QuotaPulse → Logs. With a direct connection they are also pushed to your Mac (Hub & Devices → Devices). Crash and hang reports from MetricKit are kept under Diagnostics."))
        }
    }
}

// MARK: - QR scanner (AVFoundation; falls back gracefully on the simulator)

struct QRScannerView: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let vc = ScannerController()
        vc.onCode = onCode
        return vc
    }

    func updateUIViewController(_ uiViewController: ScannerController, context: Context) {}

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var delivered = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device) else {
                let label = UILabel()
                label.text = L("No camera available. Enter the pairing details manually.")
                label.textColor = .white; label.numberOfLines = 0; label.textAlignment = .center
                label.translatesAutoresizingMaskIntoConstraints = false
                view.addSubview(label)
                NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: view.centerXAnchor), label.centerYAnchor.constraint(equalTo: view.centerYAnchor), label.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.8)])
                return
            }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            layer.frame = view.bounds
            view.layer.addSublayer(layer)
            let s = session
            DispatchQueue.global(qos: .userInitiated).async { s.startRunning() }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            view.layer.sublayers?.first { $0 is AVCaptureVideoPreviewLayer }?.frame = view.bounds
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            if session.isRunning { session.stopRunning() }
        }

        nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject, let s = obj.stringValue else { return }
            Task { @MainActor in self.deliver(s) }
        }

        private func deliver(_ code: String) {
            guard !delivered else { return }
            delivered = true
            onCode?(code)
        }
    }
}
