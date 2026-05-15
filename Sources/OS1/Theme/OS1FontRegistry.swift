import CoreText
import Foundation

/// Registers the bundled DM Sans TTFs with Core Text so SwiftUI's
/// `Font.custom("DMSans", size:)` resolves correctly. Call once during
/// app startup. Idempotent — Core Text safely returns
/// `kCTFontManagerErrorAlreadyRegistered` on second registration and we
/// swallow it.
enum OS1FontRegistry {
    private static let bundledFontFiles: [String] = [
        "DMSans-ExtraLight",
        "DMSans-Light",
        "DMSans-Regular",
        "DMSans-Medium"
    ]

    static func registerBundledFonts() {
        let bundle = Bundle.module
        for name in bundledFontFiles {
            guard let url = bundle.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts")
                ?? bundle.url(forResource: name, withExtension: "ttf") else {
                #if DEBUG
                print("[OS1FontRegistry] missing bundled font: \(name).ttf")
                #endif
                continue
            }

            var error: Unmanaged<CFError>?
            let registered = CTFontManagerRegisterFontsForURL(
                url as CFURL,
                .process,
                &error
            )

            if !registered, let err = error?.takeRetainedValue() {
                let domain = CFErrorGetDomain(err) as String
                let code = CFErrorGetCode(err)
                // 105 = kCTFontManagerErrorAlreadyRegistered. Idempotent.
                if !(domain == "com.apple.CoreText.CTFontManagerErrorDomain" && code == 105) {
                    #if DEBUG
                    print("[OS1FontRegistry] failed to register \(name): \(err)")
                    #endif
                }
            }
        }
    }
}
