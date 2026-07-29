import AppKit
import Foundation

@MainActor
final class AppIconCache {
    typealias Provider = (_ bundleIdentifier: String, _ name: String, _ url: URL?) -> NSImage

    private struct Key: Hashable {
        let bundleIdentifier: String
        let applicationPath: String?
        let fallbackName: String?
    }

    private struct Entry {
        let image: NSImage
        var lastAccess: UInt64
    }

    private let capacity: Int
    private let provider: Provider
    private var entries: [Key: Entry] = [:]
    private var accessSequence: UInt64 = 0

    var cachedIconCount: Int {
        entries.count
    }

    init(capacity: Int = 256, provider: Provider? = nil) {
        self.capacity = max(1, capacity)
        self.provider = provider ?? { _, name, applicationURL in
            if let applicationURL {
                return NSWorkspace.shared.icon(forFile: applicationURL.path)
            }
            return NSImage(systemSymbolName: "app", accessibilityDescription: name) ?? NSImage()
        }
    }

    func icon(
        bundleIdentifier: String,
        name: String,
        applicationURL: URL?
    ) -> NSImage {
        let applicationPath = applicationURL?.standardizedFileURL.path
        let key = Key(
            bundleIdentifier: bundleIdentifier,
            applicationPath: applicationPath,
            fallbackName: applicationPath == nil ? name : nil
        )
        accessSequence &+= 1
        if var entry = entries[key] {
            entry.lastAccess = accessSequence
            entries[key] = entry
            return entry.image
        }

        let image = provider(bundleIdentifier, name, applicationURL)
        entries[key] = Entry(image: image, lastAccess: accessSequence)
        if entries.count > capacity,
           let leastRecentlyUsedKey = entries.min(by: {
               $0.value.lastAccess < $1.value.lastAccess
           })?.key {
            entries.removeValue(forKey: leastRecentlyUsedKey)
        }
        return image
    }
}
