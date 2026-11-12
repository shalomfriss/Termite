import Foundation

enum GraphicalFileOperations {
    enum OperationError: LocalizedError {
        case invalidName
        case itemAlreadyExists(String)
        case compressionFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .invalidName:
                "Enter a name that does not begin with a period or contain a colon or slash."
            case .itemAlreadyExists(let name):
                "An item named “\(name)” already exists in this folder."
            case .compressionFailed(let status):
                "The folder could not be compressed (ditto exited with status \(status))."
            }
        }
    }

    static func rename(
        _ source: URL,
        to proposedName: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              !name.hasPrefix("."),
              !name.contains(":"),
              !name.contains("/") else {
            throw OperationError.invalidName
        }

        let destination = source.deletingLastPathComponent().appending(path: name)
        if destination.standardizedFileURL == source.standardizedFileURL { return source }
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw OperationError.itemAlreadyExists(name)
        }
        try fileManager.moveItem(at: source, to: destination)
        return destination
    }

    static func archiveDestination(
        for source: URL,
        fileManager: FileManager = .default
    ) -> URL {
        let directory = source.deletingLastPathComponent()
        let baseName = source.lastPathComponent
        var candidate = directory.appending(path: baseName + ".zip")
        var number = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appending(path: "\(baseName) \(number).zip")
            number += 1
        }
        return candidate
    }

    static func compress(
        _ source: URL,
        fileManager: FileManager = .default
    ) async throws -> URL {
        let destination = archiveDestination(for: source, fileManager: fileManager)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = [
            "-c", "-k", "--sequesterRsrc", "--keepParent",
            source.path,
            destination.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { completedProcess in
                if completedProcess.terminationStatus == 0 {
                    continuation.resume(returning: destination)
                } else {
                    continuation.resume(
                        throwing: OperationError.compressionFailed(
                            completedProcess.terminationStatus
                        )
                    )
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
