import AppKit
import AVFoundation
import ServiceManagement
import SwiftUI

/// Every user setting and its default. Read through UserDefaults everywhere else.
let settingDefaults: [String: Any] = [
    "switchDelay": 300.0, "headTurn": 50.0, "paneFocus": true, "paneDelay": 300.0, "edgeMargin": 120.0, "clickFallback": true,
    "waitTyping": true, "typingPause": 2.0, "learnClicks": true, "showDot": false, "smoothing": 10.0, "camera": "", "camera2": "",
]

struct SettingsView: View {
    @AppStorage("switchDelay") private var switchDelay = 300.0
    @AppStorage("headTurn") private var headTurn = 50.0
    @AppStorage("paneFocus") private var paneFocus = true
    @AppStorage("paneDelay") private var paneDelay = 300.0
    @AppStorage("edgeMargin") private var edgeMargin = 120.0
    @AppStorage("clickFallback") private var clickFallback = true
    @AppStorage("waitTyping") private var waitTyping = true
    @AppStorage("typingPause") private var typingPause = 2.0
    @AppStorage("learnClicks") private var learnClicks = true
    @AppStorage("showDot") private var showDot = false
    @AppStorage("smoothing") private var smoothing = 10.0
    @AppStorage("camera") private var camera = ""
    @AppStorage("camera2") private var camera2 = ""
    @State private var startAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Screens") {
                slider("Delay before switching", "How long you must face another screen before focus moves there. Higher = fewer accidental switches from quick glances.",
                       $switchDelay, 100...1000, step: 50, "\(Int(switchDelay)) ms")
                slider("Head turn needed", "How far you turn your head toward the other screen before it takes over. 50% = halfway between the screens' centres.",
                       $headTurn, 30...80, step: 5, "\(Int(headTurn))%")
            }
            Section("Gaze") {
                slider("Smoothing", "How many recent gaze estimates are averaged. Higher = steadier dot and fewer jittery switches, but it lags a little behind your eyes.",
                       $smoothing, 1...20, step: 1, "\(Int(smoothing))")
            }
            Section("Windows and panes") {
                toggle("Focus the window or pane I look at", "Within one screen, move focus to the window — or split pane in supported editors and terminals — you're looking at.",
                       $paneFocus)
                slider("Delay for panes", "How long your gaze must rest on another window or pane before it gets focus.",
                       $paneDelay, 100...1000, step: 50, "\(Int(paneDelay)) ms").disabled(!paneFocus)
                slider("Edge margin", "How far past the focused window's or pane's edge you must look before the next one takes focus. Stops reading near an edge from switching.",
                       $edgeMargin, 0...300, step: 20, "\(Int(edgeMargin)) pt").disabled(!paneFocus)
                toggle("Click into panes that refuse focus", "Some terminals and editors only change pane on a real click. Eyeshift clicks the middle of the pane — never in another app.",
                       $clickFallback).disabled(!paneFocus)
            }
            Section("Typing") {
                toggle("Wait while I'm typing", "Don't move focus while you type, so a glance elsewhere never steals your keystrokes.", $waitTyping)
                slider("Typing pause", "How long after your last keystroke windows and panes stay locked. Screens can still switch after a short pause.",
                       $typingPause, 0.5...5, step: 0.5, String(format: "%.1f s", typingPause)).disabled(!waitTyping)
            }
            Section("Camera") {
                Picker(selection: $camera) {
                    Text("Automatic (external first)").tag("")
                    ForEach(Tracker.cameras(), id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                } label: {
                    Text("Camera")
                    Text("The camera that watches your face. Automatic picks a plugged-in webcam, otherwise the built-in one.")
                }
                Picker(selection: $camera2) {
                    Text("None").tag("")
                    ForEach(Tracker.cameras(), id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                } label: {
                    Text("Second camera (optional)")
                    Text("Put it on your other screen: Eyeshift trusts whichever camera you're facing. Recalibrate after changing cameras.")
                }
            }
            Section("General") {
                toggle("Learn from my clicks, typing and corrections", "Keeps improving as you work: clicks, the text cursor while you type, and clicking away right after a wrong switch all teach it.",
                       $learnClicks)
                toggle("Show gaze dot", "A red dot where Eyeshift thinks you're looking. Handy for checking accuracy.", $showDot)
                toggle("Start at login", "Open Eyeshift automatically when you log in.", $startAtLogin)
                    .onChange(of: startAtLogin) { _, on in
                        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                        catch { loginError = error.localizedDescription }
                    }
                if let loginError { Text(loginError).foregroundStyle(.red).font(.caption) }
                LabeledContent {
                    Text("⇧⌘G")
                } label: {
                    Text("Pause / resume")
                    Text("Stops all focus changes until you press it again. Also in the menu bar.")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize()
    }

    /// Title with a grey explanation line under it (grouped forms show the second Text as a subtitle).
    private func toggle(_ title: String, _ help: String, _ value: Binding<Bool>) -> some View {
        Toggle(isOn: value) {
            Text(title)
            Text(help)
        }
    }

    private func slider(_ title: String, _ help: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, step: Double, _ label: String) -> some View {
        LabeledContent {
            Slider(value: value, in: range, step: step).frame(width: 180)
            Text(label).monospacedDigit().frame(width: 60, alignment: .trailing)
        } label: {
            Text(title)
            Text(help)
        }
    }
}

struct WelcomeView: View {
    let calibrate: () -> Void
    @State private var camera = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var trusted = AXIsProcessTrusted()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Welcome to Eyeshift").font(.largeTitle.bold())
            Text("Eyeshift moves keyboard focus to the screen, window or split pane you're looking at, so you can just start typing.")
                .foregroundStyle(.secondary)
            step(1, "Allow the camera", "Frames are read in memory and never saved.", done: camera == .authorized) {
                if camera == .notDetermined { AVCaptureDevice.requestAccess(for: .video) { _ in } } else { open("Privacy_Camera") }
            }
            step(2, "Allow Accessibility", "Needed to raise the window you look at and move the pointer.", done: trusted) {
                open("Privacy_Accessibility")
            }
            step(3, "Calibrate each screen", "Follow a dot around each screen — about 30 seconds per screen.", done: GazeModel.load() != nil, action: calibrate)
            step(4, "Start using it", "Turn toward a screen or look at a pane, then type. Pause any time with ⇧⌘G.", done: false, action: nil)
        }
        .padding(28)
        .frame(width: 520)
        .onReceive(tick) { _ in
            camera = AVCaptureDevice.authorizationStatus(for: .video)
            trusted = AXIsProcessTrusted()
        }
    }

    private func step(_ n: Int, _ title: String, _ detail: String, done: Bool, action: (() -> Void)?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(n).circle").font(.title2).foregroundStyle(done ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary)
            }
            Spacer()
            if let action, !done { Button(n == 3 ? "Calibrate" : "Open", action: action) }
        }
    }

    private func open(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
}

/// Shows a SwiftUI view in a normal titled window, reusing it if already open.
func showWindow<V: View>(_ existing: inout NSWindow?, _ title: String, _ view: V) {
    if existing == nil {
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.title = title
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        existing = w
    }
    NSApp.activate(ignoringOtherApps: true)
    existing?.center()
    existing?.makeKeyAndOrderFront(nil)
}
