import SwiftUI

struct AIConversationPanel: View {
    @ObservedObject var session: TerminalSession
    @ObservedObject var settings: AISettings

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                Text("Terminal AI").font(.system(size: 12, weight: .semibold))
                Picker("Provider", selection: $settings.provider) {
                    ForEach(AIProvider.allCases) { provider in
                        Text(provider.title).tag(provider)
                    }
                }
                .labelsHidden()
                .frame(width: 110)
                Text(settings.connectionMode(for: settings.provider) == .signIn
                     ? "Account login"
                     : settings.selectedModel)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer()
                Button { session.clearAIConversation() } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .help("Clear conversation")
                Button { session.isAIChatVisible = false } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("Close AI chat")
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: 34)

            Divider().opacity(0.35)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if session.aiMessages.isEmpty {
                            Text("Ask about a command, an error, or what to do next.")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 16)
                        }
                        ForEach(session.aiMessages) { message in
                            AIMessageView(message: message)
                                .id(message.id)
                        }
                        if session.isAIResponding {
                            HStack(spacing: 7) {
                                ProgressView().controlSize(.small)
                                Text("Thinking…")
                            }
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: session.aiMessages.count) {
                    if let last = session.aiMessages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }

            if let error = session.aiError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 5)
            }

            if let attachment = session.aiAttachment {
                HStack(spacing: 8) {
                    Image(systemName: "terminal")
                    VStack(alignment: .leading, spacing: 1) {
                        Text(attachment.command).lineLimit(1)
                        Text("\(attachment.output.count) characters of output")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button { session.aiAttachment = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                }
                .font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 10)
                .frame(height: 38)
                .background(Color.white.opacity(0.045))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextEditor(text: $session.aiDraft)
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 38, maxHeight: 68)
                    .padding(4)
                    .background(Color.black.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                Button {
                    session.sendAIMessage(using: settings)
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderedProminent)
                .disabled(session.aiDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.isAIResponding)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Send (Command-Return)")
            }
            .padding(10)
        }
        .frame(minHeight: 180, idealHeight: 250, maxHeight: 310)
        .background(TerminalTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        }
    }
}

private struct AIMessageView: View {
    let message: AIChatMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message.role == .user ? "You" : "AI")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            if let attachment = message.attachment {
                Label(attachment.command, systemImage: "terminal")
                    .font(.system(size: 10, design: .monospaced))
                    .lineLimit(1)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            Text(message.text)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(9)
        .background(message.role == .user ? Color.accentColor.opacity(0.12) : Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

struct AppSettingsView: View {
    @ObservedObject var store: TerminalStore
    @ObservedObject var settings: AISettings
    @Environment(\.dismiss) private var dismiss
    @State private var openAIKey = ""
    @State private var anthropicKey = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Settings").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    GroupBox("Tabs") {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("Orientation", selection: $store.tabOrientation) {
                                Text("Horizontal").tag(TabOrientation.horizontal)
                                Text("Vertical").tag(TabOrientation.vertical)
                            }
                            .pickerStyle(.segmented)
                            Toggle(
                                "Show \(store.tabOrientation.panelName)",
                                isOn: $store.isTabBarVisible
                            )
                            Toggle("Autocolor tabs", isOn: $store.autocolorTabs)
                        }
                        .padding(8)
                    }

                    GroupBox("Directory listings") {
                        VStack(alignment: .leading, spacing: 8) {
                            Picker("Backend", selection: $store.listingBackend) {
                                ForEach(ListingBackend.allCases) { backend in
                                    Text(backend.title).tag(backend)
                                }
                            }
                            .pickerStyle(.segmented)
                            Text(store.listingBackend.detail)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .padding(8)
                    }

                    GroupBox("AI connections") {
                        VStack(spacing: 14) {
                            credentialRow(
                                provider: .openAI,
                                connected: settings.openAIConnected,
                                loggedIn: settings.openAILoggedIn,
                                connectionMode: $settings.openAIConnectionMode,
                                key: $openAIKey,
                                model: $settings.openAIModel,
                                placeholder: "OpenAI API key"
                            )
                            Divider()
                            credentialRow(
                                provider: .anthropic,
                                connected: settings.anthropicConnected,
                                loggedIn: settings.anthropicLoggedIn,
                                connectionMode: $settings.anthropicConnectionMode,
                                key: $anthropicKey,
                                model: $settings.anthropicModel,
                                placeholder: "Anthropic API key"
                            )
                        }
                        .padding(8)
                    }

                    Text("Sign-in mode uses the official Codex or Claude Code login and its eligible subscription. API-key mode is billed separately, with keys stored in macOS Keychain.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    if let error { Text(error).font(.system(size: 10)).foregroundStyle(.red) }
                    if let message = settings.loginStatusMessage {
                        Text(message).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(22)
        .frame(width: 500, height: 560)
        .background(TerminalTheme.backdrop)
        .task { await settings.refreshLoginStatus() }
    }

    @ViewBuilder
    private func credentialRow(
        provider: AIProvider,
        connected: Bool,
        loggedIn: Bool,
        connectionMode: Binding<AIConnectionMode>,
        key: Binding<String>,
        model: Binding<String>,
        placeholder: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(provider.title).font(.headline)
                Text(connectionMode.wrappedValue == .signIn
                     ? (loggedIn ? "Signed in" : "Not signed in")
                     : (connected ? "Connected" : "Not connected"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle((connectionMode.wrappedValue == .signIn ? loggedIn : connected) ? .green : .secondary)
                Spacer()
                if connectionMode.wrappedValue == .apiKey, connected {
                    Button("Disconnect", role: .destructive) { settings.disconnect(provider) }
                }
            }
            Picker("Connection", selection: connectionMode) {
                Text("Sign in").tag(AIConnectionMode.signIn)
                Text("API key").tag(AIConnectionMode.apiKey)
            }
            .pickerStyle(.segmented)

            if connectionMode.wrappedValue == .signIn {
                HStack {
                    Text("Uses the official \(provider == .openAI ? "Codex" : "Claude Code") CLI login.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Refresh") { Task { await settings.refreshLoginStatus() } }
                    Button(loggedIn ? "Sign In Again" : "Sign In") { settings.startLogin(provider) }
                }
            } else {
                SecureField(connected ? "Enter a new key to replace the saved key" : placeholder, text: key)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Text("Model")
                    TextField("Model identifier", text: model).textFieldStyle(.roundedBorder)
                    Button(connected ? "Update Key" : "Connect") {
                        do {
                            try settings.connect(provider, apiKey: key.wrappedValue)
                            key.wrappedValue = ""
                            error = nil
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                    .disabled(key.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
