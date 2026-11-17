import Foundation

struct TerminalBlockAttachment: Identifiable, Equatable, Sendable {
    let id: UUID
    let command: String
    let output: String
    let workingDirectory: String
    let sourceBlockID: TerminalBlockID?

    init(
        id: UUID = UUID(),
        command: String,
        output: String,
        workingDirectory: String,
        sourceBlockID: TerminalBlockID? = nil
    ) {
        self.id = id
        self.command = command
        self.output = output
        self.workingDirectory = workingDirectory
        self.sourceBlockID = sourceBlockID
    }

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

struct AIFileAttachment: Identifiable, Equatable, Sendable {
    static let maximumFileBytes = 256 * 1024
    static let maximumDirectoryEntries = 300

    let id: UUID
    let path: String
    let isDirectory: Bool
    let content: String

    init(
        id: UUID = UUID(),
        path: String,
        isDirectory: Bool,
        content: String
    ) {
        self.id = id
        self.path = path
        self.isDirectory = isDirectory
        self.content = content
    }

    static func load(url: URL, fileManager: FileManager = .default) -> AIFileAttachment? {
        let url = url.standardizedFileURL
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }

        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue {
            return AIFileAttachment(
                path: url.path,
                isDirectory: true,
                content: directoryInventory(at: url, fileManager: fileManager)
            )
        }
        return AIFileAttachment(
            path: url.path,
            isDirectory: false,
            content: filePreview(at: url, fileManager: fileManager)
        )
    }

    private static func filePreview(at url: URL, fileManager: FileManager) -> String {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        let size = attributes?[.size] as? UInt64 ?? 0
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return "(File could not be read; \(size) bytes)"
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumFileBytes + 1) else {
            return "(File could not be read; \(size) bytes)"
        }
        let prefix = data.prefix(maximumFileBytes)
        guard !prefix.contains(0), let text = String(data: prefix, encoding: .utf8) else {
            return "(Binary file; \(size) bytes)"
        }
        return data.count > maximumFileBytes
            ? text + "\n… (truncated after \(maximumFileBytes) bytes)"
            : text
    }

    private static func directoryInventory(at url: URL, fileManager: FileManager) -> String {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]
        ) else { return "(Directory could not be read)" }

        var entries: [String] = []
        for case let childURL as URL in enumerator {
            let relativePath = String(childURL.path.dropFirst(url.path.count)).trimmingPrefix("/")
            let isDirectory = (try? childURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            entries.append(relativePath + (isDirectory ? "/" : ""))
            if entries.count == maximumDirectoryEntries {
                entries.append("… (additional entries omitted)")
                break
            }
        }
        return entries.isEmpty ? "(Empty directory)" : entries.joined(separator: "\n")
    }

    var promptContent: String {
        let tag = isDirectory ? "directory" : "file"
        return """
        <\(tag) path="\(path)">
        \(content)
        </\(tag)>
        """
    }
}

enum AIInputAttachment: Identifiable, Equatable, Sendable {
    case terminalBlock(TerminalBlockAttachment)
    case file(AIFileAttachment)

    var id: UUID {
        switch self {
        case .terminalBlock(let attachment): attachment.id
        case .file(let attachment): attachment.id
        }
    }

    var title: String {
        switch self {
        case .terminalBlock(let attachment): attachment.command
        case .file(let attachment): URL(fileURLWithPath: attachment.path).lastPathComponent
        }
    }

    var detail: String {
        switch self {
        case .terminalBlock(let attachment): "\(attachment.output.count) characters of output"
        case .file(let attachment): attachment.isDirectory ? "Folder" : "File"
        }
    }

    var systemImage: String {
        switch self {
        case .terminalBlock: "terminal"
        case .file(let attachment): attachment.isDirectory ? "folder" : "doc"
        }
    }

    var promptContent: String {
        switch self {
        case .terminalBlock(let attachment): attachment.promptContent
        case .file(let attachment): attachment.promptContent
        }
    }

    var sourceBlockID: TerminalBlockID? {
        switch self {
        case .terminalBlock(let attachment): attachment.sourceBlockID
        case .file: nil
        }
    }
}
