import Foundation

enum ProfilePowerSource: Equatable, Sendable {
    case battery
    case externalPower
}

struct ManagementContext: Equatable, Sendable {
    var powerSource: ProfilePowerSource?
    var userIdleDuration: TimeInterval?

    static let unavailable = ManagementContext(
        powerSource: nil,
        userIdleDuration: nil
    )
}

enum ManagementProfileSelector {
    static func automaticProfileID(
        profiles: [ManagementProfile],
        context: ManagementContext
    ) -> UUID? {
        profiles.enumerated()
            .filter { _, profile in
                profile.activation.isAutomatic
                    && matches(profile.activation, context: context)
            }
            .max { lhs, rhs in
                let leftConditions = lhs.element.activation.conditionCount
                let rightConditions = rhs.element.activation.conditionCount
                if leftConditions != rightConditions {
                    return leftConditions < rightConditions
                }
                return lhs.offset > rhs.offset
            }?
            .element.id
    }

    private static func matches(
        _ activation: ProfileActivation,
        context: ManagementContext
    ) -> Bool {
        switch activation.powerCondition {
        case .any:
            break
        case .battery:
            guard context.powerSource == .battery else { return false }
        case .externalPower:
            guard context.powerSource == .externalPower else { return false }
        }

        if let idleAfterMinutes = activation.idleAfterMinutes {
            guard idleAfterMinutes.isFinite,
                  idleAfterMinutes > 0,
                  let userIdleDuration = context.userIdleDuration,
                  userIdleDuration.isFinite,
                  userIdleDuration >= idleAfterMinutes * 60 else {
                return false
            }
        }
        return true
    }
}
