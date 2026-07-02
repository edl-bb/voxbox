//
//  DeviceCapability.swift
//  speaktype
//
//  Detects the host Mac's hardware so the app can recommend a transcription
//  model that actually matches the machine — not just its RAM. Considers the
//  chip family/generation, performance-core count, Neural Engine, and RAM.
//

import Foundation

/// A snapshot of the host Mac's relevant compute capability.
struct DeviceCapability: Equatable {
    enum Chip: Equatable {
        /// Apple Silicon with a best-effort generation (M1 = 1, M2 = 2, …); 0 if unknown.
        case appleSilicon(generation: Int)
        case intel
        case unknown
    }

    /// Installed physical memory, in GB.
    let ramGB: Int
    let chip: Chip
    /// Human-readable chip string, e.g. "Apple M3 Pro" or an Intel brand string.
    let chipName: String
    /// Number of performance cores (Apple Silicon) or physical cores (Intel).
    let performanceCoreCount: Int
    /// Apple Silicon ships a Neural Engine; Intel Macs do not.
    let hasNeuralEngine: Bool

    /// Cached capability for the current machine.
    static let current: DeviceCapability = detect()

    /// A 0.0–1.0 estimate of how comfortably this Mac runs a real-time,
    /// on-device speech model. Higher means larger/slower models stay usable.
    var performanceTier: Double {
        let base: Double
        switch chip {
        case .appleSilicon(let generation):
            // M1 ≈ 0.6, and each generation adds headroom, capped at 1.0.
            base = min(1.0, 0.6 + Double(max(generation - 1, 0)) * 0.12)
        case .intel:
            base = 0.3  // No Neural Engine; CoreML falls back to CPU/GPU.
        case .unknown:
            base = 0.5
        }
        // Extra performance cores widen the margin a little (Pro/Max/Ultra).
        let coreBonus = min(0.15, Double(max(performanceCoreCount - 4, 0)) * 0.02)
        return min(1.0, base + coreBonus)
    }

    var isAppleSilicon: Bool {
        if case .appleSilicon = chip { return true }
        return false
    }

    /// Short summary for UI, e.g. "Apple M3 Pro · 18 GB · Neural Engine".
    var summary: String {
        var parts = [chipName, "\(ramGB) GB"]
        if hasNeuralEngine { parts.append("Neural Engine") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Detection

    static func detect() -> DeviceCapability {
        let ramGB = Int((ProcessInfo.processInfo.physicalMemory + (1 << 29)) / (1 << 30))
        let brand = sysctlString("machdep.cpu.brand_string") ?? ""

        let chip: Chip
        let hasNeuralEngine: Bool
        if brand.localizedCaseInsensitiveContains("Apple") {
            chip = .appleSilicon(generation: appleSiliconGeneration(from: brand))
            hasNeuralEngine = true
        } else if brand.isEmpty {
            // Empty brand string on Apple Silicon can happen; fall back to arch.
            #if arch(arm64)
                chip = .appleSilicon(generation: 0)
                hasNeuralEngine = true
            #else
                chip = .intel
                hasNeuralEngine = false
            #endif
        } else {
            chip = .intel
            hasNeuralEngine = false
        }

        // Performance cores on Apple Silicon live at perflevel0; fall back to
        // physical CPU count on Intel or older SDKs.
        let perfCores =
            sysctlInt("hw.perflevel0.physicalcpu")
            ?? sysctlInt("hw.physicalcpu")
            ?? ProcessInfo.processInfo.activeProcessorCount

        let chipName = brand.isEmpty ? (chip == .intel ? "Intel Mac" : "Apple Silicon") : brand

        return DeviceCapability(
            ramGB: max(ramGB, 1),
            chip: chip,
            chipName: chipName,
            performanceCoreCount: max(perfCores, 1),
            hasNeuralEngine: hasNeuralEngine
        )
    }

    /// Parse the M-series generation from a brand string like "Apple M3 Pro".
    static func appleSiliconGeneration(from brand: String) -> Int {
        // Look for the token after "M" (e.g. "M3" -> 3).
        guard let range = brand.range(of: #"\bM(\d+)"#, options: .regularExpression) else {
            return 0
        }
        let token = brand[range].dropFirst()  // drop the "M"
        return Int(token) ?? 0
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int = 0
        var size = MemoryLayout<Int>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}
