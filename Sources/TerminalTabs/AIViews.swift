import AppKit
import SwiftUI

// MARK: - Response segment parsing

private enum AIResponseSegment: Equatable {
    case text(String)
    case code(language: String?, body: String)

    static func parse(_ raw: String) -> [AIResponseSegment] {
        var segments: [AIResponseSegment] = []
        var remaining = raw

        while !remaining.isEmpty {
            guard let fenceRange = remaining.range(of: "```") else {
                segments.append(.text(remaining))
                break
            }
            let before = String(remaining[..<fenceRange.lowerBound])
            if !before.isEmpty { segments.append(.text(before)) }
            remaining = String(remaining[fenceRange.upperBound...])

            // Extract optional language tag on the same line as opening fence
            let langEnd = remaining.firstIndex(of: "\n") ?? remaining.endIndex
            let lang = String(remaining[..<langEnd]).trimmingCharacters(in: .whitespaces)
            remaining = langEnd < remaining.endIndex
                ? String(remaining[remaining.index(after: langEnd)...])
                : ""

            // Find closing fence
            if let closeRange = remaining.range(of: "```") {
                let body = String(remaining[..<closeRange.lowerBound])
                    .trimmingCharacters(in: .newlines)
                segments.append(.code(language: lang.isEmpty ? nil : lang, body: body))
                remaining = String(remaining[closeRange.upperBound...])
                if remaining.hasPrefix("\n") { remaining = String(remaining.dropFirst()) }
            } else {
                segments.append(.text(remaining))
                remaining = ""
            }
        }

        return segments.filter {
            if case .text(let t) = $0 { return !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return true
        }
    }
}

// MARK: - Code block view

struct AICodeBlockView: View {
    let language: String?
    let code: String
    let runCommand: ((String) -> Void)?

    @State private var copied = false

    private var isShell: Bool {
        ["bash", "sh", "zsh", "shell", "fish", ""].contains((language ?? "").lowercased())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header bar
            HStack(spacing: 6) {
                Text(language ?? "shell")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(TerminalTheme.cyanMuted)
                Spacer()
                Button(copied ? "Copied" : "Copy",
                       systemImage: copied ? "checkmark" : "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copied = false
                    }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.toolbarIcon)
                .help("Copy to clipboard")

                if isShell, let runCommand {
                    Button("Run", systemImage: "play.fill") {
                        runCommand(code)
                    }
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(TerminalTheme.cyan.opacity(0.18), in: .rect(cornerRadius: 5))
                    .overlay {
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(TerminalTheme.cyan.opacity(0.4), lineWidth: 1)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(TerminalTheme.cyan)
                    .help("Run in terminal")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.22))

            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(TerminalTheme.text)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(TerminalTheme.canvas)
        .clipShape(.rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.white.opacity(0.09), lineWidth: 1)
        }
    }
}

// MARK: - Message view

private struct AIMessageView: View {
    let message: AIChatMessage
    let runCommand: ((String) -> Void)?

    var body: some View {
        if message.role == .user {
            userBubble
        } else {
            assistantBubble
        }
    }

    // Right-aligned tinted bubble for user turns
    private var userBubble: some View {
        HStack(alignment: .top, spacing: 0) {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 6) {
                ForEach(message.attachments) { attachment in
                    AIAttachmentChip(attachment: attachment)
                }
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                        .foregroundStyle(TerminalTheme.text)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .background(TerminalTheme.cyan.opacity(0.14), in: .rect(cornerRadius: 10))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(TerminalTheme.cyan.opacity(0.26), lineWidth: 1)
                        }
                }
            }
        }
    }

    // Full-width markdown-parsed response for assistant turns
    private var assistantBubble: some View {
        let segments = AIResponseSegment.parse(message.text)
        return VStack(alignment: .leading, spacing: 10) {
            Label("AI", systemImage: "sparkles")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(TerminalTheme.cyanMuted)

            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let txt):
                    Text(txt.trimmingCharacters(in: .newlines))
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                        .foregroundStyle(TerminalTheme.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .code(let lang, let body):
                    AICodeBlockView(language: lang, code: body, runCommand: runCommand)
                }
            }
        }
        .padding(11)
        .background(Color.white.opacity(0.035), in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(.white.opacity(0.07), lineWidth: 1)
        }
    }
}

// MARK: - Conversation panel

struct AIConversationPanel: View {
    @ObservedObject var session: TerminalSession
    @ObservedObject var settings: AISettings
    @State private var isDropTargeted = false

    private var runCommand: (String) -> Void {
        { code in
            let trimmed = code.trimmingCharacters(in: .newlines)
            let lines = trimmed.components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if lines.count == 1 {
                session.rerunBlockCommand(lines[0])
            } else {
                session.paste(trimmed)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(TerminalTheme.cyan)
                Text("AI").font(.system(size: 12, weight: .semibold))
                AirMenuPicker(
                    "Provider",
                    selection: $settings.provider,
                    options: AIProvider.allCases,
                    minimumWidth: 110,
                    optionTitle: { $0.title }
                )
                Text(settings.connectionMode(for: settings.provider) == .signIn
                     ? "Account"
                     : settings.selectedModel)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer()
                Button("Clear", systemImage: "trash", action: session.clearAIConversation)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.toolbarIcon)
                    .help("Clear conversation")
                Button("Close", systemImage: "xmark") { session.isAIChatVisible = false }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.toolbarIcon)
                    .help("Close AI chat")
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: 36)

            // Current directory context strip
            HStack(spacing: 5) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 9))
                Text(session.workingDirectory)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(TerminalTheme.cyanMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.bottom, 6)

            Divider().opacity(0.3)

            // Message list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if session.aiMessages.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 24))
                                    .foregroundStyle(TerminalTheme.cyanMuted)
                                Text("Ask about a command, an error, or what to do next.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.tertiary)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                        }
                        ForEach(session.aiMessages) { message in
                            AIMessageView(message: message, runCommand: runCommand)
                                .id(message.id)
                        }
                        if session.isAIResponding {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Thinking…").font(.system(size: 11)).foregroundStyle(.secondary)
                                Spacer()
                                Button("Stop", systemImage: "stop.fill") {
                                    session.cancelAIMessage()
                                }
                                .labelStyle(.titleAndIcon)
                                .font(.system(size: 10, weight: .medium))
                                .buttonStyle(.plain)
                                .foregroundStyle(TerminalTheme.cyanMuted)
                                .help("Stop generating")
                            }
                            .padding(.top, 4)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: session.aiMessages.count) {
                    if let last = session.aiMessages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                .onChange(of: session.isAIResponding) {
                    if let last = session.aiMessages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            if let error = session.aiError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(error).foregroundStyle(.red)
                }
                .font(.system(size: 10))
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
                .padding(.bottom, 4)
            }

            Divider().opacity(0.3)

            // Input bar
            HStack(alignment: .bottom, spacing: 8) {
                TextField(
                    "Ask anything about the terminal…",
                    text: $session.aiDraft,
                    axis: .vertical
                )
                .font(.system(size: 12))
                .lineLimit(2...6)
                .textFieldStyle(.plain)
                .padding(9)
                .background(
                    isDropTargeted ? TerminalTheme.cyan.opacity(0.12) : Color.black.opacity(0.18),
                    in: .rect(cornerRadius: 8)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isDropTargeted ? TerminalTheme.cyan : Color.white.opacity(0.08), lineWidth: 1)
                }
                .onSubmit { session.sendAIMessage(using: settings) }

                Button {
                    session.sendAIMessage(using: settings)
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    (session.aiDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && session.aiAttachments.isEmpty)
                        || session.isAIResponding
                )
                .keyboardShortcut(.return, modifiers: .shift)
                .help("Send (Return · Shift-Return for new line)")
            }
            .padding(10)
        }
        .frame(minHeight: 200, idealHeight: 300)
        .background(TerminalTheme.surface)
        .clipShape(.rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isDropTargeted ? TerminalTheme.cyan.opacity(0.8) : Color.white.opacity(0.1), lineWidth: 1)
        }
        .dropDestination(for: URL.self) { urls, _ in
            session.attachFilesToAI(urls)
        } isTargeted: { isDropTargeted = $0 }
    }
}

// MARK: - Settings

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
                            Toggle(
                                "Show \(store.tabOrientation.panelName)",
                                isOn: $store.isTabBarVisible
                            )
                            Toggle("Autocolor tabs", isOn: $store.autocolorTabs)
                        }
                        .padding(8)
                    }

                    PredictiveTypingSettingsSection(store: store)

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

                    GroupBox("File preview") {
                        VStack(alignment: .leading, spacing: 8) {
                            LabeledContent("Opacity") {
                                HStack(spacing: 8) {
                                    Slider(
                                        value: $store.graphicalPreviewOpacity,
                                        in: 0.4...1.0,
                                        step: 0.05
                                    )
                                    .frame(width: 130)
                                    Text("\(Int(store.graphicalPreviewOpacity * 100))%")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 36, alignment: .trailing)
                                }
                            }
                            Text("Opacity of the preview pane when shown over the file listing.")
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
