import Foundation

actor RepositoryContextScanner {
    func scan(at workingDirectory: String) -> RepositoryContext? {
        Self.scanRepository(at: workingDirectory)
    }

    nonisolated static func scanRepository(at workingDirectory: String) -> RepositoryContext? {
        let directory = URL(
            fileURLWithPath: workingDirectory,
            isDirectory: true
        ).standardizedFileURL
        guard let root = repositoryRoot(startingAt: directory) else { return nil }

        let searchDirectories = directories(from: directory, through: root)
        let node = runtime(
            kind: .node,
            searchDirectories: searchDirectories,
            repositoryRoot: root
        )
        let python = runtime(
            kind: .python,
            searchDirectories: searchDirectories,
            repositoryRoot: root
        )
        let displayName = root.lastPathComponent.isEmpty ? root.path : root.lastPathComponent
        return RepositoryContext(
            rootPath: root.path,
            displayName: displayName,
            node: node,
            python: python
        )
    }

    nonisolated static func repositoryRoot(startingAt start: URL) -> URL? {
        let fileManager = FileManager.default
        var directory = start
        while true {
            if fileManager.fileExists(atPath: directory.appending(path: ".git").path) {
                return directory
            }
            let parent = directory.deletingLastPathComponent().standardizedFileURL
            if parent.path == directory.path { return nil }
            directory = parent
        }
    }

    private nonisolated static func directories(from directory: URL, through root: URL) -> [URL] {
        guard directory.path == root.path || directory.path.hasPrefix(root.path + "/") else {
            return [root]
        }
        var result: [URL] = []
        var current = directory
        while true {
            result.append(current)
            if current.path == root.path { return result }
            current = current.deletingLastPathComponent().standardizedFileURL
        }
    }

    private nonisolated static func runtime(
        kind: RepositoryContext.RuntimeKind,
        searchDirectories: [URL],
        repositoryRoot: URL
    ) -> RepositoryContext.Runtime? {
        guard let declaration = runtimeDeclaration(kind: kind, directories: searchDirectories) else {
            return nil
        }
        return RepositoryContext.Runtime(
            kind: kind,
            declaredVersion: declaration.version,
            declarationSource: declaration.source,
            installations: installations(
                kind: kind,
                repositoryRoot: repositoryRoot,
                declaredVersion: declaration.version
            )
        )
    }

    private nonisolated static func runtimeDeclaration(
        kind: RepositoryContext.RuntimeKind,
        directories: [URL]
    ) -> (version: String?, source: String)? {
        for directory in directories {
            if let declaration = directVersionDeclaration(kind: kind, directory: directory) {
                return declaration
            }
            if let declaration = toolVersionsDeclaration(kind: kind, directory: directory) {
                return declaration
            }
            if let declaration = miseDeclaration(kind: kind, directory: directory) {
                return declaration
            }
            if let declaration = manifestDeclaration(kind: kind, directory: directory) {
                return declaration
            }
        }
        return nil
    }

    private nonisolated static func directVersionDeclaration(
        kind: RepositoryContext.RuntimeKind,
        directory: URL
    ) -> (version: String?, source: String)? {
        let names = switch kind {
        case .node: [".nvmrc", ".node-version"]
        case .python: [".python-version"]
        }
        for name in names {
            let url = directory.appending(path: name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            return (firstValue(in: url), name)
        }
        return nil
    }

    private nonisolated static func toolVersionsDeclaration(
        kind: RepositoryContext.RuntimeKind,
        directory: URL
    ) -> (version: String?, source: String)? {
        let url = directory.appending(path: ".tool-versions")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let keys = switch kind {
        case .node: ["nodejs", "node"]
        case .python: ["python"]
        }
        for line in text.split(whereSeparator: \Character.isNewline) {
            let fields = line.split(whereSeparator: \Character.isWhitespace)
            guard fields.count >= 2, keys.contains(String(fields[0])) else { continue }
            return (normalizeVersion(String(fields[1])), ".tool-versions")
        }
        return nil
    }

    private nonisolated static func miseDeclaration(
        kind: RepositoryContext.RuntimeKind,
        directory: URL
    ) -> (version: String?, source: String)? {
        for name in ["mise.toml", ".mise.toml"] {
            let url = directory.appending(path: name)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let key = kind.rawValue
            for line in text.split(whereSeparator: \Character.isNewline) {
                let parts = line.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let candidate = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                guard candidate == key || candidate == "tools.\(key)" else { continue }
                return (normalizeVersion(String(parts[1])), name)
            }
        }
        return nil
    }

    private nonisolated static func manifestDeclaration(
        kind: RepositoryContext.RuntimeKind,
        directory: URL
    ) -> (version: String?, source: String)? {
        switch kind {
        case .node:
            let url = directory.appending(path: "package.json")
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            let engines = object["engines"] as? [String: Any]
            return (normalizeVersion(engines?["node"] as? String), "package.json")
        case .python:
            for name in ["pyproject.toml", "uv.lock", "requirements.txt", "Pipfile"] {
                let url = directory.appending(path: name)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                if name == "pyproject.toml",
                   let text = try? String(contentsOf: url, encoding: .utf8),
                   let line = text.split(whereSeparator: \Character.isNewline).first(where: {
                       $0.trimmingCharacters(in: .whitespaces).hasPrefix("requires-python")
                   }),
                   let value = line.split(separator: "=", maxSplits: 1).last {
                    return (normalizeVersion(String(value)), name)
                }
                return (nil, name)
            }
        }
        return nil
    }

    private nonisolated static func installations(
        kind: RepositoryContext.RuntimeKind,
        repositoryRoot: URL,
        declaredVersion: String?
    ) -> [RepositoryContext.RuntimeInstallation] {
        var values: [RepositoryContext.RuntimeInstallation] = []
        var seen = Set<String>()
        let home = FileManager.default.homeDirectoryForCurrentUser

        func append(
            version: String,
            binPath: URL,
            executable: String,
            source: String,
            isProjectLocal: Bool = false
        ) {
            let standardized = binPath.standardizedFileURL.path
            guard !seen.contains(standardized),
                  FileManager.default.isExecutableFile(
                    atPath: binPath.appending(path: executable).path
                  ) else { return }
            seen.insert(standardized)
            values.append(.init(
                version: normalizeVersion(version) ?? version,
                binPath: standardized,
                source: source,
                isProjectLocal: isProjectLocal
            ))
        }

        func appendChildren(
            parent: URL,
            binSuffix: [String],
            executable: String,
            source: String,
            namePrefix: String? = nil
        ) {
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: parent,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return }
            for child in children {
                if let namePrefix,
                   child.lastPathComponent != namePrefix,
                   !child.lastPathComponent.hasPrefix(namePrefix + "@") {
                    continue
                }
                var bin = child
                for component in binSuffix { bin.append(path: component) }
                let version = if let namePrefix,
                                 child.lastPathComponent.hasPrefix(namePrefix + "@") {
                    String(child.lastPathComponent.dropFirst(namePrefix.count + 1))
                } else {
                    child.lastPathComponent
                }
                append(
                    version: version,
                    binPath: bin,
                    executable: executable,
                    source: source
                )
            }
        }

        switch kind {
        case .node:
            appendChildren(
                parent: home.appending(path: ".nvm/versions/node"),
                binSuffix: ["bin"],
                executable: "node",
                source: "nvm"
            )
            appendChildren(
                parent: home.appending(path: ".local/share/mise/installs/node"),
                binSuffix: ["bin"],
                executable: "node",
                source: "mise"
            )
            appendChildren(
                parent: home.appending(path: ".asdf/installs/nodejs"),
                binSuffix: ["bin"],
                executable: "node",
                source: "asdf"
            )
            appendChildren(
                parent: home.appending(path: ".volta/tools/image/node"),
                binSuffix: ["bin"],
                executable: "node",
                source: "Volta"
            )
            appendChildren(
                parent: home.appending(path: ".local/share/fnm/node-versions"),
                binSuffix: ["installation", "bin"],
                executable: "node",
                source: "fnm"
            )
            appendChildren(
                parent: home.appending(path: "Library/Application Support/fnm/node-versions"),
                binSuffix: ["installation", "bin"],
                executable: "node",
                source: "fnm"
            )
            for prefix in ["/opt/homebrew/opt", "/usr/local/opt"] {
                appendChildren(
                    parent: URL(fileURLWithPath: prefix, isDirectory: true),
                    binSuffix: ["bin"],
                    executable: "node",
                    source: "Homebrew",
                    namePrefix: "node"
                )
            }
        case .python:
            for environmentName in [".venv", "venv"] {
                append(
                    version: environmentName,
                    binPath: repositoryRoot.appending(path: "\(environmentName)/bin"),
                    executable: "python",
                    source: "Project",
                    isProjectLocal: true
                )
            }
            appendChildren(
                parent: home.appending(path: ".pyenv/versions"),
                binSuffix: ["bin"],
                executable: "python",
                source: "pyenv"
            )
            appendChildren(
                parent: home.appending(path: ".local/share/mise/installs/python"),
                binSuffix: ["bin"],
                executable: "python",
                source: "mise"
            )
            appendChildren(
                parent: home.appending(path: ".asdf/installs/python"),
                binSuffix: ["bin"],
                executable: "python",
                source: "asdf"
            )
            for prefix in ["/opt/homebrew/opt", "/usr/local/opt"] {
                appendChildren(
                    parent: URL(fileURLWithPath: prefix, isDirectory: true),
                    binSuffix: ["bin"],
                    executable: "python3",
                    source: "Homebrew",
                    namePrefix: "python"
                )
            }
            appendChildren(
                parent: URL(
                    fileURLWithPath: "/Library/Frameworks/Python.framework/Versions",
                    isDirectory: true
                ),
                binSuffix: ["bin"],
                executable: "python3",
                source: "Python.org"
            )
        }

        let executableNames = switch kind {
        case .node: ["node"]
        case .python: ["python", "python3"]
        }
        for path in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let bin = URL(fileURLWithPath: String(path), isDirectory: true)
            if let executable = executableNames.first(where: {
                FileManager.default.isExecutableFile(atPath: bin.appending(path: $0).path)
            }) {
                append(
                    version: "Current PATH",
                    binPath: bin,
                    executable: executable,
                    source: "System"
                )
                break
            }
        }

        return values.sorted { left, right in
            if left.isProjectLocal != right.isProjectLocal { return left.isProjectLocal }
            let leftMatches = version(left.version, matches: declaredVersion)
            let rightMatches = version(right.version, matches: declaredVersion)
            if leftMatches != rightMatches { return leftMatches }
            return left.version.localizedStandardCompare(right.version) == .orderedDescending
        }
    }

    private nonisolated static func firstValue(in url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return normalizeVersion(text.split(whereSeparator: \Character.isNewline).first.map(String.init))
    }

    private nonisolated static func normalizeVersion(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard !cleaned.isEmpty else { return nil }
        if cleaned.first == "v", cleaned.dropFirst().first?.isNumber == true {
            return String(cleaned.dropFirst())
        }
        return cleaned
    }

    private nonisolated static func version(_ candidate: String, matches declared: String?) -> Bool {
        guard let declared = normalizeVersion(declared),
              declared.first?.isNumber == true else { return false }
        let candidate = normalizeVersion(candidate) ?? candidate
        return candidate == declared || candidate.hasPrefix(declared + ".")
    }
}
