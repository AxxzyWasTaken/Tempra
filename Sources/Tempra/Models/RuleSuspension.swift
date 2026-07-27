import Foundation

struct RuleSuspension: Codable, Equatable, Identifiable {
    let bundleIdentifier: String
    let until: Date

    var id: String { bundleIdentifier }

    var isActive: Bool {
        until > Date()
    }
}
