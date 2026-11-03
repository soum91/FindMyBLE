import Foundation
import CoreLocation
import UIKit

// Talks to the same service icloud.com/find uses. Apple has no official API for this, so it can
// stop working whenever Apple changes the site. Everything is logged (never passwords or cookie
// values) so a failure can be diagnosed from the Activity Log in the Devices tab.

enum FMConst {
    /// Same string for the sign-in web view and the API calls, so Apple sees one browser.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
    static let buildNumber = "2021Project52"
    static let masteringNumber = "2021B29"
    static let origin = "https://www.icloud.com"
}

// MARK: - Activity log

final class FindMyLog: ObservableObject {
    static let shared = FindMyLog()
    @Published private(set) var lines: [String] = UserDefaults.standard.stringArray(forKey: "fmLog") ?? []

    static func log(_ s: String) { shared.add(s) }

    func add(_ s: String) {
        DispatchQueue.main.async {
            let f = DateFormatter()
            f.dateFormat = "MMM d HH:mm:ss"
            var l = self.lines
            l.append("\(f.string(from: Date()))  \(s)")
            if l.count > 250 { l.removeFirst(l.count - 250) }
            self.lines = l
            UserDefaults.standard.set(l, forKey: "fmLog")
        }
    }

    func clear() {
        DispatchQueue.main.async {
            self.lines = []
            UserDefaults.standard.removeObject(forKey: "fmLog")
        }
    }
}

// MARK: - Model

struct FMDevice: Identifiable, Equatable, Codable {
    let id: String
    var name: String
    var model: String
    var cls: String
    /// 0...1
    var battery: Double?
    var charging: Bool
    var online: Bool
    var lat: Double?
    var lon: Double?
    var accuracy: Double
    var locAt: Date?
    var finished: Bool

    init?(json j: [String: Any]) {
        guard let id = j["id"] as? String else { return nil }
        self.id = id
        name = (j["name"] as? String) ?? "Device"
        model = (j["deviceDisplayName"] as? String) ?? ""
        cls = (j["deviceClass"] as? String) ?? ""
        battery = (j["batteryLevel"] as? NSNumber)?.doubleValue
        charging = (j["batteryStatus"] as? String) == "Charging"
        online = "\(j["deviceStatus"] ?? "")" == "200"
        var la: Double?, lo: Double?, ac = 0.0, at: Date?, fin = false
        if let l = j["location"] as? [String: Any] {
            la = (l["latitude"] as? NSNumber)?.doubleValue
            lo = (l["longitude"] as? NSNumber)?.doubleValue
            ac = (l["horizontalAccuracy"] as? NSNumber)?.doubleValue ?? 0
            if let ms = (l["timeStamp"] as? NSNumber)?.doubleValue { at = Date(timeIntervalSince1970: ms / 1000) }
            fin = (l["locationFinished"] as? NSNumber)?.boolValue ?? false
        }
        lat = la; lon = lo; accuracy = ac; locAt = at; finished = fin
    }

    var coordinate: CLLocationCoordinate2D? {
        guard let lat, let lon else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    var symbol: String {
        let k = (cls + " " + model + " " + name).lowercased()
        if k.contains("airpods") { return "airpodspro" }
        if k.contains("watch") { return "applewatch" }
        if k.contains("ipad") { return "ipad" }
        if k.contains("iphone") { return "iphone" }
        if k.contains("mac") { return "laptopcomputer" }
        if k.contains("tag") { return "tag.fill" }
        return "dot.radiowaves.left.and.right"
    }
}

enum FMError: LocalizedError {
    case notSignedIn, expired, http(Int), bad(String)
    var errorDescription: String? {
        switch self {
        case .notSignedIn: "Not signed in to iCloud."
        case .expired: "The iCloud session expired. Sign in again."
        case .http(let c): "iCloud answered with HTTP \(c)."
        case .bad(let s): s
        }
    }
}

// MARK: - Client

actor FindMyClient {
    static let shared = FindMyClient()

    private var cookies: [HTTPCookie] = []
    private var dsid: String?
    private var root: String?
    private let clientId: String
    private let session: URLSession

    private static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("findmy-session.plist")
    }()

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.timeoutIntervalForRequest = 20
        session = URLSession(configuration: cfg)
        if let s = UserDefaults.standard.string(forKey: "fmClientId") {
            clientId = s
        } else {
            let s = UUID().uuidString.lowercased()
            UserDefaults.standard.set(s, forKey: "fmClientId")
            clientId = s
        }
        cookies = Self.load()
    }

    var hasSession: Bool { !cookies.isEmpty }

    // MARK: Session

    /// Cookies from the sign-in web view.
    func adopt(_ new: [HTTPCookie]) {
        cookies = new.filter { $0.domain.contains("icloud.com") || $0.domain.contains("apple.com") }
        dsid = nil
        root = nil
        save()
        FindMyLog.log("Adopted \(cookies.count) cookies from sign-in (\(Set(cookies.map(\.domain)).sorted().joined(separator: ", ")))")
    }

    func signOut() {
        cookies = []
        dsid = nil
        root = nil
        try? FileManager.default.removeItem(at: Self.fileURL)
        FindMyLog.log("Signed out")
    }

    /// Learns the account id and the Find My server address.
    func validate() async throws {
        guard !cookies.isEmpty else { throw FMError.notSignedIn }
        var c = URLComponents(string: "https://setup.icloud.com/setup/ws/1/validate")!
        c.queryItems = query(withDSID: false)
        let (data, http) = try await send(c.url!, body: nil)
        FindMyLog.log("validate -> HTTP \(http.statusCode)")
        if [401, 421, 450].contains(http.statusCode) { throw FMError.expired }
        guard http.statusCode == 200 else { throw FMError.http(http.statusCode) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FMError.bad("validate returned something unreadable")
        }
        let ds = json["dsInfo"] as? [String: Any]
        let web = json["webservices"] as? [String: Any]
        FindMyLog.log("validate: dsInfo \(ds == nil ? "missing" : "ok"), services: \((web?.keys.sorted() ?? []).joined(separator: ","))")
        guard let id = ds?["dsid"], !"\(id)".isEmpty else { throw FMError.expired }
        dsid = "\(id)"
        guard let fm = web?["findme"] as? [String: Any], let url = fm["url"] as? String, !url.isEmpty else {
            throw FMError.bad("This account has no Find My service listed.")
        }
        root = url.replacingOccurrences(of: ":443", with: "")
        FindMyLog.log("Find My server: \(URL(string: root ?? "")?.host ?? "?")")
    }

    // MARK: Devices

    /// Devices with their last known location. The first answer often has no location yet, so
    /// this asks again a few times while iCloud is still locating.
    func devices(polls: Int) async throws -> [FMDevice] {
        if root == nil || dsid == nil { try await validate() }
        var devs = try await refreshOnce()
        var n = 1
        while n < polls, devs.contains(where: { $0.online && !$0.finished }) {
            try await Task.sleep(nanoseconds: 3_000_000_000)
            devs = try await refreshOnce()
            n += 1
        }
        let located = devs.filter { $0.coordinate != nil }.count
        FindMyLog.log("Got \(devs.count) devices, \(located) with a location, after \(n) request(s)")
        return devs
    }

    private func refreshOnce() async throws -> [FMDevice] {
        for attempt in 0..<2 {
            guard let root, dsid != nil else { throw FMError.notSignedIn }
            var c = URLComponents(string: root + "/fmipservice/client/web/refreshClient")!
            c.queryItems = query(withDSID: true)
            let body = #"{"clientContext":{"fmly":true,"shouldLocate":true,"selectedDevice":"all"}}"#
            let (data, http) = try await send(c.url!, body: Data(body.utf8))
            if [401, 421, 450].contains(http.statusCode) {
                FindMyLog.log("refreshClient -> HTTP \(http.statusCode)")
                if attempt == 0 {
                    self.root = nil; self.dsid = nil
                    try await validate()
                    continue
                }
                throw FMError.expired
            }
            guard http.statusCode == 200 else {
                FindMyLog.log("refreshClient -> HTTP \(http.statusCode): \(String(decoding: data.prefix(150), as: UTF8.self))")
                throw FMError.http(http.statusCode)
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = json["content"] as? [[String: Any]] else {
                FindMyLog.log("refreshClient: no device list in answer: \(String(decoding: data.prefix(150), as: UTF8.self))")
                throw FMError.bad("iCloud answered without a device list.")
            }
            return list.compactMap { FMDevice(json: $0) }
        }
        throw FMError.expired
    }

    func playSound(_ deviceID: String) async throws {
        if root == nil || dsid == nil { try await validate() }
        guard let root else { throw FMError.notSignedIn }
        var c = URLComponents(string: root + "/fmipservice/client/web/playSound")!
        c.queryItems = query(withDSID: true)
        let obj: [String: Any] = ["device": deviceID, "subject": "Find My Device Alert",
                                  "clientContext": ["fmly": true]]
        let body = try JSONSerialization.data(withJSONObject: obj)
        let (_, http) = try await send(c.url!, body: body)
        FindMyLog.log("playSound -> HTTP \(http.statusCode)")
        if [401, 421, 450].contains(http.statusCode) { throw FMError.expired }
        guard http.statusCode == 200 else { throw FMError.http(http.statusCode) }
    }

    // MARK: HTTP

    private func query(withDSID: Bool) -> [URLQueryItem] {
        var q = [URLQueryItem(name: "clientBuildNumber", value: FMConst.buildNumber),
                 URLQueryItem(name: "clientMasteringNumber", value: FMConst.masteringNumber),
                 URLQueryItem(name: "clientId", value: clientId)]
        if withDSID, let dsid { q.append(URLQueryItem(name: "dsid", value: dsid)) }
        return q
    }

    private func send(_ url: URL, body: Data?) async throws -> (Data, HTTPURLResponse) {
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.httpBody = body
        r.setValue(FMConst.origin, forHTTPHeaderField: "Origin")
        r.setValue(FMConst.origin + "/", forHTTPHeaderField: "Referer")
        r.setValue("text/plain;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        r.setValue("*/*", forHTTPHeaderField: "Accept")
        r.setValue(FMConst.userAgent, forHTTPHeaderField: "User-Agent")
        if let h = cookieHeader(for: url) { r.setValue(h, forHTTPHeaderField: "Cookie") }
        let (data, resp) = try await session.data(for: r)
        guard let http = resp as? HTTPURLResponse else { throw FMError.bad("No response from iCloud.") }
        var fields: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            if let k = k as? String, let v = v as? String { fields[k] = v }
        }
        let fresh = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
        if !fresh.isEmpty { merge(fresh) }
        return (data, http)
    }

    // MARK: Cookies

    private func cookieHeader(for url: URL) -> String? {
        let host = url.host ?? ""
        let now = Date()
        let usable = cookies.filter { c in
            if let e = c.expiresDate, e < now { return false }
            let d = c.domain.hasPrefix(".") ? String(c.domain.dropFirst()) : c.domain
            return host == d || host.hasSuffix("." + d)
        }
        return HTTPCookie.requestHeaderFields(with: usable)["Cookie"]
    }

    private func merge(_ fresh: [HTTPCookie]) {
        for n in fresh {
            cookies.removeAll { $0.name == n.name && $0.domain == n.domain && $0.path == n.path }
            if let e = n.expiresDate, e < Date() { continue }
            cookies.append(n)
        }
        save()
    }

    private func save() {
        let arr: [[String: Any]] = cookies.map { c in
            var d: [String: Any] = ["name": c.name, "value": c.value, "domain": c.domain,
                                    "path": c.path, "secure": c.isSecure]
            if let e = c.expiresDate { d["exp"] = e.timeIntervalSince1970 }
            return d
        }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: arr, format: .binary, options: 0) else { return }
        try? data.write(to: Self.fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private static func load() -> [HTTPCookie] {
        guard let data = try? Data(contentsOf: fileURL),
              let arr = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [[String: Any]]
        else { return [] }
        let now = Date()
        return arr.compactMap { d in
            guard let name = d["name"] as? String, let value = d["value"] as? String,
                  let domain = d["domain"] as? String, let path = d["path"] as? String else { return nil }
            var p: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path]
            if (d["secure"] as? Bool) == true { p[.secure] = "TRUE" }
            if let e = d["exp"] as? Double {
                let date = Date(timeIntervalSince1970: e)
                if date < now { return nil }
                p[.expires] = date
            }
            return HTTPCookie(properties: p)
        }
    }
}
