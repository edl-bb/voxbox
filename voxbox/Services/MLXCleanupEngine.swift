import Foundation

/// Runs cleanup on a locally downloaded MLX model.
///
/// Interim state: the MLX runtime dependency is being wired in on this
/// branch; until that lands, `cleanup` throws and the formatter's retry
/// path runs the request on the system model instead.
struct MLXCleanupEngine: CleanupEngine {
    let model: PostProcessingModel
    let directory: URL

    var isAvailable: Bool {
        FileManager.default.fileExists(atPath: directory.path)
    }

    var displayName: String { model.name }

    func cleanup(_ request: FormattingRequest) async throws -> String {
        throw MLXCleanupEngineError.runtimeUnavailable
    }
}

enum MLXCleanupEngineError: Error {
    case runtimeUnavailable
}
