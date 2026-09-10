import SwiftUI

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var pomodoro = Pomodoro.shared
    @State private var panelWidth: CGFloat = 380

    var body: some View {
        HStack(spacing: 0) {
            PreviewView(markdown: state.markdown) { kind, payload in
                let text = payload["text"] as? String ?? ""
                switch kind {
                case "context":
                    state.attach(
                        context: text,
                        start: (payload["start"] as? NSNumber)?.intValue,
                        end: (payload["end"] as? NSNumber)?.intValue
                    )
                case "buffer": state.bufferChanged(text)
                case "save":   state.save()
                default:       break
                }
            }
            .frame(minWidth: 320)

            if state.chatVisible {
                Divider()
                ChatPanel()
                    .frame(width: panelWidth)
                    .transition(.move(edge: .trailing))
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Text((state.fileURL?.lastPathComponent ?? "No file open")
                     + (state.isDirty ? " •" : ""))
                    .foregroundStyle(.secondary)
            }
            ToolbarItem {
                Button {
                    state.toggleEditing()
                } label: {
                    Image(systemName: state.editing ? "eye" : "pencil")
                }
                .help(state.editing ? "Preview (⌘E)" : "Edit (⌘E)")
            }
            ToolbarItem { PomodoroToolbarItem() }
            ToolbarItem {
                Menu {
                    Picker("Model", selection: $state.provider) {
                        ForEach(Provider.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Button("API Keys & Models…") { state.showSettings = true }
                } label: {
                    Text(state.provider.displayName)
                        .foregroundStyle(state.apiKey.isEmpty ? .secondary : .primary)
                }
                .help(state.apiKey.isEmpty
                      ? "No API key for \(state.provider.displayName) yet (⌘,)"
                      : "Answering with \(state.modelID)")
            }
            ToolbarItem {
                Menu {
                    Picker("Appearance", selection: $state.appearance) {
                        ForEach(Appearance.allCases) { option in
                            Label(option.label, systemImage: option.icon).tag(option)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: state.appearance.icon)
                }
                .help("Appearance (⌘⇧D cycles)")
            }
            ToolbarItem {
                Button {
                    state.toggleChat()
                } label: {
                    Image(systemName: state.chatVisible
                          ? "sidebar.trailing"
                          : "bubble.left.and.text.bubble.right")
                }
                .help("Toggle chat (⌘J)")
            }
        }
        .sheet(isPresented: $state.showSettings) { SettingsSheet() }
        .sheet(isPresented: $pomodoro.showSettings) { PomodoroSettingsSheet() }
        .navigationTitle("MdChat")
        .onAppear { state.applyAppearance() }
    }
}

struct SettingsSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var editing: Provider = .gemini
    @State private var key = ""
    @State private var model = ""
    @State private var rateIn = ""
    @State private var rateOut = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Model provider").font(.headline)

            Picker("", selection: $editing) {
                ForEach(Provider.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: editing) { _ in load() }

            VStack(alignment: .leading, spacing: 4) {
                Text("API key").font(.subheadline).foregroundStyle(.secondary)
                SecureField(editing.keyPlaceholder, text: $key)
                    .textFieldStyle(.roundedBorder)
                Text("\(editing.keySource) · stored in your login Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Model ID").font(.subheadline).foregroundStyle(.secondary)
                TextField(editing.defaultModel, text: $model)
                    .textFieldStyle(.roundedBorder)
                Text(editing.modelHint)
                    .font(.caption).foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Price per 1M tokens").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Text(rateSource).font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    HStack(spacing: 4) {
                        Text("in").font(.caption).foregroundStyle(.secondary)
                        TextField(placeholderIn, text: $rateIn)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 78)
                    }
                    HStack(spacing: 4) {
                        Text("out").font(.caption).foregroundStyle(.secondary)
                        TextField(placeholderOut, text: $rateOut)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 78)
                    }
                    Spacer()
                    Text(lifetime).font(.caption).foregroundStyle(.secondary)
                    Button("Reset spend") { state.resetLifetime(for: editing) }
                        .font(.caption)
                }
                Text("Leave blank to use the built-in rate card. Fill in to override it.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Divider()

            Toggle("Use \(editing.displayName) for new messages", isOn: activeBinding)
                .toggleStyle(.checkbox)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    state.saveCredentials(for: editing, key: key, model: model)

                    let named = model.trimmingCharacters(in: .whitespaces)
                    let target = named.isEmpty ? editing.defaultModel : named
                    let typedIn = Double(rateIn.trimmingCharacters(in: .whitespaces))
                    let typedOut = Double(rateOut.trimmingCharacters(in: .whitespaces))

                    if typedIn == nil && typedOut == nil {
                        state.setRateOverride(nil, provider: editing, model: target)
                    } else {
                        state.setRateOverride(Rate(input: typedIn ?? 0, output: typedOut ?? 0),
                                              provider: editing, model: target)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            editing = state.provider
            load()
        }
    }

    /// Saving credentials and switching provider are separate acts; you can
    /// paste a key for the backend you aren't using yet.
    private var activeBinding: Binding<Bool> {
        Binding(
            get: { state.provider == editing },
            set: { on in if on { state.provider = editing } }
        )
    }

    private var resolvedModel: String {
        let named = model.trimmingCharacters(in: .whitespaces)
        return named.isEmpty ? editing.defaultModel : named
    }

    private var rateSource: String {
        switch Prices.source(provider: editing, model: resolvedModel) {
        case .custom:  return "custom rate"
        case .card:    return "rate card, \(Prices.cardDate)"
        case .unknown: return "no published rate for this model"
        }
    }

    private var placeholderIn: String {
        let rate = Prices.card(provider: editing, model: resolvedModel)
        return rate.map { String(format: "%g", $0.input) } ?? "0.00"
    }

    private var placeholderOut: String {
        let rate = Prices.card(provider: editing, model: resolvedModel)
        return rate.map { String(format: "%g", $0.output) } ?? "0.00"
    }

    private var lifetime: String {
        let spend = state.lifetimeCost[editing.rawValue] ?? 0
        let tokens = state.lifetimeTokens[editing.rawValue] ?? 0
        guard tokens > 0 else { return "no usage yet" }
        return "all time: \(Prices.money(spend)) · \(Prices.tokens(tokens)) tok"
    }

    private func load() {
        key = state.key(for: editing)
        model = state.modelIDs[editing.rawValue] ?? ""
        // Blank unless you've overridden: the placeholder shows the card rate.
        let custom = Prices.override(provider: editing, model: state.model(for: editing))
        rateIn = custom.map { String(format: "%g", $0.input) } ?? ""
        rateOut = custom.map { String(format: "%g", $0.output) } ?? ""
    }
}
