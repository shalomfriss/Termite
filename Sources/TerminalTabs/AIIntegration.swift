import Foundation
import Security

enum AIProvider: String, CaseIterable, Identifiable, Sendable {
    case openAI
    case anthropic

    var id: String { rawValue }
    var title: String { self == .openAI ? "ChatGPT" : "Claude" }
    var keyAccount: String { self == .openAI ? "openai-api-key" : "anthropic-api-key" }
}

enum AIConnectionMode: String, CaseIterable, Sendable {
    case signIn
    case apiKey
}

struct TerminalBlockAttachment: Equatable, Sendable {
    let command: String
    let output: String
    let workingDirectory: String

    var promptContent: String {
        """
        <terminal_block>
        <working_directory>\(workingDirectory)</working_directory>
        <command>\(command)</command>
        <output>
        \(output)
        </output>
        </terminal_block>
        """
    }
}

struct AIChatMessage: Identifiable, Equatable, Sendable {
    enum Role: String, Sendable { case user, assistant }
    let id: UUID
    let role: Role
    let text: String
    let attachment: TerminalBlockAttachment?

    init(id: UUID = UUID(), role: Role, text: String, attachment: TerminalBlockAttachment? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.attachment = attachment
    }

    var requestContent: String {
        guard let attachment else { return text }
        return text + "\n\n" + attachment.promptContent
    }
}

enum KeychainStore {
    private static let service = "com.terminaltabs.ai"

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String, account: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

@MainActor
final class AISettings: ObservableObject {
    private static let providerKey = "aiProvider"
    private static let openAIModelKey = "openAIModel"
    private static let anthropicModelKey = "anthropicModel"
    private static let openAIModeKey = "openAIConnectionMode"
    private static let anthropicModeKey = "anthropicConnectionMode"

    @Published var provider: AIProvider {
        didSet { UserDefaults.standard.set(provider.rawValue, forKey: Self.providerKey) }
    }
    @Published var openAIModel: String {
        didSet { UserDefaults.standard.set(openAIModel, forKey: Self.openAIModelKey) }
    }
    @Published var anthropicModel: String {
        didSet { UserDefaults.standard.set(anthropicModel, forKey: Self.anthropicModelKey) }
    }
    @Published private(set) var openAIConnected = false
    @Published private(set) var anthropicConnected = false
    @Published var openAIConnectionMode: AIConnectionMode {
        didSet { UserDefaults.standard.set(openAIConnectionMode.rawValue, forKey: Self.openAIModeKey) }
    }
    @Published var anthropicConnectionMode: AIConnectionMode {
        didSet { UserDefaults.standard.set(anthropicConnectionMode.rawValue, forKey: Self.anthropicModeKey) }
    }
    @Published private(set) var openAILoggedIn = false
    @Published private(set) var anthropicLoggedIn = false
    @Published var loginStatusMessage: String?

    init() {
        provider = AIProvider(rawValue: UserDefaults.standard.string(forKey: Self.providerKey) ?? "") ?? .openAI
        openAIModel = UserDefaults.standard.string(forKey: Self.openAIModelKey) ?? "chat-latest"
        anthropicModel = UserDefaults.standard.string(forKey: Self.anthropicModelKey) ?? "claude-sonnet-5"
        openAIConnectionMode = AIConnectionMode(
            rawValue: UserDefaults.standard.string(forKey: Self.openAIModeKey) ?? ""
        ) ?? .signIn
        anthropicConnectionMode = AIConnectionMode(
            rawValue: UserDefaults.standard.string(forKey: Self.anthropicModeKey) ?? ""
        ) ?? .signIn
        refreshConnectionState()
        Task { await refreshLoginStatus() }
    }

    var selectedModel: String { provider == .openAI ? openAIModel : anthropicModel }

    func connectionMode(for provider: AIProvider) -> AIConnectionMode {
        provider == .openAI ? openAIConnectionMode : anthropicConnectionMode
    }

    func isLoggedIn(to provider: AIProvider) -> Bool {
        provider == .openAI ? openAILoggedIn : anthropicLoggedIn
    }

    func apiKey(for provider: AIProvider) -> String? {
        KeychainStore.read(account: provider.keyAccount)
    }

    func connect(_ provider: AIProvider, apiKey: String) throws {
        let cleaned = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        try KeychainStore.save(cleaned, account: provider.keyAccount)
        refreshConnectionState()
    }

    func disconnect(_ provider: AIProvider) {
        KeychainStore.delete(account: provider.keyAccount)
        refreshConnectionState()
    }

    func startLogin(_ provider: AIProvider) {
        loginStatusMessage = "Opening \(provider.title) sign-in…"
        Task {
            do {
                try await CLIRunner.shared.startLogin(provider)
                loginStatusMessage = "Complete sign-in in your browser, then click Refresh."
            } catch {
                loginStatusMessage = error.localizedDescription
            }
        }
    }

    func refreshLoginStatus() async {
        // CLIRunner is an actor, so these checks are serialized either way. Update each
        // provider as soon as its own CLI responds instead of waiting for both clients.
        anthropicLoggedIn = await CLIRunner.shared.isLoggedIn(.anthropic)
        openAILoggedIn = await CLIRunner.shared.isLoggedIn(.openAI)
    }

    private func refreshConnectionState() {
        openAIConnected = KeychainStore.read(account: AIProvider.openAI.keyAccount) != nil
        anthropicConnected = KeychainStore.read(account: AIProvider.anthropic.keyAccount) != nil
    }
}

enum AIClient {
    static func send(
        provider: AIProvider,
        connectionMode: AIConnectionMode,
        model: String,
        apiKey: String,
        messages: [AIChatMessage],
        workingDirectory: String
    ) async throws -> String {
        if connectionMode == .signIn {
            return try await CLIRunner.shared.ask(
                provider,
                messages: messages,
                workingDirectory: workingDirectory
            )
        }
        switch provider {
        case .openAI:
            return try await sendOpenAI(model: model, apiKey: apiKey, messages: messages)
        case .anthropic:
            return try await sendAnthropic(model: model, apiKey: apiKey, messages: messages)
        }
    }

    private static func sendOpenAI(model: String, apiKey: String, messages: [AIChatMessage]) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "input": messages.map { ["role": $0.role.rawValue, "content": $0.requestContent] },
        ])
        let data = try await perform(request)
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let output = root?["output"] as? [[String: Any]] ?? []
        let text = output.flatMap { $0["content"] as? [[String: Any]] ?? [] }
            .compactMap { $0["text"] as? String }.joined(separator: "\n")
        guard !text.isEmpty else { throw AIError.invalidResponse }
        return text
    }

    private static func sendAnthropic(model: String, apiKey: String, messages: [AIChatMessage]) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": 4096,
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.requestContent] },
        ])
        let data = try await perform(request)
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let content = root?["content"] as? [[String: Any]] ?? []
        let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        guard !text.isEmpty else { throw AIError.invalidResponse }
        return text
    }

    private static func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let error = root?["error"] as? [String: Any]
            throw AIError.api(error?["message"] as? String ?? "Request failed with status \(http.statusCode).")
        }
        return data
    }
}

actor CLIRunner {
    static let shared = CLIRunner()
    private var loginProcesses: [AIProvider: Process] = [:]

    func startLogin(_ provider: AIProvider) async throws {
        guard let executable = executable(for: provider) else {
            throw AIError.api("Install the official \(provider == .openAI ? "Codex" : "Claude Code") CLI first.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = provider == .openAI ? ["login"] : ["auth", "login"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        try process.run()
        loginProcesses[provider] = process
        try await Task.sleep(for: .milliseconds(350))
        if !process.isRunning && process.terminationStatus != 0 {
            let detail = String(
                decoding: output.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            throw AIError.api(detail.isEmpty ? "The login command failed to start." : detail)
        }
    }

    func isLoggedIn(_ provider: AIProvider) -> Bool {
        guard let executable = executable(for: provider) else { return false }
        let result = run(executable, arguments: provider == .openAI
            ? ["login", "status"]
            : ["auth", "status"])
        guard result.status == 0 else { return false }
        let lower = result.output.lowercased()
        return lower.contains("logged in") || lower.contains("\"loggedin\": true")
    }

    func ask(
        _ provider: AIProvider,
        messages: [AIChatMessage],
        workingDirectory: String
    ) throws -> String {
        guard let executable = executable(for: provider) else {
            throw AIError.api("Install the official \(provider == .openAI ? "Codex" : "Claude Code") CLI first.")
        }
        let transcript = messages.map { message in
            "\(message.role == .user ? "User" : "Assistant"): \(message.requestContent)"
        }.joined(separator: "\n\n")
        let prompt = "Answer the final user question. Use attached terminal context when present.\n\n" + transcript
        let arguments: [String]
        if provider == .openAI {
            arguments = ["exec", "--sandbox", "read-only", "--skip-git-repo-check", prompt]
        } else {
            arguments = ["-p", prompt, "--output-format", "text", "--permission-mode", "plan", "--max-turns", "1"]
        }
        let result = run(executable, arguments: arguments, workingDirectory: workingDirectory)
        guard result.status == 0 else {
            throw AIError.api(result.error.isEmpty ? "The \(provider.title) CLI request failed." : result.error)
        }
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { throw AIError.invalidResponse }
        return output
    }

    private func executable(for provider: AIProvider) -> String? {
        let name = provider == .openAI ? "codex" : "claude"
        let candidates = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func run(
        _ executable: String,
        arguments: [String],
        workingDirectory: String? = nil
    ) -> (status: Int32, output: String, error: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        if let workingDirectory, FileManager.default.fileExists(atPath: workingDirectory) {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }
        do { try process.run() } catch { return (-1, "", error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        return (process.terminationStatus, output, process.terminationStatus == 0 ? "" : output)
    }
}

enum AIError: LocalizedError {
    case invalidResponse
    case api(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "The provider returned an unreadable response."
        case .api(let message): message
        }
    }
}
