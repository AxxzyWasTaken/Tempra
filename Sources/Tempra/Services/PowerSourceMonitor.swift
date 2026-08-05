import Foundation
import IOKit
import IOKit.ps

enum PowerSourceState: Equatable, Sendable {
    case battery
    case externalPower

    var profilePowerSource: ProfilePowerSource {
        switch self {
        case .battery:
            .battery
        case .externalPower:
            .externalPower
        }
    }
}

final class PowerSourceMonitor {
    typealias StateProvider = () -> PowerSourceState?

    private let stateProvider: StateProvider

    convenience init() {
        self.init(stateProvider: Self.readPowerSource)
    }

    init(stateProvider: @escaping StateProvider) {
        self.stateProvider = stateProvider
    }

    func sample() -> PowerSourceState? {
        stateProvider()
    }

    private static func readPowerSource() -> PowerSourceState? {
        guard let infoReference = IOPSCopyPowerSourcesInfo() else { return nil }
        let info = infoReference.takeRetainedValue()
        guard let sourcesReference = IOPSCopyPowerSourcesList(info) else { return nil }
        let sources = sourcesReference.takeRetainedValue() as [CFTypeRef]

        for source in sources {
            guard let descriptionReference = IOPSGetPowerSourceDescription(info, source),
                  let description = descriptionReference.takeUnretainedValue()
                    as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let state = description[kIOPSPowerSourceStateKey] as? String else {
                continue
            }
            if state == kIOPSACPowerValue {
                return .externalPower
            }
            if state == kIOPSBatteryPowerValue {
                return .battery
            }
        }
        return nil
    }
}
