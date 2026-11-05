import SwiftUI
import WebKit
import MapKit
import CoreLocation

// MARK: - Sign in (Apple's own page, so the app never sees the password)

struct ICloudWebView: UIViewRepresentable {
    /// Gets the web view's cookies every few seconds once the user looks signed in.
    /// Return true when iCloud accepted them; polling then stops.
    let onCookies: ([HTTPCookie]) async -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(onCookies) }

    func makeUIView(context: Context) -> WKWebView {
        // The shared page: its login is kept, and it's the same one the app calls through later.
        let v = FindMyWebBridge.shared.webView
        context.coordinator.web = v
        context.coordinator.start()
        return v
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        let onCookies: ([HTTPCookie]) async -> Bool
        weak var web: WKWebView?
        private var timer: Timer?
        private var busy = false
        private var done = false

        init(_ f: @escaping ([HTTPCookie]) async -> Bool) { onCookies = f }

        func start() {
            timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.poll() }
        }

        func stop() { timer?.invalidate(); timer = nil }

        private func poll() {
            guard !busy, !done, let store = web?.configuration.websiteDataStore.httpCookieStore else { return }
            store.getAllCookies { [weak self] cookies in
                guard let self else { return }
                let signed = cookies.contains { $0.name.hasPrefix("X-APPLE-WEBAUTH-USER") || $0.name.hasPrefix("X-APPLE-WEBAUTH-TOKEN") }
                guard signed else { return }
                self.busy = true
                Task { @MainActor in
                    let ok = await self.onCookies(cookies)
                    self.busy = false
                    if ok { self.done = true; self.stop() }
                }
            }
        }
    }
}

struct FindMyLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var fm = FindMyStore.shared
    @ObservedObject var log = FindMyLog.shared
    @State private var appleID = UserDefaults.standard.string(forKey: "fmAppleID") ?? ""
    @State private var password = ""
    @State private var code = ""
    @State private var phones: [FMPhone] = []
    @State private var needsCode = false
    @State private var textedTo: FMPhone?
    @State private var busy = false
    @State private var error: String?
    @State private var showWeb = false

    var body: some View {
        NavigationStack {
            Form {
                if !needsCode {
                    Section {
                        TextField("Apple ID (email)", text: $appleID)
                            .textContentType(.username)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                    } footer: {
                        Text("Goes straight to Apple, the same way icloud.com signs you in. The password is also saved in this phone's Keychain so the app can sign back in by itself when the session runs out.")
                    }
                    Section {
                        Button { signIn() } label: {
                            HStack { Text("Sign In"); if busy { Spacer(); ProgressView() } }
                        }
                        .disabled(busy || appleID.isEmpty || password.isEmpty)
                    }
                } else {
                    Section {
                        TextField("6-digit code", text: $code)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                    } footer: {
                        Text(textedTo.map { "Texted to \($0.label)." } ?? "Apple sent a code to your other devices.")
                    }
                    Section {
                        Button { verify() } label: {
                            HStack { Text("Verify"); if busy { Spacer(); ProgressView() } }
                        }
                        .disabled(busy || code.filter(\.isNumber).count < 6)
                        Button("Send the code to my devices again") {
                            busy = true
                            Task { phones = await fm.resendCodes(); busy = false }
                        }.disabled(busy)
                        ForEach(phones) { p in
                            Button("Text a code to \(p.label)") { text(p) }.disabled(busy)
                        }
                    }
                }
                if let e = error {
                    Section { Text(e).foregroundStyle(.red) }
                }
                // What Apple answered, right here, so there's no digging for the log.
                if !log.lines.isEmpty {
                    Section("What Apple said") {
                        Text(log.lines.suffix(8).reversed().joined(separator: "\n"))
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                Section {
                    Button("Use Apple's web page instead") { showWeb = true }
                        .font(.footnote)
                }
            }
            .navigationTitle("Sign in to iCloud")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .sheet(isPresented: $showWeb) { FindMyWebLoginView(done: { showWeb = false; dismiss() }) }
        }
    }

    private func signIn() {
        busy = true; error = nil
        Task {
            do {
                switch try await fm.login(appleID: appleID, password: password) {
                case .signedIn: dismiss()
                case .needsCode(let p): phones = p; needsCode = true
                }
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }

    private func verify() {
        busy = true; error = nil
        Task {
            do { try await fm.submitCode(code, phoneID: textedTo?.id); dismiss() }
            catch { self.error = error.localizedDescription }
            busy = false
        }
    }

    private func text(_ p: FMPhone) {
        busy = true; error = nil
        Task {
            do { try await fm.textCode(phoneID: p.id); textedTo = p }
            catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}

/// Fallback: sign in on Apple's own page.
struct FindMyWebLoginView: View {
    @Environment(\.dismiss) private var dismiss
    let done: () -> Void

    var body: some View {
        NavigationStack {
            ICloudWebView { cookies in
                let ok = await FindMyStore.shared.signIn(cookies: cookies)
                if ok { done() }
                return ok
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("Apple's sign-in page")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

// MARK: - Devices tab

struct DevicesTab: View {
    @ObservedObject var fm = FindMyStore.shared
    @ObservedObject var loc = LocationRecorder.shared
    let focus: (CLLocationCoordinate2D) -> Void
    @State private var showLogin = false
    @State private var showLog = false
    @AppStorage(DistanceUnit.storageKey) private var unit: DistanceUnit = .localeDefault

    var body: some View {
        NavigationStack {
            List {
                if !fm.signedIn {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Bring your iPhone, iPad, Watch and Mac into this map and get a warning when one gets left behind.")
                            Button { showLogin = true } label: {
                                Label("Sign in to iCloud", systemImage: "icloud")
                            }
                            .buttonStyle(.borderedProminent)
                            if let e = fm.lastError {
                                Text(e).font(.footnote).foregroundStyle(.orange)
                            }
                        }
                        .padding(.vertical, 4)
                    } footer: {
                        Text("You sign in with your Apple ID and password, and 2FA code if asked. This uses the same service as icloud.com/find, which Apple doesn't offer as a public API, so it can break without notice. Use at your own risk.")
                    }
                } else {
                    Section {
                        ForEach(sorted) { d in
                            NavigationLink {
                                DeviceDetail(id: d.id)
                            } label: {
                                DeviceRow(device: d, me: loc.current)
                            }
                            .simultaneousGesture(TapGesture().onEnded {
                                if let c = d.coordinate { focus(c) }
                            })
                        }
                        if fm.devices.isEmpty {
                            Text(fm.refreshing ? "Looking for devices..." : "No devices yet. Pull down to refresh.")
                                .foregroundStyle(.secondary)
                        }
                    } footer: {
                        if let e = fm.lastError {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(e).foregroundStyle(.orange)
                                if fm.expired {
                                    Button("Renew session", systemImage: "arrow.triangle.2.circlepath") {
                                        Task { await fm.refresh(polls: 4, userAsked: true) }
                                    }
                                    .buttonStyle(.borderedProminent)
                                }
                            }
                        } else if let t = fm.lastRefresh {
                            Text("Updated \(t.formatted(.relative(presentation: .named))). Alerts need Location set to Always.")
                        }
                    }
                }
            }
            .navigationTitle("Devices")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await fm.refresh(polls: 4) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if fm.signedIn {
                            Button("Refresh", systemImage: "arrow.clockwise") { Task { await fm.refresh(polls: 4) } }
                            Button("Check for Left-Behind Now", systemImage: "location.magnifyingglass") {
                                Task { await fm.check("manual", force: true) }
                            }
                        }
                        Button("Activity Log", systemImage: "list.bullet.rectangle") { showLog = true }
                        if fm.signedIn {
                            Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { fm.signOut() }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showLogin) { FindMyLoginView() }
            .sheet(isPresented: $showLog) { FindMyLogView() }
            .task {
                if fm.signedIn, Date().timeIntervalSince(fm.lastRefresh ?? .distantPast) > 60 {
                    await fm.refresh()
                }
            }
        }
    }

    private var sorted: [FMDevice] {
        guard let me = loc.current else { return fm.devices }
        return fm.devices.sorted { a, b in
            func d(_ x: FMDevice) -> Double {
                guard let c = x.coordinate else { return .greatestFiniteMagnitude }
                return me.distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
            }
            return d(a) < d(b)
        }
    }
}

struct DeviceRow: View {
    let device: FMDevice
    let me: CLLocation?
    @AppStorage(DistanceUnit.storageKey) private var unit: DistanceUnit = .localeDefault

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: device.symbol)
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Circle().fill((device.online ? Color.green : Color.gray).gradient))
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).font(.body.weight(.medium))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let b = device.battery, b >= 0 {
                BatteryLabel(level: Int((b * 100).rounded()), stale: !device.online).font(.caption)
            }
        }
    }

    private var subtitle: String {
        guard let at = device.locAt, let c = device.coordinate else {
            return device.online ? "Locating..." : "No location"
        }
        var parts: [String] = [at.formatted(.relative(presentation: .named))]
        if let me {
            let d = me.distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
            parts.append(unit.format(d) + " away")
        }
        if !device.online { parts.append("offline") }
        return parts.joined(separator: " · ")
    }
}

struct DeviceDetail: View {
    let id: String
    @ObservedObject var fm = FindMyStore.shared
    @ObservedObject var loc = LocationRecorder.shared
    @State private var message: String?
    @State private var busy = false

    var body: some View {
        if let d = fm.devices.first(where: { $0.id == id }) {
            let w = fm.setting(id)
            List {
                if let c = d.coordinate {
                    Section {
                        Map(initialPosition: .region(MKCoordinateRegion(center: c, latitudinalMeters: 500, longitudinalMeters: 500))) {
                            Annotation(d.name, coordinate: c, anchor: .bottom) { DevicePin(device: d) }
                            MapCircle(center: c, radius: max(d.accuracy, 10))
                                .foregroundStyle(.blue.opacity(0.12))
                        }
                        .frame(height: 180)
                        .listRowInsets(EdgeInsets())
                        .allowsHitTesting(false)
                    }
                }
                Section {
                    LabeledContent("Model", value: d.model.isEmpty ? d.cls : d.model)
                    LabeledContent("Status", value: d.online ? "Online" : "Offline")
                    if let b = d.battery, b >= 0 {
                        LabeledContent("Battery") {
                            BatteryLabel(level: Int((b * 100).rounded()), stale: !d.online)
                            if d.charging { Image(systemName: "bolt.fill").foregroundStyle(.green) }
                        }
                    }
                    if let at = d.locAt {
                        LabeledContent("Location", value: at.formatted(.relative(presentation: .named)))
                    }
                }
                Section {
                    Button { play(d) } label: { Label("Play Sound", systemImage: "speaker.wave.3.fill") }
                        .disabled(busy)
                    if let c = d.coordinate {
                        Button {
                            let url = URL(string: "http://maps.apple.com/?daddr=\(c.latitude),\(c.longitude)&dirflg=d")!
                            UIApplication.shared.open(url)
                        } label: { Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill") }
                    }
                    if let m = message { Text(m).font(.footnote).foregroundStyle(.secondary) }
                }
                Section {
                    Toggle("Warn if left behind", isOn: Binding(
                        get: { w.enabled }, set: { v in fm.update(id) { $0.enabled = v } }))
                    if w.enabled {
                        GeofenceSlider(title: "Warn when apart by", radius: Binding(
                            get: { fm.setting(id).threshold },
                            set: { v in fm.update(id) { $0.threshold = v } }))
                        Toggle("Even if it usually stays put", isOn: Binding(
                            get: { w.always }, set: { v in fm.update(id) { $0.always = v } }))
                    }
                } header: {
                    Text("Left-Behind Warning")
                } footer: {
                    Text("Warns when this device is farther than that from you. By default only for devices that have recently travelled with you, so a Mac that lives at home stays quiet. Places set to Ignore under Me never warn. Needs Location Always; iOS checks every so often, so it isn't instant.")
                }
            }
            .navigationTitle(d.name)
            .navigationBarTitleDisplayMode(.inline)
        } else {
            Text("Device not found").foregroundStyle(.secondary)
        }
    }

    private func play(_ d: FMDevice) {
        busy = true
        Task {
            message = await fm.playSound(d.id)
            busy = false
        }
    }
}

struct DevicePin: View {
    let device: FMDevice
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle().fill(.white).frame(width: 40, height: 40).shadow(radius: 3)
                Image(systemName: device.symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill((device.online ? Color.green : Color.gray).gradient))
            }
            Triangle().fill(.white).frame(width: 10, height: 7).shadow(radius: 1)
        }
    }
}

// MARK: - Activity log

struct FindMyLogView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var log = FindMyLog.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(log.lines.isEmpty ? "Nothing yet." : log.lines.reversed().joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .textSelection(.enabled)
            }
            .navigationTitle("Activity Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ShareLink(item: log.lines.joined(separator: "\n")) { Label("Share", systemImage: "square.and.arrow.up") }
                        Button("Clear", systemImage: "trash", role: .destructive) { log.clear() }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
    }
}
