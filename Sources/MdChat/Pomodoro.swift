import AppKit
import SwiftUI

@MainActor
final class Pomodoro: ObservableObject {
    static let shared = Pomodoro()

    enum Phase: String {
        case focus, shortBreak, longBreak

        var label: String {
            switch self {
            case .focus: return "Focus"
            case .shortBreak: return "Break"
            case .longBreak: return "Long break"
            }
        }

        var icon: String {
            switch self {
            case .focus: return "timer"
            case .shortBreak, .longBreak: return "cup.and.saucer"
            }
        }
    }

    // MARK: - Published state

    @Published private(set) var phase: Phase = .focus
    @Published private(set) var remaining: TimeInterval = 25 * 60
    @Published private(set) var running = false
    /// Focus blocks finished since launch — drives the long-break cadence.
    @Published private(set) var completed = 0
    @Published var showSettings = false

    @Published var focusMinutes: Int { didSet { save("pomo.focus", focusMinutes); resyncIfIdle() } }
    @Published var shortMinutes: Int { didSet { save("pomo.short", shortMinutes); resyncIfIdle() } }
    @Published var longMinutes: Int { didSet { save("pomo.long", longMinutes); resyncIfIdle() } }
    @Published var cycles: Int { didSet { save("pomo.cycles", cycles) } }
    @Published var autoStart: Bool { didSet { save("pomo.autoStart", autoStart) } }
    @Published var focusSound: String { didSet { save("pomo.focusSound", focusSound) } }
    @Published var breakSound: String { didSet { save("pomo.breakSound", breakSound) } }

    /// Names that ship in /System/Library/Sounds, so no bundled assets.
    static let sounds = ["None", "Glass", "Ping", "Hero", "Submarine", "Bottle", "Blow", "Tink"]

    private var ticker: Timer?
    private var endDate: Date?

    private init() {
        let defaults = UserDefaults.standard
        focusMinutes = defaults.object(forKey: "pomo.focus") as? Int ?? 25
        shortMinutes = defaults.object(forKey: "pomo.short") as? Int ?? 5
        longMinutes = defaults.object(forKey: "pomo.long") as? Int ?? 15
        cycles = defaults.object(forKey: "pomo.cycles") as? Int ?? 4
        autoStart = defaults.object(forKey: "pomo.autoStart") as? Bool ?? true
        focusSound = defaults.string(forKey: "pomo.focusSound") ?? "Glass"
        breakSound = defaults.string(forKey: "pomo.breakSound") ?? "Ping"
        remaining = Double(focusMinutes) * 60
    }

    // MARK: - Display

    var timeString: String {
        let total = Int(remaining.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// 0...1 through the current phase, for the toolbar ring.
    var progress: Double {
        let full = duration(of: phase)
        guard full > 0 else { return 0 }
        return min(1, max(0, 1 - remaining / full))
    }

    var isIdleAtStart: Bool { !running && remaining == duration(of: phase) }

    // MARK: - Controls

    func toggle() { running ? pause() : start() }

    func start() {
        guard !running else { return }
        if remaining <= 0 { remaining = duration(of: phase) }
        endDate = Date().addingTimeInterval(remaining)
        running = true

        // Wall-clock target, not an accumulated count, so a busy main thread
        // or a missed tick can't make the timer drift.
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            Task { @MainActor in Pomodoro.shared.tick() }
        }
    }

    func pause() {
        guard running else { return }
        remaining = max(0, endDate?.timeIntervalSinceNow ?? remaining)
        running = false
        ticker?.invalidate()
        ticker = nil
        endDate = nil
    }

    func reset() {
        pause()
        remaining = duration(of: phase)
    }

    /// Manual skip: moves on without the chime, since you already know.
    func skip() {
        advance(announce: false)
    }

    func select(_ phase: Phase) {
        pause()
        self.phase = phase
        remaining = duration(of: phase)
    }

    // MARK: - Internals

    private func tick() {
        guard running, let endDate else { return }
        remaining = max(0, endDate.timeIntervalSinceNow)
        if remaining <= 0 { advance(announce: true) }
    }

    private func advance(announce: Bool) {
        pause()

        switch phase {
        case .focus:
            completed += 1
            phase = (cycles > 0 && completed % cycles == 0) ? .longBreak : .shortBreak
        case .shortBreak, .longBreak:
            phase = .focus
        }

        remaining = duration(of: phase)
        if announce { play(phase == .focus ? focusSound : breakSound) }
        if autoStart { start() }
    }

    private func duration(of phase: Phase) -> TimeInterval {
        switch phase {
        case .focus: return Double(focusMinutes) * 60
        case .shortBreak: return Double(shortMinutes) * 60
        case .longBreak: return Double(longMinutes) * 60
        }
    }

    /// Editing the current phase's length while it's paused should take effect.
    private func resyncIfIdle() {
        guard !running else { return }
        remaining = duration(of: phase)
    }

    func play(_ name: String) {
        guard name != "None", !name.isEmpty, let sound = NSSound(named: name) else { return }
        sound.stop()
        sound.play()
    }

    private func save(_ key: String, _ value: Any) {
        UserDefaults.standard.set(value, forKey: key)
    }
}

// MARK: - Toolbar

struct PomodoroToolbarItem: View {
    @ObservedObject var timer = Pomodoro.shared

    var body: some View {
        Menu {
            Button(timer.running ? "Pause" : "Start") { timer.toggle() }
            Button("Skip to \(next)") { timer.skip() }
            Button("Reset") { timer.reset() }
                .disabled(timer.isIdleAtStart)

            Divider()

            Picker("Phase", selection: phaseBinding) {
                Text("Focus").tag(Pomodoro.Phase.focus)
                Text("Break").tag(Pomodoro.Phase.shortBreak)
                Text("Long break").tag(Pomodoro.Phase.longBreak)
            }
            .pickerStyle(.inline)

            Divider()

            Toggle("Auto-start next phase", isOn: $timer.autoStart)
            Text("\(timer.completed) focus block\(timer.completed == 1 ? "" : "s") done")
            Button("Timer Settings…") { timer.showSettings = true }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: timer.phase.icon)
                Text(timer.timeString)
                    .monospacedDigit()
                    .foregroundStyle(timer.running ? .primary : .secondary)
            }
        }
        .help("\(timer.phase.label) · ⌘⇧Space starts and pauses")
    }

    private var next: String {
        timer.phase == .focus ? "break" : "focus"
    }

    private var phaseBinding: Binding<Pomodoro.Phase> {
        Binding(get: { timer.phase }, set: { timer.select($0) })
    }
}

// MARK: - Settings

struct PomodoroSettingsSheet: View {
    @ObservedObject var timer = Pomodoro.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pomodoro").font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Focus").foregroundStyle(.secondary)
                    Stepper("\(timer.focusMinutes) min", value: $timer.focusMinutes, in: 1...180)
                }
                GridRow {
                    Text("Break").foregroundStyle(.secondary)
                    Stepper("\(timer.shortMinutes) min", value: $timer.shortMinutes, in: 1...60)
                }
                GridRow {
                    Text("Long break").foregroundStyle(.secondary)
                    Stepper("\(timer.longMinutes) min", value: $timer.longMinutes, in: 1...120)
                }
                GridRow {
                    Text("Long break every").foregroundStyle(.secondary)
                    Stepper("\(timer.cycles) focus blocks", value: $timer.cycles, in: 1...12)
                }
            }
            .font(.subheadline)

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Focus sound").foregroundStyle(.secondary)
                    soundPicker($timer.focusSound)
                }
                GridRow {
                    Text("Break sound").foregroundStyle(.secondary)
                    soundPicker($timer.breakSound)
                }
            }
            .font(.subheadline)

            Text("Plays when that phase begins. System sounds, nothing bundled.")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    @ViewBuilder
    private func soundPicker(_ selection: Binding<String>) -> some View {
        HStack(spacing: 6) {
            Picker("", selection: selection) {
                ForEach(Pomodoro.sounds, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(width: 130)

            Button {
                timer.play(selection.wrappedValue)
            } label: {
                Image(systemName: "play.circle")
            }
            .buttonStyle(.plain)
            .disabled(selection.wrappedValue == "None")
            .help("Preview")
        }
    }
}
