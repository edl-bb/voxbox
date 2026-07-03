//
//  FontRegistration.swift
//  speaktype
//
//  Registers app-bundled fonts (Satoshi, Source Sans 3) with the process so
//  `Font.custom(...)` resolves them even on machines where the font isn't
//  installed system-wide. Call `AppFonts.registerBundledFonts()` once at launch.
//

import CoreText
import Foundation

enum AppFonts {
    /// PostScript names of the Satoshi weights we bundle, for reference at call
    /// sites so we fail loudly (in Debug) if a weight is missing.
    enum Satoshi {
        static let regular = "Satoshi-Regular"
        static let medium = "Satoshi-Medium"
        static let bold = "Satoshi-Bold"
    }

    private static var didRegister = false

    /// Registers every .otf/.ttf shipped in the app bundle. Idempotent.
    static func registerBundledFonts() {
        guard !didRegister else { return }
        didRegister = true

        let extensions = ["otf", "ttf"]
        var urls: [URL] = []
        for ext in extensions {
            urls += Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: nil) ?? []
        }

        for url in urls {
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                // Already-registered fonts report an error we can safely ignore;
                // anything else is worth a Debug log.
                #if DEBUG
                let desc = error?.takeRetainedValue().localizedDescription ?? "unknown"
                print("[AppFonts] Skipped \(url.lastPathComponent): \(desc)")
                #endif
            }
        }
    }
}
