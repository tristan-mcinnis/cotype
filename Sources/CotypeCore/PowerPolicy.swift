import Foundation
import IOKit.ps

/// The machine's power state, reduced to the two facts a completion policy
/// needs. Pure and injectable so the policy table is testable without a battery.
public struct PowerState: Equatable, Sendable {
    public var onBattery: Bool
    public var lowPowerMode: Bool

    public init(onBattery: Bool, lowPowerMode: Bool) {
        self.onBattery = onBattery
        self.lowPowerMode = lowPowerMode
    }

    /// A desktop or a Mac with no readable battery reports external power.
    public static let externalPower = PowerState(onBattery: false, lowPowerMode: false)
}

public protocol PowerStateProviding: Sendable {
    func current() -> PowerState
}

/// Production provider: `ProcessInfo` for Low Power Mode and IOKit for the
/// battery. Every read is defensive; an unreadable power source is treated as
/// external power so a broken sensor can never silently disable suggestions.
public struct SystemPowerStateProvider: PowerStateProviding {
    public init() {}

    public func current() -> PowerState {
        PowerState(
            onBattery: Self.isOnBattery(),
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }

    static func isOnBattery() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?
        else { return false }
        return type == kIOPSBatteryPowerValue
    }
}

/// When automatic (typing-pause) suggestions pause to save energy.
///
/// The manual trigger is deliberately outside this policy: the user asking for a
/// completion is a direct instruction, so it always runs. Pausing automatic work
/// never unloads, restarts, or duplicates the shared Local Models daemon; it
/// only stops Cotype from starting its own generations.
public enum BatteryPolicy {
    /// Pause auto suggestions while the Mac runs on battery. Off by default: the
    /// measured cost of a warm-daemon completion is not established, so this is
    /// an explicit choice.
    public static let pauseOnBatteryKey = "pauseAutoOnBattery"
    /// Pause auto suggestions in Low Power Mode. On by default: Low Power Mode is
    /// already an explicit request to reduce background work.
    public static let pauseInLowPowerModeKey = "pauseAutoInLowPowerMode"

    public struct Settings: Equatable, Sendable {
        public var pauseOnBattery: Bool
        public var pauseInLowPowerMode: Bool

        public init(pauseOnBattery: Bool, pauseInLowPowerMode: Bool) {
            self.pauseOnBattery = pauseOnBattery
            self.pauseInLowPowerMode = pauseInLowPowerMode
        }

        public static func current(_ defaults: UserDefaults = .standard) -> Settings {
            Settings(
                pauseOnBattery: defaults.object(forKey: pauseOnBatteryKey) as? Bool ?? false,
                pauseInLowPowerMode: defaults.object(forKey: pauseInLowPowerModeKey) as? Bool ?? true
            )
        }
    }

    /// Whether the automatic lane must pause for this state.
    public static func pausesAutomatic(_ state: PowerState, settings: Settings) -> Bool {
        if state.lowPowerMode, settings.pauseInLowPowerMode { return true }
        if state.onBattery, settings.pauseOnBattery { return true }
        return false
    }
}
