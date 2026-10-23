import Foundation
import Security

/// Files shared between the app and the widget through the App Group container.
enum AppGroup {
    static let defaultID = "group.com.soumen.findmyble"

    /// Sideloaders often rename the App Group (AltStore adds the team ID, Sideloadly can rewrite it
    /// to match a new bundle ID), so read the group IDs this binary was actually signed with first.
    static var containerURL: URL { resolved.url }

    /// False when the sideload stripped the App Group, so the widget can't see the app's data.
    static var isShared: Bool { resolved.shared }
    static var activeGroup: String? { resolved.group }
    static var candidates: [String] { resolved.tried }
    /// Every shared container this binary can open. Some sideloaders hand the app and the widget a pool of
    /// renamed groups in different orders, so data is written to all of them and read from the newest copy.
    static var containers: [URL] { resolved.all }
    static var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
    }

    private static let resolved: (url: URL, shared: Bool, group: String?, tried: [String], all: [URL]) = {
        var ids: [String] = signedGroups()
        for bundle in [Bundle.main, appBundle].compactMap({ $0 }) {
            if let alt = bundle.object(forInfoDictionaryKey: "ALTAppGroups") as? [String] { ids += alt }
        }
        ids.append(defaultID)
        var unique: [String] = []
        for id in ids where !unique.contains(id) { unique.append(id) }
        var urls: [URL] = []
        var first: String?
        for id in unique {
            if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) {
                urls.append(url)
                if first == nil { first = id }
            }
        }
        if let first, let url = urls.first {
            return (url, true, first, unique, urls)
        }
        let fallback = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return (fallback, false, nil, unique, [fallback])
    }()

    /// Read the running process's actual signed entitlements without loading or scanning its
    /// executable. WidgetKit gives extensions a small memory budget and the old scan ran
    /// during the first timeline request, before WidgetKit could display real content.
    /// It also assumed the signing tool left an XML entitlement in the Mach-O binary.
    static func signedGroups() -> [String] {
        guard let task = SecTaskCreateFromSelf(nil),
              let groups = SecTaskCopyValueForEntitlement(
                task, "com.apple.security.application-groups" as CFString, nil
              ) as? [String] else { return [] }
        return groups.filter { $0.hasPrefix("group.") }
    }

    /// The containing app's bundle when running inside the widget extension.
    private static var appBundle: Bundle? {
        let url = Bundle.main.bundleURL
        guard url.pathExtension == "appex" else { return nil }
        return Bundle(url: url.deletingLastPathComponent().deletingLastPathComponent())
    }

    static func file(_ name: String) -> URL { containerURL.appendingPathComponent(name) }

    static func read<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        let newest = containers
            .map { $0.appendingPathComponent(name) }
            .compactMap { url -> (URL, Date)? in
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                      let date = attrs[.modificationDate] as? Date else { return nil }
                return (url, date)
            }
            .max { $0.1 < $1.1 }
        guard let url = newest?.0, let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        return try? dec.decode(T.self, from: data)
    }

    static func write<T: Encodable>(_ value: T, _ name: String) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        guard let data = try? enc.encode(value) else { return }
        for dir in containers {
            try? data.write(to: dir.appendingPathComponent(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    /// Raw bytes (images). Written to every container, read from the newest copy.
    static func writeData(_ data: Data, _ name: String) {
        for dir in containers {
            try? data.write(to: dir.appendingPathComponent(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    static func readData(_ name: String) -> Data? {
        let newest = containers
            .map { $0.appendingPathComponent(name) }
            .compactMap { url -> (URL, Date)? in
                guard let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
                else { return nil }
                return (url, date)
            }
            .max { $0.1 < $1.1 }
        return newest.flatMap { try? Data(contentsOf: $0.0) }
    }

    static func remove(_ name: String) {
        for dir in containers { try? FileManager.default.removeItem(at: dir.appendingPathComponent(name)) }
    }
}
