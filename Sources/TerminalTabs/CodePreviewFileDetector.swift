import Foundation
import UniformTypeIdentifiers

enum CodePreviewFileDetector {
    private static let codeExtensions: Set<String> = [
        "c", "cc", "clj", "cljs", "cmake", "cpp", "cs", "css", "dart", "diff",
        "el", "erl", "ex", "exs", "fish", "fs", "fsx", "go", "gradle", "groovy",
        "h", "hpp", "htm", "html", "java", "js", "json", "jsonc", "jsx", "kt",
        "kts", "less", "lua", "m", "markdown", "md", "mm", "php", "pl", "proto",
        "py", "r", "rb", "rs", "sass", "scala", "scss", "sh", "sql", "svelte",
        "swift", "toml", "ts", "tsx", "vue", "xml", "yaml", "yml", "zig", "zsh",
    ]

    private static let codeFileNames: Set<String> = [
        ".editorconfig", ".gitattributes", ".gitignore", "CMakeLists.txt", "Dockerfile",
        "Gemfile", "Justfile", "Makefile", "Package.swift", "Podfile", "Rakefile",
    ]

    static func isCodeFile(_ url: URL) -> Bool {
        if codeFileNames.contains(url.lastPathComponent) { return true }
        let fileExtension = url.pathExtension.lowercased()
        if codeExtensions.contains(fileExtension) { return true }
        return UTType(filenameExtension: fileExtension)?.conforms(to: .sourceCode) == true
    }
}
