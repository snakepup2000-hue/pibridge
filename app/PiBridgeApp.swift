import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
struct PiBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var engine = Engine.shared

    var body: some Scene {
        // Window, not WindowGroup: a WindowGroup treats every open-file event
        // (and every "New Window") as a new scene, which multiplied the UI.
        Window("PiBridge", id: "main") {
            ContentView()
                .environmentObject(engine)
                .frame(minWidth: 760, minHeight: 560)
                .onAppear { WindowPlacer.placeIfOffscreen() }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

/// SwiftUI persists window frames by name. A frame saved while a second
/// display was attached will reopen on that display, which is where it cannot
/// be seen. This pulls the main window back onto a screen that exists.
enum WindowPlacer {
    /// Both displays here are real, so a saved frame can legitimately land on
    /// the second monitor and look "missing" to someone at the main display.
    /// First run after this change centres on the main screen once; after that
    /// whatever position you choose is respected.
    static func placeIfOffscreen() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "didPlaceWindow") else { return }
        // SwiftUI restores the saved frame a moment after the view appears, and
        // the exact moment moves between releases. Poll briefly and stop as
        // soon as the window is on the main display.
        var attempts = 0
        func attempt() {
            attempts += 1
            guard let main = NSScreen.main,
                  let window = NSApp.windows.first(where: {
                      $0.isVisible && !$0.className.contains("Panel")
                  }) else {
                if attempts < 20 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: attempt) }
                return
            }
            let v = main.visibleFrame
            let onMain = v.intersects(window.frame)
            if onMain || attempts > 20 {
                if onMain { defaults.set(true, forKey: "didPlaceWindow") }
                return
            }
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(x: v.midX - size.width / 2,
                                          y: v.midY - size.height / 2))
            if attempts < 20 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: attempt) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: attempt)
    }

    /// Force back to the main display; used by the Settings button.
    static func recenterOnMain() {
        guard let main = NSScreen.main,
              let window = NSApp.windows.first(where: {
                  $0.isVisible && !$0.className.contains("Panel")
              }) else { return }
        let size = window.frame.size
        let v = main.visibleFrame
        window.setFrameOrigin(NSPoint(x: v.midX - size.width / 2,
                                      y: v.midY - size.height / 2))
        window.makeKeyAndOrderFront(nil)
    }
}

/// Receives file-open events so `open -a PiBridge track.flac` and Finder's
/// "Open With" both start playback immediately.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        Task { @MainActor in Engine.shared.handleOpen(url: url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Stops the child engine and the Pi's aplay before we go away.
        MainActor.assumeIsolated { Engine.shared.shutdown() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A saved window frame can point at a display that is no longer
        // attached (or at a coordinate beyond every screen), which makes the
        // app look dead: it launched, but the window is nowhere visible.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })
            else { return }
            // NSScreen.main is the screen with the key window, NOT the primary
            // display, so ask for screens[0] (the one with the menu bar) and set
            // the frame explicitly rather than relying on center().
            let primary = NSScreen.screens.first ?? NSScreen.main
            if let area = primary?.visibleFrame {
                let mid = NSPoint(x: window.frame.midX, y: window.frame.midY)
                if !area.contains(mid) {
                    let size = window.frame.size
                    window.setFrame(NSRect(x: area.midX - size.width / 2,
                                           y: area.midY - size.height / 2,
                                           width: size.width, height: size.height),
                                    display: true)
                }
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

// MARK: - Palette

private enum Ink {
    static let bg = Color(red: 0.055, green: 0.06, blue: 0.075)
    static let panel = Color(red: 0.095, green: 0.102, blue: 0.125)
    static let panelEdge = Color.white.opacity(0.07)
    static let text = Color(white: 0.92)
    static let dim = Color(white: 0.55)
    static let accent = Color(red: 0.42, green: 0.82, blue: 0.72)
    static let warm = Color(red: 0.95, green: 0.72, blue: 0.36)
    static let bad = Color(red: 0.93, green: 0.42, blue: 0.42)
}

// MARK: - Root

struct ContentView: View {
    @EnvironmentObject var engine: Engine
    @State private var file: URL?
    @State private var showingSettings = false
    @State private var showingDiag = false
    @State private var diagText = ""
    @State private var loadingDiag = false
    @State private var dropTargeted = false
    @State private var hovered: Int?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Ink.panelEdge)

            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 14) {
                    sourcePanel
                    transportPanel
                }
                .frame(width: 392)

                VStack(spacing: 14) {
                    metersPanel
                    queuePanel
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(Ink.bg)
        .foregroundStyle(Ink.text)
        .sheet(isPresented: $showingSettings) { SettingsSheet().environmentObject(engine) }
        .sheet(isPresented: $showingDiag) { diagSheet }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            // Directories land here too; the engine expands them in order.
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    file = url
                    engine.open(url: url)
                }
            }
            return true
        }
        .overlay(dropHighlight)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("PiBridge").font(.system(size: 17, weight: .semibold, design: .rounded))
                Text("Mac → \(engine.host) → \(engine.device)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Ink.dim)
            }
            Spacer()
            phaseBadge
            Button {
                loadingDiag = true
                showingDiag = true
                Task {
                    let t = await engine.runDiagnostics()
                    diagText = t
                    loadingDiag = false
                }
            } label: {
                Label("Link test", systemImage: "wave.3.right")
            }
            .buttonStyle(.borderless)
            Button { WindowPlacer.recenterOnMain() } label: {
                Image(systemName: "macwindow.on.rectangle")
            }
            .buttonStyle(.borderless)
            .help("Move this window to the main display")
            Button { showingSettings = true } label: {
                Label("Settings", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(Ink.panel)
    }

    private var phaseBadge: some View {
        let (label, color): (String, Color) = {
            switch engine.phase {
            case .idle: return ("IDLE", Ink.dim)
            case .connecting: return ("CONNECTING", Ink.warm)
            case .playing: return ("PLAYING", Ink.accent)
            case .stopping: return ("STOPPING", Ink.warm)
            case .failed: return ("ERROR", Ink.bad)
            }
        }()
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.12)))
    }

    // MARK: Source

    private var sourcePanel: some View {
        Panel(title: "SOURCE") {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Image(systemName: file == nil ? "music.note" : "music.note.list")
                        .foregroundStyle(Ink.accent)
                    Text(file?.lastPathComponent ?? "Drop a track or a folder")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(file == nil ? Ink.dim : Ink.text)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                }
                .padding(10)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.25)))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(dropTargeted ? Ink.accent : Ink.panelEdge, lineWidth: 1))

                HStack(spacing: 8) {
                    Button {
                        chooseTrack()
                    } label: {
                        Label("Open File", systemImage: "music.note")
                            .font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .controlSize(.large)

                    Button {
                        chooseFolder()
                    } label: {
                        Label("Open Folder", systemImage: "folder.fill")
                            .font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .tint(Ink.accent)
                    .keyboardShortcut("o", modifiers: [.command])
                }

                HStack(spacing: 8) {
                    Button(engine.dsd ? "Switch to PCM" : "Switch to DSD") {
                        engine.dsd.toggle()
                    }
                    .help("Switch between PCM and native DSD256")
                    Spacer()
                    Text(engine.dsd ? "DSD256" : "352.8 kHz")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Ink.dim)
                }

                Divider().overlay(Ink.panelEdge)

                LabeledSlider(label: "Buffer", value: $engine.bufferMs,
                              range: 4...200, format: "%.0f ms")
                LabeledSlider(label: "Gain",
                              value: Binding(get: { engine.gainDb },
                                             set: { engine.setGain($0) }),
                              range: -24...6, format: "%+.1f dB")
                Text(engine.isRunning
                     ? "live · applies as you move it"
                     : "applies when playback starts")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Ink.dim)
            }
        }
    }

    // MARK: Transport

    private var transportPanel: some View {
        Panel(title: "TRANSPORT") {
            VStack(spacing: 10) {
                // One control per action, in transport order: ◀◀  ▶ / ■  ▶▶.
                // There used to be a second stop icon, which made neither button
                // read as "the" stop.
                HStack(spacing: 8) {
                    Button { engine.previous() } label: {
                        Image(systemName: "backward.fill")
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!engine.isRunning)
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
                    .help("Previous track (⌘←)")

                    Button {
                        guard let f = file else { chooseTrack(); return }
                        if engine.isRunning { engine.stop() } else { engine.open(url: f) }
                    } label: {
                        Label(engine.isRunning ? "Stop" : "Play",
                              systemImage: engine.isRunning ? "stop.fill" : "play.fill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(engine.isRunning ? Ink.bad : Ink.accent)
                    .keyboardShortcut(.space, modifiers: [])
                    .help(engine.isRunning ? "Stop (space)" : "Play (space)")

                    Button { engine.next() } label: {
                        Image(systemName: "forward.fill")
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!engine.isRunning)
                    .keyboardShortcut(.rightArrow, modifiers: [.command])
                    .help("Next track (⌘→)")
                }

                if let err = engine.errorText {
                    Text(err).font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Ink.bad).lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if !engine.summary.isEmpty {
                    Text(engine.summary).font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Ink.dim).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: Meters

    private var metersPanel: some View {
        Panel(title: "LINK") {
            VStack(spacing: 12) {
                LevelBar(label: "PEAK", db: engine.status.peakDb)
                LevelBar(label: "RMS", db: engine.status.rmsDb)

                Divider().overlay(Ink.panelEdge)

                FillGauge(fillMs: engine.status.fillMs, bufferMs: engine.status.bufferMs)

                HStack(spacing: 0) {
                    // aplay reports every xrun the moment it happens; this is
                    // the number that matches what you hear.
                    Readout(label: "XRUNS",
                            value: "\(engine.status.xruns + engine.status.underruns)",
                            warn: (engine.status.xruns + engine.status.underruns) > 0)
                    Readout(label: "DRIFT", value: String(format: "%+.0f ppm", engine.status.trimPpm))
                    Readout(label: "ELAPSED", value: clock(engine.status.seconds))
                }
            }
        }
    }

    private func clock(_ s: Double) -> String {
        let t = Int(s.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    // MARK: Queue

    @ViewBuilder
    private var queuePanel: some View {
        if engine.tracks.isEmpty {
            logPanel
        } else {
            Panel(title: "QUEUE · \(engine.currentTrack) OF \(max(engine.trackTotal, engine.tracks.count))") {
                ScrollView {
                    // LazyVStack: a 1,044-track folder must not lay out every
                    // row up front.
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(engine.tracks) { t in
                            let active = t.id == engine.currentTrack
                            QueueRow(track: t, active: active, hovered: hovered == t.id)
                                .contentShape(Rectangle())
                                .onHover { inside in
                                    hovered = inside ? t.id : (hovered == t.id ? nil : hovered)
                                }
                                .onTapGesture { engine.play(track: t.id) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    // MARK: Log

    private var logPanel: some View {
        Panel(title: "ENGINE") {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if engine.log.isEmpty {
                        Text("No activity yet.").foregroundStyle(Ink.dim)
                            .font(.system(size: 10, design: .monospaced))
                    }
                    ForEach(Array(engine.log.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(line.contains("underrun") ? Ink.bad : Ink.dim)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    // MARK: Diag

    private var diagSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Link test").font(.headline)
                Spacer()
                Button("Close") { showingDiag = false }
            }
            if loadingDiag {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Text(diagText)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(16)
        .frame(width: 560, height: 440)
        .background(Ink.bg)
    }

    private var dropHighlight: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Ink.accent, lineWidth: 2)
            .opacity(dropTargeted ? 1 : 0)
            .padding(6)
            .allowsHitTesting(false)
    }

    private func chooseTrack() { choose(directories: false, prompt: "Play") }

    private func chooseFolder() { choose(directories: true, prompt: "Play Folder") }

    private func choose(directories: Bool, prompt: String) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = directories
        panel.canChooseFiles = !directories
        panel.canCreateDirectories = false
        panel.prompt = prompt
        panel.message = directories
            ? "Choose a folder of tracks; they play in name order"
            : "Choose a track"
        if panel.runModal() == .OK, let url = panel.url {
            file = url
            engine.open(url: url)
        }
    }

    /// ⌘O / space with nothing loaded.
    private func chooseFile() { chooseFolder() }
}

// MARK: - Components

/// One song in the folder. Clicking it jumps playback to that track.
struct QueueRow: View {
    let track: Engine.Track
    let active: Bool
    let hovered: Bool

    var body: some View {
        HStack(spacing: 7) {
            Group {
                if active {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 8))
                } else if hovered {
                    Image(systemName: "play.fill")
                        .font(.system(size: 8))
                } else {
                    Text(String(format: "%02d", track.id))
                        .font(.system(size: 9, design: .monospaced))
                }
            }
            .foregroundStyle(active ? Ink.accent : (hovered ? Ink.text : Ink.dim))
            .frame(width: 18, alignment: .trailing)

            Text(track.name)
                .font(.system(size: 11, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? Ink.text : (hovered ? Ink.text : Ink.dim))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 5)
        .background(RoundedRectangle(cornerRadius: 4)
            .fill(active ? Ink.accent.opacity(0.12)
                         : (hovered ? Color.white.opacity(0.06) : Color.clear)))
        .help(active ? "Playing" : "Play this track")
    }
}

struct Panel<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(Ink.dim)
                .tracking(1.2)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Ink.panel))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Ink.panelEdge))
    }
}

struct LabeledSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String

    var body: some View {
        HStack(spacing: 9) {
            Text(label)
                .font(.system(size: 11)).foregroundStyle(Ink.dim)
                .frame(width: 44, alignment: .leading)
            Slider(value: $value, in: range)
            Text(String(format: format, value))
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 62, alignment: .trailing)
        }
    }
}

struct LevelBar: View {
    let label: String
    let db: Double

    private var normalized: Double {
        // -60 dB .. 0 dB
        max(0, min(1, (db + 60) / 60))
    }

    private var color: Color {
        if db > -1 { return Ink.bad }
        if db > -9 { return Ink.warm }
        return Ink.accent
    }

    var body: some View {
        HStack(spacing: 9) {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(Ink.dim).frame(width: 34, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.black.opacity(0.4))
                    RoundedRectangle(cornerRadius: 2).fill(color)
                        .frame(width: geo.size.width * normalized)
                }
            }
            .frame(height: 7)
            Text(db <= -119 ? " −∞ " : String(format: "%5.1f", db))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Ink.dim).frame(width: 48, alignment: .trailing)
        }
    }
}

/// Shows the audio currently unplayed in the DAC's buffer — the honest latency.
struct FillGauge: View {
    let fillMs: Double
    let bufferMs: Double

    private var fraction: Double {
        guard bufferMs > 0 else { return 0 }
        return max(0, min(1, fillMs / bufferMs))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("DAC BUFFER")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(Ink.dim).tracking(1.0)
                Spacer()
                Text(String(format: "%.1f / %.0f ms", fillMs, bufferMs))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Ink.dim)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.4))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(LinearGradient(colors: [Ink.accent, Ink.warm],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 10)
        }
    }
}

struct Readout: View {
    let label: String
    let value: String
    var warn: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(Ink.dim).tracking(0.8)
            Text(value)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(warn ? Ink.bad : Ink.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Settings

struct SettingsSheet: View {
    @EnvironmentObject var engine: Engine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Network settings").font(.headline)
            Form {
                TextField("Host", text: $engine.host, prompt: Text(PiDefaults.host))
                TextField("User", text: $engine.user, prompt: Text("up"))
                TextField("ALSA device", text: $engine.device,
                          prompt: Text(PiDefaults.device))
                TextField("SSH key", text: $engine.keyPath)
                TextField("Receiver", text: $engine.receiver, prompt: Text("aplay"))
            }
            Text("The key must already be in ~/.ssh/authorized_keys on the Pi:\n"
                 + "ssh-copy-id -i <key>.pub \(engine.user)@\(engine.host)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Ink.dim)
            Text("Receiver is `aplay` (stock) or a path on the Pi such as ~/hqdac,\n"
                 + "the fixed-buffer engine: it sets the device buffer exactly instead of\n"
                 + "letting aplay fill it, and 4 ms is the K11's floor. Install with\n"
                 + "receiver/install.sh.")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Ink.dim)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 460)
        .background(Ink.bg)
    }
}
