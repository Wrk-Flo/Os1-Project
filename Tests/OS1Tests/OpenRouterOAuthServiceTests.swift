import CryptoKit
import Foundation
import Testing
@testable import OS1

struct OpenRouterOAuthServiceTests {
    @Test
    @MainActor
    func codeVerifierIsURLSafe() {
        // PKCE §4.1: verifier must be from the unreserved set
        // [A-Z] [a-z] [0-9] - . _ ~. base64url drops + / = which
        // covers the unsafe characters; we should never see those.
        for _ in 0..<100 {
            let verifier = OpenRouterOAuthService.makeCodeVerifier()
            let illegal = verifier.contains(where: { ch in
                !(ch.isASCII && (ch.isLetter || ch.isNumber || ch == "-" || ch == "_"))
            })
            #expect(!illegal, "Verifier contained illegal char: \(verifier)")
            #expect(verifier.count >= 43, "Verifier too short: \(verifier)")
            #expect(verifier.count <= 128, "Verifier too long: \(verifier)")
        }
    }

    @Test
    @MainActor
    func codeChallengeIsDeterministicSHA256() {
        // Known test vector — same verifier should always produce the
        // same challenge. Lock against accidentally swapping hash algs.
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let challenge = OpenRouterOAuthService.makeCodeChallenge(from: verifier)
        let expected = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        #expect(challenge == expected, "Got \(challenge)")
    }

    @Test
    @MainActor
    func authURLIncludesAllPKCEParams() {
        let callback = OpenRouterOAuthService.callbackURL()
        let url = OpenRouterOAuthService.makeAuthURL(callbackURL: callback, codeChallenge: "abc")
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
        #expect(items["code_challenge"] == "abc")
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["callback_url"] == callback.absoluteString)
        #expect(url.host == "openrouter.ai")
    }

    @Test
    @MainActor
    func callbackURLMatchesSchemeRegisteredInPlist() {
        let callback = OpenRouterOAuthService.callbackURL()
        // Scheme/host/path must match what Info.plist registers and
        // what handleCallback(_:) checks; a divergence would silently
        // drop redirects on the floor.
        #expect(callback.scheme == "os1")
        #expect(callback.host == "oauth")
        #expect(callback.path == "/openrouter")
    }

    @Test
    @MainActor
    func handleCallbackIgnoresUnrelatedURLs() {
        // No active flow + unrelated URL → must not crash and must
        // return false so other handlers can claim the URL.
        let service = OpenRouterOAuthService()
        let irrelevant = URL(string: "https://example.com")!
        #expect(service.handleCallback(irrelevant) == false)

        let wrongHost = URL(string: "os1://other/path")!
        #expect(service.handleCallback(wrongHost) == false)
    }

    @Test
    @MainActor
    func handleCallbackConsumesValidShapeEvenWithoutPending() {
        // Shape matches; no flow in progress. Returns true (we own this
        // URL, drop it silently rather than letting another handler
        // dispatch on a stale code).
        let service = OpenRouterOAuthService()
        let validShape = URL(string: "os1://oauth/openrouter?code=abc")!
        #expect(service.handleCallback(validShape) == true)
    }
}
