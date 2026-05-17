import Foundation
import Testing
@testable import OS1

@MainActor
struct OS1FeatureFlagsTests {
    @Test
    func orgoTransportDefaultsToDisabledWithoutOptIn() throws {
        let defaults = try Self.makeDefaults()

        #expect(!OS1FeatureFlags.isOrgoTransportEnabled(environment: [:], userDefaults: defaults))
    }

    @Test
    func orgoTransportCanBeEnabledByUserDefaults() throws {
        let defaults = try Self.makeDefaults()
        defaults.set(true, forKey: "EnableOrgoTransport")

        #expect(OS1FeatureFlags.isOrgoTransportEnabled(environment: ["OS1_ENABLE_ORGO": "0"], userDefaults: defaults))
    }

    @Test
    func orgoTransportCanBeEnabledByTruthyEnvironmentValue() throws {
        let defaults = try Self.makeDefaults()

        for value in ["1", "true", "yes", "on", " TRUE "] {
            #expect(OS1FeatureFlags.isOrgoTransportEnabled(environment: ["OS1_ENABLE_ORGO": value], userDefaults: defaults))
        }
    }

    @Test
    func orgoTransportIgnoresFalseOrUnknownEnvironmentValues() throws {
        let defaults = try Self.makeDefaults()

        for value in ["0", "false", "no", "off", "orgo"] {
            #expect(!OS1FeatureFlags.isOrgoTransportEnabled(environment: ["OS1_ENABLE_ORGO": value], userDefaults: defaults))
        }
    }

    @Test
    func connectionEditorHidesOrgoForNewSSHDraftsWhenFlagIsOff() {
        #expect(!ConnectionEditorSheet.shouldShowOrgoTransport(isOrgoTransportEnabled: false, draftTransportKind: .ssh))
    }

    @Test
    func connectionEditorShowsOrgoForNewSSHDraftsWhenFlagIsOn() {
        #expect(ConnectionEditorSheet.shouldShowOrgoTransport(isOrgoTransportEnabled: true, draftTransportKind: .ssh))
    }

    @Test
    func connectionEditorKeepsExistingOrgoProfilesEditableWhenFlagIsOff() {
        #expect(ConnectionEditorSheet.shouldShowOrgoTransport(isOrgoTransportEnabled: false, draftTransportKind: .orgo))
    }

    private static func makeDefaults() throws -> UserDefaults {
        let suiteName = "OS1FeatureFlagsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
