import SwiftUI

struct AIConversationPanel: View {
    @ObservedObject var session: TerminalSession
    @ObservedObject var settings: AISettings
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                Text("Terminal AI").font(.system(size: 12, weight: .semibold))
                AirMenuPicker(
                    "Provider",
                    selection: $settings.provider,
                    options: AIProvider.allCases,
                    minimumWidth: 110,
                    optionTitle: { $0.title }
                )
                Text(settings.connectionMode(for: settings.provider) == .signIn
                     ? "Account login"
                     : settings.selectedModel)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer()
                Button("Clear conversation", systemImage: "trash", action: session.clearAIConversation)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .help("Clear conversation")
                Button("Close AI chat", systemImage: "xmark") { session.isAIChatVisible = false }
                .labelStyle(.iconOnly)
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

            if !session.aiAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 7) {
                        ForEach(session.aiAttachments) { attachment in
                            AIAttachmentChip(attachment: attachment) {
                                session.removeAIAttachment(attachment.id)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                }
                .frame(height: 42)
                .padding(.bottom, 6)
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask about the terminal, or drop files and folders here", text: $session.aiDraft, axis: .vertical)
                    .font(.system(size: 12))
                    .lineLimit(2...5)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(isDropTargeted ? TerminalTheme.cyan.opacity(0.12) : Color.black.opacity(0.2))
                    .clipShape(.rect(cornerRadius: 7))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(isDropTargeted ? TerminalTheme.cyan : Color.clear, lineWidth: 1)
                    }
                Button("Send", systemImage: "arrow.up") { session.sendAIMessage(using: settings) }
                .labelStyle(.iconOnly)
                .font(.system(size: 12, weight: .bold))
                .frame(width: 28, height: 28)
                .buttonStyle(.borderedProminent)
                .disabled(
                    session.aiDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && session.aiAttachments.isEmpty
                        || session.isAIResponding
                )
                .keyboardShortcut(.return, modifiers: .command)
                .help("Send (Command-Return)")
            }
            .padding(10)
        }
        .frame(minHeight: 180, idealHeight: 250)
        .background(TerminalTheme.surface)
        .clipShape(.rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isDropTargeted ? TerminalTheme.cyan.opacity(0.8) : Color.white.opacity(0.1), lineWidth: 1)
        }
        .dropDestination(for: URL.self) { urls, _ in
            session.attachFilesToAI(urls)
        } isTargeted: { isDropTargeted = $0 }
    }
}

private struct AIMessageView: View {
    let message: AIChatMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message.role == .user ? "You" : "AI")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(message.attachments) { attachment in
                AIAttachmentChip(attachment: attachment)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                Button("Done") { dismiss() }
                    .buttonStyle(.airPrimary)
                    .keyboardShortcut(.defaultAction)
                    .help("Close Settings")
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    GroupBox("Tabs") {
                        VStack(alignment: .leading, spacing: 10) {
                            LabeledContent("Orientation") {
                                AirMenuPicker(
                                    "Orientation",
                                    selection: $store.tabOrientation,
                                    options: TabOrientation.allCases,
                                    minimumWidth: 150,
                                    optionTitle: { $0.title }
                                )
                            }
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
                            LabeledContent("Backend") {
                                AirMenuPicker(
                                    "Directory listing backend",
                                    selection: $store.listingBackend,
                                    options: ListingBackend.allCases,
                                    minimumWidth: 150,
                                    optionTitle: { $0.title }
                                )
                            }
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
                        .buttonStyle(.airDestructive)
                        .help("Remove the saved \(provider.title) API key")
                }
            }
            LabeledContent("Connection") {
                AirMenuPicker(
                    "Connection",
                    selection: connectionMode,
                    options: AIConnectionMode.allCases,
                    minimumWidth: 150,
                    optionTitle: { $0.title }
                )
            }

            if connectionMode.wrappedValue == .signIn {
                HStack {
                    Text("Uses the official \(provider == .openAI ? "Codex" : "Claude Code") CLI login.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Refresh") { Task { await settings.refreshLoginStatus() } }
                        .buttonStyle(.airSecondary)
                        .help("Refresh \(provider.title) sign-in status")
                    Button(loggedIn ? "Sign In Again" : "Sign In") { settings.startLogin(provider) }
                        .buttonStyle(.airPrimary)
                        .help(loggedIn
                              ? "Sign in to \(provider.title) again"
                              : "Sign in to \(provider.title)")
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
                    .buttonStyle(.airPrimary)
                    .disabled(key.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help(connected
                          ? "Replace the saved \(provider.title) API key"
                          : "Connect \(provider.title) with this API key")
                }
            }
        }
    }
}
