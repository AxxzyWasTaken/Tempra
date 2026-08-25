import Foundation
import ServiceManagement

@MainActor
protocol LaunchAtLoginControlling: AnyObject {
    var isEnabled: Bool { get }
    var requiresApproval: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}

@MainActor
final class LaunchAtLoginController: LaunchAtLoginControlling {
    private let bundleURL: URL
    private let locationPolicy: LaunchAtLoginLocationPolicy

    init(
        bundleURL: URL = Bundle.main.bundleURL,
        locationPolicy: LaunchAtLoginLocationPolicy = LaunchAtLoginLocationPolicy()
    ) {
        self.bundleURL = bundleURL
        self.locationPolicy = locationPolicy
    }

    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            guard locationPolicy.permitsRegistration(for: bundleURL) else {
                throw LaunchAtLoginControllerError.appIsOutsideApplicationsDirectory
            }
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else if SMAppService.mainApp.status != .notRegistered {
            try SMAppService.mainApp.unregister()
        }
    }
}

enum LaunchAtLoginControllerError: LocalizedError {
    case appIsOutsideApplicationsDirectory

    var errorDescription: String? {
        switch self {
        case .appIsOutsideApplicationsDirectory:
            "Move Tempra to an Applications folder before you enable Launch at login."
        }
    }
}

struct LaunchAtLoginLocationPolicy {
    private let applicationDirectories: [URL]

    init(
        applicationDirectories: [URL] = LaunchAtLoginLocationPolicy
            .systemApplicationDirectories()
    ) {
        self.applicationDirectories = applicationDirectories.map(Self.canonicalURL)
    }

    func permitsRegistration(for bundleURL: URL) -> Bool {
        let bundleComponents = Self.canonicalURL(bundleURL).pathComponents
        return applicationDirectories.contains { directory in
            let directoryComponents = directory.pathComponents
            guard bundleComponents.count > directoryComponents.count else {
                return false
            }
            return bundleComponents.starts(with: directoryComponents)
        }
    }

    private static func systemApplicationDirectories() -> [URL] {
        [.localDomainMask, .userDomainMask].flatMap {
            FileManager.default.urls(for: .applicationDirectory, in: $0)
        }
    }

    private static func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
}
