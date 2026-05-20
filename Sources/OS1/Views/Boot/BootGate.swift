import SwiftUI

/// Wraps `RootView` behind the OS-1 boot animation. RootView is mounted
/// immediately so its data loads while the animation plays; the boot
/// overlay sits on top and dismisses when the animation finishes.
/// Views that should not run until the intro has finished can read
/// `EnvironmentValues.os1BootAnimationFinished`.
struct BootGate<Content: View>: View {
    private let dismissalDuration = 0.04

    @AppStorage("os1.skipBootAnimation") private var skipBootAnimation: Bool = false

    @State private var bootFinished: Bool

    @ViewBuilder var content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
        let environment = ProcessInfo.processInfo.environment
        _bootFinished = State(initialValue: !BootAnimationLaunchPolicy.shouldStartBootAnimation(
            environment: environment,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            userDefaultsSkip: false
        ))
    }

    var body: some View {
        let isBootComplete = bootFinished || skipBootAnimation

        ZStack {
            content()
                .environment(\.os1BootAnimationFinished, isBootComplete)

            if !isBootComplete {
                BootAnimationView {
                    withAnimation(.easeOut(duration: dismissalDuration)) {
                        bootFinished = true
                    }
                }
                .transition(.opacity.animation(.easeOut(duration: dismissalDuration)))
                .zIndex(1)
            }
        }
    }
}

enum BootAnimationLaunchPolicy {
    static let lowMemoryThresholdBytes: UInt64 = 9 * 1024 * 1024 * 1024

    static func shouldStartBootAnimation(
        environment: [String: String],
        physicalMemoryBytes: UInt64,
        userDefaultsSkip: Bool
    ) -> Bool {
        if environment["OS1_SKIP_BOOT"] == "1" || userDefaultsSkip {
            return false
        }
        if physicalMemoryBytes <= lowMemoryThresholdBytes,
           environment["OS1_ENABLE_BOOT_ANIMATION"] != "1" {
            return false
        }
        return true
    }
}

private struct OS1BootAnimationFinishedKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var os1BootAnimationFinished: Bool {
        get { self[OS1BootAnimationFinishedKey.self] }
        set { self[OS1BootAnimationFinishedKey.self] = newValue }
    }
}
