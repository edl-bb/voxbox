import Foundation
import FluidAudio

struct ModelDownloadManifest: Equatable, Sendable {
    struct File: Equatable, Sendable {
        var path: String
        var size: Int64
    }

    var files: [File]
    var totalBytes: Int64

    var fileCount: Int { files.count }

    nonisolated static func make(files: [File]) -> ModelDownloadManifest {
        ModelDownloadManifest(
            files: files,
            totalBytes: files.reduce(0) { $0 + max(0, $1.size) }
        )
    }
}

/// Hugging Face `tree/main` listings include a `size` on every file.
/// FluidAudio uses that internally but only forwards a 0–0.5 fraction, so
/// VoxBox fetches the same listing and treats it as the download manifest.
enum HuggingFaceModelManifest {
    struct Entry: Equatable {
        var path: String
        var type: String
        var size: Int64
    }

    nonisolated private static let maxFiles = 400
    nonisolated private static let maxDepth = 8

    nonisolated static func huggingFaceRepo(for variant: String) -> Repo {
        switch variant {
        case ParakeetCatalog.v2Variant: return .parakeetV2
        case ParakeetCatalog.ctc110mVariant: return .parakeetTdtCtc110m
        default: return .parakeetV3
        }
    }

    nonisolated static func requiredNames(for variant: String) -> [String] {
        let models: Set<String>
        switch variant {
        case ParakeetCatalog.v2Variant:
            models = ModelNames.ASR.requiredModels
        case ParakeetCatalog.ctc110mVariant:
            models = ModelNames.ASR.requiredModelsFused
        default:
            models = ModelNames.ASR.requiredModelsV3(precision: .int8)
        }
        return Array(models) + [ModelNames.ASR.vocabularyFile]
    }

    nonisolated static func parseEntries(_ items: [[String: Any]]) -> [Entry] {
        items.compactMap { item in
            guard let path = item["path"] as? String,
                let type = item["type"] as? String
            else { return nil }
            let size: Int64
            if let value = item["size"] as? Int {
                size = Int64(value)
            } else if let value = item["size"] as? Int64 {
                size = value
            } else {
                size = -1
            }
            return Entry(path: path, type: type, size: size)
        }
    }

    nonisolated static func shouldInclude(path: String, requiredNames: [String]) -> Bool {
        let name = (path as NSString).lastPathComponent
        if name.hasSuffix(".json") || name.hasSuffix(".txt") {
            return true
        }
        return requiredNames.contains { required in
            path == required || path.hasPrefix("\(required)/") || name == required
        }
    }

    nonisolated static func manifest(
        from entries: [Entry],
        requiredNames: [String]
    ) -> ModelDownloadManifest {
        let files = entries
            .filter { $0.type == "file" && shouldInclude(path: $0.path, requiredNames: requiredNames) }
            .map { ModelDownloadManifest.File(path: $0.path, size: $0.size) }
        return ModelDownloadManifest.make(files: files)
    }

    nonisolated static func remoteURL(for path: String, variant: String) throws -> URL {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return try ModelRegistry.resolveModel(huggingFaceRepo(for: variant).remotePath, encoded)
    }

    nonisolated static func fetch(
        for variant: String,
        session: URLSession = HuggingFaceModelManifest.session
    ) async throws -> ModelDownloadManifest {
        let repo = huggingFaceRepo(for: variant)
        let required = requiredNames(for: variant)
        let files = try await listDirectory(
            repo: repo, path: "", session: session, depth: 0)
        let filtered = files.filter { shouldInclude(path: $0.path, requiredNames: required) }
        return ModelDownloadManifest.make(files: filtered)
    }

    nonisolated private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    nonisolated private static func listDirectory(
        repo: Repo,
        path: String,
        session: URLSession,
        depth: Int
    ) async throws -> [ModelDownloadManifest.File] {
        guard depth <= maxDepth else { return [] }

        let apiPath = path.isEmpty ? "tree/main" : "tree/main/\(path)"
        let url = try ModelRegistry.apiModels(repo.remotePath, apiPath)
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        guard let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw URLError(.cannotParseResponse)
        }

        var files: [ModelDownloadManifest.File] = []
        for entry in parseEntries(items) {
            if files.count >= maxFiles { break }
            if entry.type == "directory" {
                files += try await listDirectory(
                    repo: repo, path: entry.path, session: session, depth: depth + 1)
            } else if entry.type == "file" {
                files.append(ModelDownloadManifest.File(path: entry.path, size: entry.size))
            }
        }
        return files
    }
}
