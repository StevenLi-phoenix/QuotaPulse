import SwiftUI
import QuotaCore
import QuotaUI
import CoreImage.CIFilterBuiltins

// MARK: - Providers

struct ProvidersPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            ForEach(ProviderID.allCases) { id in
                Section {
                    ProviderSettingsRow(id: id)
                } header: {
                    HStack(spacing: 8) {
                        ProviderGlyph(id, size: 20)
                        Text(id.displayName)
                        Text(id.subtitle).foregroundStyle(.secondary).font(.caption)
                        Spacer()
                        if let s = model.snapshot.provider(id) { StatusBadge(s.status) }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct ProviderSettingsRow: View {
    @Environment(AppModel.self) private var model
    let id: ProviderID
    @State private var keyDraft = ""
    @State private var showKey = false

    var body: some View {
        Toggle(L("Enabled"), isOn: Binding(get: { model.settings.isEnabled(id) }, set: { model.setEnabled(id, $0) }))

        switch id {
        case .claude:
            LabeledContent(L("Credentials")) {
                Text(L("Read from Claude Code (Keychain “Claude Code-credentials”, then ~/.claude/.credentials.json). Nothing is stored by QuotaPulse."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Toggle(isOn: Binding(get: { model.settings.options(id)[ClaudeProvider.optionAllowRefresh] == "true" },
                                 set: { model.setOption(id, key: ClaudeProvider.optionAllowRefresh, value: $0 ? "true" : nil) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Refresh expired tokens myself"))
                    Text(L("Off by default: Claude Code rotates its own tokens; a second refresher can sign it out. Opening Claude Code refreshes the token for both."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        case .codex:
            LabeledContent(L("Credentials")) {
                Text(L("Read from ~/.codex/auth.json (or $CODEX_HOME). Expired sessions are refreshed with the Codex CLI's own client id and written back."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Toggle(L("Auto-refresh expired session"), isOn: Binding(get: { model.settings.options(id)[CodexProvider.optionAllowRefresh] != "false" },
                                                                   set: { model.setOption(id, key: CodexProvider.optionAllowRefresh, value: $0 ? nil : "false") }))
        case .deepseek where model.gatewayActive, .opencode where model.gatewayActive:
            LabeledContent(L("Credentials")) {
                Text(L("Provided by your gateway. No API key is needed on this Mac."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        case .deepseek, .opencode, .zai:
            HStack {
                Group {
                    if showKey { TextField(L("API key"), text: $keyDraft) } else { SecureField(L("API key"), text: $keyDraft) }
                }
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.setAPIKey(id, keyDraft) }
                Button { showKey.toggle() } label: { Image(systemName: showKey ? "eye.slash" : "eye") }.buttonStyle(.borderless)
                Button(L("Save")) { model.setAPIKey(id, keyDraft); keyDraft = "" }.disabled(keyDraft.isEmpty)
            }
            HStack {
                Image(systemName: model.apiKeyPresence[id] == true ? "checkmark.seal.fill" : "seal")
                    .foregroundStyle(model.apiKeyPresence[id] == true ? Color.green : Color.secondary)
                Text(model.apiKeyPresence[id] == true ? L("A key is stored in your Keychain.") : L("No key stored. Environment variables also work."))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.apiKeyPresence[id] == true { Button(L("Remove key"), role: .destructive) { model.setAPIKey(id, "") } }
                Link(L("Get a key"), destination: id.dashboardURL).font(.caption)
            }
            if id == .zai {
                Picker(L("Region"), selection: Binding(get: { model.settings.options(id)[ZaiProvider.optionRegion] ?? "cn" },
                                                      set: { model.setOption(id, key: ZaiProvider.optionRegion, value: $0) })) {
                    Text("bigmodel.cn").tag("cn")
                    Text("z.ai (global)").tag("global")
                }
            }
        }
    }
}

// MARK: - Hub

struct HubPage: View {
    @Environment(AppModel.self) private var model
    @State private var portDraft = ""
    @State private var selectedHost = ""

    var body: some View {
        Form {
            CloudSyncSection()

            Section {
                Toggle(L("Serve usage over the network"), isOn: Binding(get: { model.settings.hub.enabled }, set: { model.setHub(enabled: $0) }))
                Toggle(L("Reachable from other devices (Tailscale / LAN)"), isOn: Binding(get: { model.settings.hub.exposeOnNetwork }, set: { model.setHub(expose: $0) }))
                    .disabled(!model.settings.hub.enabled)
                HStack {
                    TextField(L("Port"), text: $portDraft).frame(width: 90).textFieldStyle(.roundedBorder)
                        .onSubmit { if let p = UInt16(portDraft), p > 1024 { model.setHub(port: p) } }
                    Button(L("Apply")) { if let p = UInt16(portDraft), p > 1024 { model.setHub(port: p) } }
                    Spacer()
                    Label(model.hubState, systemImage: model.hubState.hasPrefix("listening") ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(model.hubState.hasPrefix("listening") ? .green : .secondary).font(.caption)
                }
            } header: { Text(L("Hub server")) } footer: {
                Text(L("Optional direct link for paired devices and local scripts: authenticated JSON over HTTP on your network. It also receives device logs. iPhone and Apple Watch don't need it while iCloud sync is on."))
            }

            if model.settings.hub.enabled, let token = model.hubToken {
                Section {
                    Picker(L("Address"), selection: $selectedHost) {
                        ForEach(model.hubAddresses, id: \.self) { Text($0 + ($0.hasPrefix("100.") ? "  (Tailscale)" : "")).tag($0) }
                        Text("127.0.0.1").tag("127.0.0.1")
                    }
                    if let url = model.pairingURL(forHost: selectedHost.isEmpty ? (model.hubAddresses.first ?? "127.0.0.1") : selectedHost) {
                        HStack(alignment: .top, spacing: 18) {
                            QRCodeView(string: url.absoluteString).frame(width: 180, height: 180)
                            VStack(alignment: .leading, spacing: 8) {
                                Text(L("Scan with the QuotaPulse iPhone app, or paste these values manually:")).font(.callout)
                                LabeledContent(L("URL")) { Text(url.query()?.components(separatedBy: "&").first?.replacingOccurrences(of: "url=", with: "").removingPercentEncoding ?? "").textSelection(.enabled).font(.caption.monospaced()) }
                                LabeledContent(L("Token")) { Text(token).textSelection(.enabled).font(.caption.monospaced()) }
                                HStack {
                                    Button(L("Copy pairing link")) {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                                    }
                                    Button(L("New token"), role: .destructive) { model.regenerateHubToken() }
                                }
                                Text(L("A new token disconnects every paired device.")).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                } header: { Text(L("Pair a device (optional)")) }

                Section {
                    if model.devices.isEmpty {
                        Text(L("No device has reported yet. Paired iPhones and Watches send their logs on every refresh.")).font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(model.devices) { d in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: d.platform.lowercased().hasPrefix("watch") ? "applewatch" : "iphone").font(.title3).foregroundStyle(.secondary).frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(d.name).font(.headline)
                                    Text("\(d.platform) · v\(d.appVersion)").font(.caption).foregroundStyle(.secondary)
                                }
                                let heartbeat = Present.updatedText(d.lastSeen, now: model.ticker.now).replacingOccurrences(of: "Updated ", with: "")
                                Text(String(localized: "Last heartbeat \(heartbeat) · \(d.eventCount) events"))
                                    .font(.caption).foregroundStyle(.secondary)
                                if let e = d.lastError {
                                    Label("\(e)" + (d.lastErrorAt.map { " · \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""), systemImage: "exclamationmark.triangle")
                                        .font(.caption).foregroundStyle(UsageLevel.hot.color).lineLimit(2)
                                }
                            }
                            Spacer()
                            Button(L("Reveal in Finder")) { model.revealTelemetry(d) }.controlSize(.small)
                        }
                        .padding(.vertical, 2)
                    }
                    HStack {
                        Button(L("Refresh list")) { model.reloadDevices() }
                        Button(L("Reveal telemetry folder")) { model.revealTelemetry() }
                    }
                    .controlSize(.small)
                } header: { Text(L("Devices")) } footer: {
                    Text(L("Each device uploads its JSON Lines log on refresh to POST /v1/telemetry; files land under telemetry/<device>/YYYY-MM-DD.log next to the hub data."))
                }

                Section(L("Endpoints")) {
                    ForEach([HubProtocol.healthPath, HubProtocol.snapshotPath, HubProtocol.historyPath + "?provider=claude&hours=24"], id: \.self) { p in
                        Text("GET \(p)").font(.caption.monospaced())
                    }
                    Text("POST \(HubProtocol.telemetryPath)  (application/x-ndjson)").font(.caption.monospaced())
                    Text(L("Send `Authorization: Bearer <token>`.")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { portDraft = String(model.settings.hub.port); selectedHost = model.hubAddresses.first ?? "127.0.0.1"; model.reloadDevices() }
        .onChange(of: model.ticker.now) { _, _ in model.reloadDevices() }
    }
}

struct CloudSyncSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            Toggle(L("Sync to iCloud"), isOn: Binding(get: { model.settings.cloud.enabled }, set: { model.setCloudSync(enabled: $0) }))
                .disabled(!model.cloudAvailable)
            if !model.cloudAvailable {
                Label(Present.cloudAccountText(.notEntitled), systemImage: "xmark.icloud").font(.caption).foregroundStyle(.secondary)
            } else if model.settings.cloud.enabled {
                LabeledContent(L("Status")) { status }
                if let id = model.cloudStatus.accountID {
                    LabeledContent(L("iCloud account ID")) { Text(id).font(.caption.monospaced()).textSelection(.enabled) }
                }
            } else {
                Button(L("Remove QuotaPulse data from iCloud"), role: .destructive) { model.removeCloudData() }
            }
        } header: { Text(L("iCloud")) } footer: {
            Text(L("Your iPhone and Apple Watch get these numbers from anywhere once they're signed in to the same iCloud account, with nothing to pair. Only usage numbers, plan names and this Mac's name go to your private iCloud database. API keys and tokens never leave this Mac."))
        }
    }

    @ViewBuilder private var status: some View {
        let s = model.cloudStatus
        if s.account != .available && s.account != .unknown {
            Label(Present.cloudAccountText(s.account), systemImage: "exclamationmark.icloud").foregroundStyle(UsageLevel.hot.color)
        } else if let e = s.lastError {
            Label(e, systemImage: "exclamationmark.icloud").foregroundStyle(UsageLevel.hot.color).lineLimit(2)
        } else if let t = s.lastPublishedAt {
            Label(Present.updatedText(t, now: model.ticker.now), systemImage: "checkmark.icloud").foregroundStyle(.secondary)
        } else {
            Label(L("Waiting for first refresh…"), systemImage: "icloud").foregroundStyle(.secondary)
        }
    }
}

struct QRCodeView: View {
    var string: String

    var body: some View {
        if let img = Self.image(for: string) {
            Image(nsImage: img).interpolation(.none).resizable().scaledToFit()
                .padding(8).background(.white, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    static func image(for string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}

// MARK: - Alerts

struct AlertsPage: View {
    @Environment(AppModel.self) private var model
    @State private var t1: Double = 80
    @State private var t2: Double = 95

    var body: some View {
        Form {
            Section {
                Toggle(L("Notify me when a window crosses a threshold"), isOn: Binding(get: { model.settings.alerts.enabled }, set: { model.setAlerts(enabled: $0) }))
                HStack {
                    Text(L("First warning")); Slider(value: $t1, in: 50...95, step: 5) { Text("") }; Text("\(Int(t1))%").monospacedDigit().frame(width: 40)
                }
                HStack {
                    Text(L("Final warning")); Slider(value: $t2, in: 60...100, step: 5) { Text("") }; Text("\(Int(t2))%").monospacedDigit().frame(width: 40)
                }
                Button(L("Save thresholds")) { model.setAlerts(thresholds: [min(t1, t2), max(t1, t2)]) }
            } header: { Text(L("Thresholds")) } footer: {
                Text(L("macOS asks for notification permission the first time you turn this on. Each threshold fires once per window cycle."))
            }
        }
        .formStyle(.grouped)
        .onAppear {
            let th = model.settings.alerts.thresholds
            if th.count >= 2 { t1 = th[0]; t2 = th[1] }
        }
    }
}

// MARK: - General

struct GeneralPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section(L("Polling")) {
                Picker(L("Refresh every"), selection: Binding(get: { model.settings.pollInterval }, set: { model.setPollInterval($0) })) {
                    Text(L("2 minutes")).tag(120.0)
                    Text(L("5 minutes")).tag(300.0)
                    Text(L("10 minutes")).tag(600.0)
                    Text(L("30 minutes")).tag(1800.0)
                }
                Text(L("Claude's usage endpoint rate-limits aggressively; 5 minutes is the recommended floor. 429s back off automatically up to 30 minutes."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("Menu bar")) {
                Picker(L("Show"), selection: Binding(get: { model.settings.menuBarStyle }, set: { model.setMenuBarStyle($0) })) {
                    Text(L("Ring and percent")).tag("both")
                    Text(L("Percent only")).tag("percent")
                    Text(L("Ring only")).tag("icon")
                }
                .pickerStyle(.segmented)
                Toggle(L("Launch at login"), isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                Toggle(L("Show in Dock"), isOn: Binding(get: { model.showInDock }, set: { model.showInDock = $0 }))
                Text(L("Off: QuotaPulse is a menu-bar-only app (find it top right, or search QuotaPulse in Spotlight). On: a Dock icon that reopens this window."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("History")) {
                Picker(L("Keep samples for"), selection: Binding(get: { model.settings.retentionDays }, set: { model.setRetention($0) })) {
                    Text(L("7 days")).tag(7)
                    Text(L("30 days")).tag(30)
                    Text(L("90 days")).tag(90)
                }
                LabeledContent(L("Stored samples")) { Text("\(model.sampleCount)").monospacedDigit() }
                HStack {
                    Button(L("Reveal data folder")) { model.revealDataFolder() }
                    Button(L("Delete history"), role: .destructive) { model.clearHistory() }
                }
                Text(model.dataFolder.path).font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Section(L("About")) {
                LabeledContent(L("Version")) { Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—") }
                Text(L("QuotaPulse reads the credentials your CLIs already keep on this Mac and never sends them anywhere except the provider itself. Logs: `log stream --predicate 'subsystem == \"app.lishuyu.quotapulse\"'`."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
