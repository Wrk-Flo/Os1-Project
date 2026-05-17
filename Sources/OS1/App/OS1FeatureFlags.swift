import Foundation

enum OS1FeatureFlags {
    static var isOrgoTransportEnabled: Bool {
        isOrgoTransportEnabled(
            environment: ProcessInfo.processInfo.environment,
            userDefaults: .standard
        )
    }

    static func isOrgoTransportEnabled(
        environment: [String: String],
        userDefaults: UserDefaults
    ) -> Bool {
        if userDefaults.bool(forKey: "EnableOrgoTransport") {
            return true
        }

        guard let rawValue = environment["OS1_ENABLE_ORGO"] else {
            return false
        }

        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }
}
