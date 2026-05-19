import Foundation
import Testing
@testable import OS1

struct ProviderCatalogTests {
    @Test
    func slugsAreUnique() {
        let slugs = ProviderCatalog.entries.map(\.slug)
        let unique = Set(slugs)
        #expect(slugs.count == unique.count, "Slugs should be unique. Got: \(slugs)")
    }

    @Test
    func envVarsAreUnique() {
        // Hermes reads env vars from .env keyed by name, so two
        // providers writing to the same key would collide on disk.
        let envVars = ProviderCatalog.entries.map(\.envVar)
        let unique = Set(envVars)
        #expect(envVars.count == unique.count, "Env vars should be unique. Got: \(envVars)")
    }

    @Test
    func customProviderConfigNamesAreUnique() {
        // Within `custom_providers`, `name` is the lookup key — must be
        // unique. Built-in providers don't share this namespace.
        var names: [String] = []
        for entry in ProviderCatalog.entries {
            if case .customProvider(let configName) = entry.kind {
                names.append(configName)
            }
        }
        #expect(names.count == Set(names).count, "Custom provider names should be unique. Got: \(names)")
    }

    @Test
    func everyEntryHasParsableURLs() {
        for entry in ProviderCatalog.entries {
            let isLocalHTTP = entry.baseURL.scheme == "http" && ["127.0.0.1", "localhost"].contains(entry.baseURL.host ?? "")
            #expect(entry.baseURL.scheme == "https" || isLocalHTTP,
                    "\(entry.slug) base URL should be https or loopback http")
            #expect(entry.dashboardURL.scheme == "https",
                    "\(entry.slug) dashboard URL should be https")
            if let docs = entry.docsURL {
                #expect(docs.scheme == "https",
                        "\(entry.slug) docs URL should be https")
            }
        }
    }

    @Test
    func sixCoreProvidersPresent() {
        let expected: Set<String> = ["anthropic", "openrouter", "openai", "fireworks", "kimi", "zai"]
        let actual = Set(ProviderCatalog.entries.map(\.slug))
        #expect(expected.isSubset(of: actual), "Missing one of the 6 core providers. Got: \(actual)")
    }

    @Test
    func localOpenSourceProvidersAreKeylessCustomProviders() throws {
        let expected: [(slug: String, configName: String, baseURL: String, envVar: String)] = [
            ("ollama", "ollama", "http://127.0.0.1:11434/v1", "OLLAMA_API_KEY"),
            ("llama-cpp", "llama_cpp", "http://127.0.0.1:8080/v1", "LLAMA_CPP_API_KEY"),
            ("lm-studio", "lm_studio", "http://127.0.0.1:1234/v1", "LM_STUDIO_API_KEY"),
        ]

        for item in expected {
            let entry = try #require(ProviderCatalog.entry(for: item.slug))
            #expect(!entry.requiresAPIKey)
            #expect(!entry.supportsOAuth)
            #expect(entry.keyPrefixHint == "No key required")
            #expect(entry.envVar == item.envVar)
            #expect(entry.baseURL.absoluteString == item.baseURL)

            if case .customProvider(let name) = entry.kind {
                #expect(name == item.configName)
            } else {
                Issue.record("\(entry.displayName) should be a custom provider")
            }

            if case .skip(let reason) = entry.validation {
                #expect(reason.contains("does not require an API key"))
            } else {
                Issue.record("\(entry.displayName) should skip API-key validation")
            }
        }
    }

    @Test
    func openRouterIsTheOnlyOAuthProvider() {
        // OAuth (PKCE) is OpenRouter-only today. If we add another
        // OAuth-capable provider this test should be loosened — but
        // the change should be deliberate, not accidental.
        let oauthSlugs = ProviderCatalog.entries.filter(\.supportsOAuth).map(\.slug)
        #expect(oauthSlugs == ["openrouter"], "OAuth providers changed: \(oauthSlugs)")
    }

    @Test
    func anthropicSkipsModelValidation() {
        // Anthropic doesn't have a cheap key-probe endpoint — explicit
        // .skip avoids spurious "validation failed" errors at save time.
        guard let anthropic = ProviderCatalog.entry(for: "anthropic") else {
            Issue.record("Anthropic entry missing")
            return
        }
        if case .skip = anthropic.validation {
            // expected
        } else {
            Issue.record("Anthropic validation should be .skip; got \(anthropic.validation)")
        }
    }

    @Test
    func openAIBaseURLIsCanonical() {
        let openai = ProviderCatalog.entry(for: "openai")
        #expect(openai?.baseURL.absoluteString == "https://api.openai.com/v1")
    }

    @Test
    func providerModelSummaryDecodesCommonShapes() throws {
        let payloads: [(String, String?)] = [
            (#"{"id":"gpt-5.2","name":"GPT-5.2","context_length":200000}"#, "GPT-5.2"),
            (#"{"id":"glm-4.6","display_name":"GLM 4.6"}"#, "GLM 4.6"),
            (#"{"id":"openai/o5-mini"}"#, nil), // no display name
        ]
        for (raw, expectedName) in payloads {
            let data = Data(raw.utf8)
            let model = try JSONDecoder().decode(ProviderModelSummary.self, from: data)
            #expect(model.displayName == expectedName, "Failed for \(raw)")
        }
    }

    @Test
    func providerModelListResponseDecodes() throws {
        let raw = #"{"data":[{"id":"a"},{"id":"b","name":"Beta"}]}"#
        let payload = try JSONDecoder().decode(ProviderModelListResponse.self, from: Data(raw.utf8))
        #expect(payload.data.map(\.id) == ["a", "b"])
        #expect(payload.data[1].displayName == "Beta")
    }
}
