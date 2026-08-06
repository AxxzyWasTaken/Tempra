import Foundation

public enum ProtectedSystemProcessPolicy {
    public static let bundleIdentifiers: Set<String> = [
        "com.apple.finder",
        "com.apple.dock",
        "com.apple.systemuiserver",
        "com.apple.loginwindow",
        "com.apple.WindowManager",
        "com.apple.WindowServer",
    ]

    private static let canonicalBundleIdentifierByExecutableName: [String: String] = [
        "finder": "com.apple.finder",
        "dock": "com.apple.dock",
        "systemuiserver": "com.apple.systemuiserver",
        "loginwindow": "com.apple.loginwindow",
        "windowmanager": "com.apple.WindowManager",
        "windowserver": "com.apple.WindowServer",
    ]

    private static let canonicalBundleIdentifierByLowercaseIdentifier =
        Dictionary(uniqueKeysWithValues: bundleIdentifiers.map {
            ($0.lowercased(), $0)
        })

    public static func canonicalBundleIdentifier(
        forExecutablePath executablePath: String
    ) -> String? {
        guard !executablePath.isEmpty else { return nil }
        let executableName = (executablePath as NSString).lastPathComponent.lowercased()
        return canonicalBundleIdentifierByExecutableName[executableName]
    }

    public static func canonicalBundleIdentifier(
        forBundleIdentifier bundleIdentifier: String
    ) -> String? {
        canonicalBundleIdentifierByLowercaseIdentifier[bundleIdentifier.lowercased()]
    }

    public static func isProtectedBundleIdentifier(_ bundleIdentifier: String) -> Bool {
        canonicalBundleIdentifier(forBundleIdentifier: bundleIdentifier) != nil
    }

    public static func isProtectedExecutablePath(_ executablePath: String) -> Bool {
        canonicalBundleIdentifier(forExecutablePath: executablePath) != nil
    }

    public static func isProtected(
        bundleIdentifier: String,
        executablePath: String? = nil
    ) -> Bool {
        isProtectedBundleIdentifier(bundleIdentifier)
            || executablePath.map(isProtectedExecutablePath) == true
    }
}
