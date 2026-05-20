import Foundation
import Testing
@testable import OS1

@MainActor
struct LaunchStabilityDefaultsTests {
    @Test
    func realtimeVoiceDefaultsToOffUntilOperatorEnablesIt() {
        let appState = AppState()

        #expect(!appState.isRealtimeVoiceEnabled)
        #expect(appState.realtimeVoiceStatus == "off")

        appState.toggleRealtimeVoiceMode()
        #expect(appState.isRealtimeVoiceEnabled)
        #expect(appState.realtimeVoiceStatus == "starting")

        appState.toggleRealtimeVoiceMode()
        #expect(!appState.isRealtimeVoiceEnabled)
        #expect(appState.realtimeVoiceStatus == "off")
    }

    @Test
    func bootAnimationSkipsWhenExplicitlyDisabled() {
        #expect(!BootAnimationLaunchPolicy.shouldStartBootAnimation(
            environment: ["OS1_SKIP_BOOT": "1"],
            physicalMemoryBytes: 64 * 1024 * 1024 * 1024,
            userDefaultsSkip: false
        ))
    }

    @Test
    func bootAnimationSkipsOnLowMemoryByDefault() {
        #expect(!BootAnimationLaunchPolicy.shouldStartBootAnimation(
            environment: [:],
            physicalMemoryBytes: 8 * 1024 * 1024 * 1024,
            userDefaultsSkip: false
        ))
    }

    @Test
    func bootAnimationCanBeForcedOnForLowMemoryMachines() {
        #expect(BootAnimationLaunchPolicy.shouldStartBootAnimation(
            environment: ["OS1_ENABLE_BOOT_ANIMATION": "1"],
            physicalMemoryBytes: 8 * 1024 * 1024 * 1024,
            userDefaultsSkip: false
        ))
    }

    @Test
    func bootAnimationRunsOnLargerMachinesUnlessUserSkippedIt() {
        #expect(BootAnimationLaunchPolicy.shouldStartBootAnimation(
            environment: [:],
            physicalMemoryBytes: 16 * 1024 * 1024 * 1024,
            userDefaultsSkip: false
        ))

        #expect(!BootAnimationLaunchPolicy.shouldStartBootAnimation(
            environment: [:],
            physicalMemoryBytes: 16 * 1024 * 1024 * 1024,
            userDefaultsSkip: true
        ))
    }
}
