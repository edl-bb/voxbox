import SwiftUI

/// Per-row / Cleanup-strip hook for preparing-model status.
/// Driven by `PostProcessingModelManager.preparingVariant` so the catalog
/// row and Cleanup strip cannot disagree.
struct CleanupModelStatusAccessory: View {
    let model: PostProcessingModel
    @ObservedObject private var manager = PostProcessingModelManager.shared

    /// View-model predicate for tests that inject a non-shared manager.
    static func isPreparing(
        _ model: PostProcessingModel,
        manager: PostProcessingModelManager
    ) -> Bool {
        manager.isPreparing(model)
    }

    var body: some View {
        Group {
            if manager.isPreparing(model) {
                HStack(spacing: 6) {
                    Spinner(size: 11, lineWidth: 1.5, tint: Color.textSecondary)
                    Text("Preparing…")
                        .font(Typography.uiMedium(11))
                }
                .foregroundStyle(Color.textSecondary)
            }
        }
        .id(model.variant)
    }
}
