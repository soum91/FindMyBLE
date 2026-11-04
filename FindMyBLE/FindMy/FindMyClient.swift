import Foundation
import CoreLocation
import UIKit
import Security

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

struct FMStatus { let statusCode: Int }

struct FMPhone: Identifiable, Equatable { let id: Int; let label: String }

enum FMLoginResult { case signedIn, needsCode([FMPhone]) }

/// The saved Apple ID password, kept in the iOS Keychain on this phone only.
enum FMKeychain {
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "FindMyBLE.icloud",
         kSecAttrAccount as String: account]
    }
    static func set(_ account: String, _ value: String) {
        SecItemDelete(query(account) as CFDictionary)
        var q = query(account)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
    static func get(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func remove(_ account: String) { SecItemDelete(query(account) as CFDictionary) }
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

    /// True once calls have to be made from inside the icloud.com page (see FindMyWebBridge).
    private var webMode = UserDefaults.standard.bool(forKey: "fmWebMode")

    var hasSession: Bool { !cookies.isEmpty || webMode }

    // MARK: Session

    /// Cookies from the sign-in web view.
    func adopt(_ new: [HTTPCookie]) {
        UserDefaults.standard.set(true, forKey: "fmWebSignIn")
        cookies = new.filter { $0.domain.contains("icloud.com") || $0.domain.contains("apple.com") }
        dsid = nil
        root = nil
        save()
        FindMyLog.log("Adopted \(cookies.count) cookies from sign-in (\(Set(cookies.map(\.domain)).sorted().joined(separator: ", ")))")
        FindMyLog.log("Cookie names: \(cookies.map(\.name).sorted().joined(separator: ", "))")
    }

    func signOut() async {
        cookies = []
        dsid = nil
        root = nil
        webMode = false
        UserDefaults.standard.set(false, forKey: "fmWebMode")
        try? FileManager.default.removeItem(at: Self.fileURL)
        await FindMyWebBridge.shared.clear()
        if let id = UserDefaults.standard.string(forKey: "fmAppleID") { FMKeychain.remove(id) }
        UserDefaults.standard.removeObject(forKey: "fmAppleID")
        UserDefaults.standard.removeObject(forKey: "fmTrust")
        trustToken = ""
        FindMyLog.log("Signed out")
    }

    /// Learns the account id and the Find My server address.
    func validate() async throws {
        guard hasSession else { throw FMError.notSignedIn }
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
                if attempt == 0, http.statusCode != 450 {
                    // Maybe only the server address moved; validate is a cheap check, not a sign-in.
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


    // MARK: Native sign-in (Apple ID + password + 2FA), same steps as icloud.com

    private static let authBase = "https://idmsa.apple.com/appleauth/auth"
    private static let widgetKey = "d39ba9916b7251055b22c7f910e2ea796ee65e98b2ddecea8f5dde8d9d1a815d"
    private var scnt = ""
    private var authSessionID = ""
    private var sessionToken = UserDefaults.standard.string(forKey: "fmSessionToken") ?? ""
    private var trustToken = UserDefaults.standard.string(forKey: "fmTrust") ?? ""
    private var accountCountry = ""
    private var authAttributes = ""

    private func authHeaders(json: Bool = true) -> [String: String] {
        var h = [
            "Accept": json ? "application/json" : "*/*",
            "Content-Type": "application/json",
            // Same as pyicloud, which signs in this way every day: the page is icloud.com.
            "Origin": FMConst.origin,
            "Referer": FMConst.origin + "/",
            "X-Apple-OAuth-Client-Id": Self.widgetKey,
            "X-Apple-OAuth-Client-Type": "firstPartyAuth",
            "X-Apple-OAuth-Redirect-URI": FMConst.origin,
            "X-Apple-OAuth-Require-Grant-Code": "true",
            "X-Apple-OAuth-Response-Mode": "web_message",
            "X-Apple-OAuth-Response-Type": "code",
            "X-Apple-OAuth-State": "auth-" + clientId,
            "X-Apple-Widget-Key": Self.widgetKey,
        ]
        if !scnt.isEmpty { h["scnt"] = scnt }
        if !authSessionID.isEmpty { h["X-Apple-ID-Session-Id"] = authSessionID }
        if !authAttributes.isEmpty { h["X-Apple-Auth-Attributes"] = authAttributes }
        return h
    }

    private func capture(_ http: HTTPURLResponse) {
        if let v = http.value(forHTTPHeaderField: "scnt") { scnt = v }
        if let v = http.value(forHTTPHeaderField: "X-Apple-ID-Session-Id") { authSessionID = v }
        if let v = http.value(forHTTPHeaderField: "X-Apple-Session-Token") { sessionToken = v }
        if let v = http.value(forHTTPHeaderField: "X-Apple-TwoSV-Trust-Token") {
            trustToken = v
            UserDefaults.standard.set(v, forKey: "fmTrust")
        }
        if let v = http.value(forHTTPHeaderField: "X-Apple-ID-Account-Country") { accountCountry = v }
        if let v = http.value(forHTTPHeaderField: "X-Apple-Auth-Attributes") { authAttributes = v }
    }

    private func raw(_ url: URL, method: String, headers: [String: String], body: Data?) async throws -> (Data, HTTPURLResponse) {
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.httpBody = body
        r.setValue(FMConst.userAgent, forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        if let h = cookieHeader(for: url) { r.setValue(h, forHTTPHeaderField: "Cookie") }
        let (data, resp) = try await session.data(for: r)
        guard let http = resp as? HTTPURLResponse else { throw FMError.bad("No response from Apple.") }
        var fields: [String: String] = [:]
        for (k, v) in http.allHeaderFields { if let k = k as? String, let v = v as? String { fields[k] = v } }
        let fresh = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
        if !fresh.isEmpty { merge(fresh) }
        capture(http)
        return (data, http)
    }

    private func b64(_ b: [UInt8]) -> String { Data(b).base64EncodedString() }

    /// Step 1: password. Returns .signedIn, or .needsCode when Apple wants the 2FA code.
    func login(appleID: String, password: String) async throws -> FMLoginResult {
        let id = appleID.trimmingCharacters(in: .whitespacesAndNewlines)
        scnt = ""; authSessionID = ""; sessionToken = ""; authAttributes = ""
        cookies = []
        let srp = SRP.Client()
        let initBody: [String: Any] = ["a": b64(srp.A.bytes), "accountName": id, "protocols": ["s2k", "s2k_fo"]]
        let (d1, r1) = try await raw(URL(string: Self.authBase + "/signin/init")!, method: "POST",
                                     headers: authHeaders(), body: try JSONSerialization.data(withJSONObject: initBody))
        FindMyLog.log("signin/init -> HTTP \(r1.statusCode)")
        guard r1.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: d1) as? [String: Any],
              let saltS = j["salt"] as? String, let bS = j["b"] as? String, let c = j["c"] as? String,
              let salt = Data(base64Encoded: saltS), let B = Data(base64Encoded: bS) else {
            FindMyLog.log("signin/init body: \(String(decoding: d1.prefix(200), as: UTF8.self))")
            throw FMError.bad(r1.statusCode == 401 || r1.statusCode == 403 ? "Apple rejected that Apple ID." : "Apple's sign-in didn't answer as expected (HTTP \(r1.statusCode)).")
        }
        let iter = (j["iteration"] as? NSNumber)?.intValue ?? 0
        let proto = (j["protocol"] as? String) ?? "s2k"
        FindMyLog.log("signin/init: protocol \(proto), \(iter) iterations")
        let key = SRP.derivePassword(password, salt: [UInt8](salt), iterations: iter, protocolName: proto)
        guard !key.isEmpty, let proof = srp.respond(account: id, salt: [UInt8](salt), B: [UInt8](B), key: key) else {
            throw FMError.bad("Couldn't compute the sign-in proof.")
        }
        let completeBody: [String: Any] = ["accountName": id, "c": c, "m1": b64(proof.m1), "m2": b64(proof.m2),
                                           "rememberMe": true, "trustTokens": trustToken.isEmpty ? [] : [trustToken]]
        let (d2, r2) = try await raw(URL(string: Self.authBase + "/signin/complete?isRememberMeEnabled=true")!, method: "POST",
                                     headers: authHeaders(), body: try JSONSerialization.data(withJSONObject: completeBody))
        FindMyLog.log("signin/complete -> HTTP \(r2.statusCode)")
        switch r2.statusCode {
        case 200, 204:
            try await finishLogin()
            return .signedIn
        case 409:
            FindMyLog.log("2FA needed: \(String(decoding: d2.prefix(200), as: UTF8.self)) scnt:\(scnt.isEmpty ? "no" : "yes") session:\(authSessionID.isEmpty ? "no" : "yes")")
            let phones = await twoFactorOptions()
            return .needsCode(phones)
        case 401:
            throw FMError.bad("Wrong Apple ID or password.")
        default:
            FindMyLog.log("signin/complete body: \(String(decoding: d2.prefix(200), as: UTF8.self))")
            throw FMError.bad("Apple refused the sign-in (HTTP \(r2.statusCode)).")
        }
    }

    /// Asks Apple which ways it can deliver the code. The request itself is what makes Apple push
    /// the code to your other devices.
    func twoFactorOptions() async -> [FMPhone] {
        var hdr = authHeaders()
        hdr["Accept"] = "application/json"
        guard let (d, r) = try? await raw(URL(string: Self.authBase)!, method: "GET", headers: hdr, body: nil) else {
            FindMyLog.log("2FA info: request failed")
            return []
        }
        let j = ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any]) ?? [:]
        // Apple nests the numbers under "phoneNumberVerification".
        let pv = (j["phoneNumberVerification"] as? [String: Any]) ?? j
        var raws = (pv["trustedPhoneNumbers"] as? [[String: Any]]) ?? (j["trustedPhoneNumbers"] as? [[String: Any]]) ?? []
        if raws.isEmpty, let one = (pv["trustedPhoneNumber"] ?? j["trustedPhoneNumber"]) as? [String: Any] { raws = [one] }
        var out: [FMPhone] = []
        for p in raws {
            guard let id = (p["id"] as? NSNumber)?.intValue else { continue }
            let mode = (p["pushMode"] as? String) ?? "sms"
            phoneModes[id] = mode
            out.append(FMPhone(id: id, label: (p["numberWithDialCode"] as? String) ?? "phone \(id)"))
        }
        let sc = (pv["securityCode"] as? [String: Any]) ?? (j["securityCode"] as? [String: Any]) ?? [:]
        FindMyLog.log("2FA info -> HTTP \(r.statusCode): numbers \(out.map { "id \($0.id) (\(phoneModes[$0.id] ?? "?"))" }.joined(separator: ", ")), trusted devices \(j["trustedDeviceCount"] ?? "?"), noTrustedDevices \(j["noTrustedDevices"] ?? "?"), tooManyCodesSent \(sc["tooManyCodesSent"] ?? "?"), locked \(sc["securityCodeLocked"] ?? sc["tooManyCodesValidated"] ?? "?")")
        return out
    }

    private var phoneModes: [Int: String] = [:]

    /// Ask Apple to text the code to one of the trusted numbers.
    func textCode(phoneID: Int) async throws {
        let mode = phoneModes[phoneID] ?? "sms"
        let body = try JSONSerialization.data(withJSONObject: ["phoneNumber": ["id": phoneID], "mode": mode] as [String: Any])
        var hdr = authHeaders()
        hdr["Accept"] = "application/json"
        let (d, r) = try await raw(URL(string: Self.authBase + "/verify/phone")!, method: "PUT", headers: hdr, body: body)
        let j = ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any]) ?? [:]
        let msg = ((j["serviceErrors"] as? [[String: Any]])?.first?["message"] as? String) ?? ""
        FindMyLog.log("text code to id \(phoneID) (\(mode)) -> HTTP \(r.statusCode) \(msg)")
        if r.statusCode == 423 {
            throw FMError.bad(msg.isEmpty ? "Apple has stopped sending codes to this number for now (too many requests). Wait a few hours, then try once." : msg)
        }
        guard (200...204).contains(r.statusCode) else {
            throw FMError.bad(msg.isEmpty ? "Apple wouldn't send the text (HTTP \(r.statusCode))." : msg)
        }
    }

    /// Step 2: the 6-digit code, from a trusted device or (with `phoneID`) from a text.
    func submitCode(_ code: String, phoneID: Int?) async throws {
        let clean = code.filter(\.isNumber)
        let url: String
        let obj: [String: Any]
        if let phoneID {
            url = "/verify/phone/securitycode"
            obj = ["phoneNumber": ["id": phoneID], "securityCode": ["code": clean], "mode": phoneModes[phoneID] ?? "sms"]
        } else {
            url = "/verify/trusteddevice/securitycode"
            obj = ["securityCode": ["code": clean]]
        }
        let (d, r) = try await raw(URL(string: Self.authBase + url)!, method: "POST", headers: authHeaders(),
                                   body: try JSONSerialization.data(withJSONObject: obj))
        FindMyLog.log("verify code -> HTTP \(r.statusCode)")
        guard (200...204).contains(r.statusCode) else {
            FindMyLog.log("verify body: \(String(decoding: d.prefix(200), as: UTF8.self))")
            throw FMError.bad(r.statusCode == 400 || r.statusCode == 403 ? "That code was wrong or expired." : "Apple refused the code (HTTP \(r.statusCode)).")
        }
        // Trust this app, so the next sign-in skips the code.
        let (_, t) = try await raw(URL(string: Self.authBase + "/2sv/trust")!, method: "GET",
                                   headers: authHeaders(), body: nil)
        FindMyLog.log("2sv/trust -> HTTP \(t.statusCode)")
        try await finishLogin()
    }

    /// Turns Apple's session token into an iCloud session and finds the Find My server.
    private func finishLogin() async throws {
        guard !sessionToken.isEmpty else { throw FMError.bad("Apple didn't hand back a session token.") }
        var c = URLComponents(string: "https://setup.icloud.com/setup/ws/1/accountLogin")!
        c.queryItems = query(withDSID: false)
        let obj: [String: Any] = ["accountCountryCode": accountCountry, "dsWebAuthToken": sessionToken,
                                  "extended_login": true, "trustToken": trustToken]
        let (data, r) = try await raw(c.url!, method: "POST",
                                      headers: ["Content-Type": "text/plain;charset=UTF-8", "Accept": "*/*",
                                                "Origin": FMConst.origin, "Referer": FMConst.origin + "/"],
                                      body: try JSONSerialization.data(withJSONObject: obj))
        FindMyLog.log("accountLogin -> HTTP \(r.statusCode)")
        guard r.statusCode == 200, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            FindMyLog.log("accountLogin body: \(String(decoding: data.prefix(200), as: UTF8.self))")
            throw FMError.bad("iCloud refused the session (HTTP \(r.statusCode)).")
        }
        let ds = j["dsInfo"] as? [String: Any]
        let web = j["webservices"] as? [String: Any]
        FindMyLog.log("accountLogin: services \((web?.keys.sorted() ?? []).joined(separator: ","))")
        guard let id = ds?["dsid"] else { throw FMError.bad("iCloud didn't return an account id.") }
        dsid = "\(id)"
        guard let fm = web?["findme"] as? [String: Any], let url = fm["url"] as? String, !url.isEmpty else {
            throw FMError.bad("This account has no Find My service listed.")
        }
        root = url.replacingOccurrences(of: ":443", with: "")
        webMode = false
        UserDefaults.standard.set(false, forKey: "fmWebMode")
        UserDefaults.standard.set(false, forKey: "fmWebSignIn")
        UserDefaults.standard.set(sessionToken, forKey: "fmSessionToken")
        save()
        FindMyLog.log("Signed in natively. Find My server: \(URL(string: root ?? "")?.host ?? "?")")
    }

    /// Each fresh sign-in makes Apple email "signed in to iCloud via a web browser", so this is
    /// rationed: at most once every 6 hours unless you asked for it (pull to refresh in the app).
    /// It first reuses Apple's session token (no password), then the saved password.
    func silentRelogin(userAsked: Bool) async -> Bool {
        let last = UserDefaults.standard.object(forKey: "fmLastRelogin") as? Date ?? .distantPast
        if !userAsked, Date().timeIntervalSince(last) < 6 * 3600 {
            FindMyLog.log("Session needs a new sign-in; holding off until \((last + 6 * 3600).formatted(date: .omitted, time: .shortened)) to avoid Apple sign-in emails")
            return false
        }
        UserDefaults.standard.set(Date(), forKey: "fmLastRelogin")
        if !sessionToken.isEmpty {
            FindMyLog.log("Renewing the iCloud session with the saved token")
            do { try await finishLogin(); return true }
            catch { FindMyLog.log("Token renewal failed: \(error.localizedDescription)") }
        }
        guard let id = UserDefaults.standard.string(forKey: "fmAppleID"), let pw = FMKeychain.get(id) else { return false }
        FindMyLog.log("Signing in again with the saved Apple ID")
        do {
            if case .signedIn = try await login(appleID: id, password: pw) { return true }
            FindMyLog.log("Apple wants a new code; sign in again from the Devices tab")
        } catch {
            FindMyLog.log("Silent sign-in failed: \(error.localizedDescription)")
        }
        return false
    }

    // MARK: HTTP

    private func query(withDSID: Bool) -> [URLQueryItem] {
        var q = [URLQueryItem(name: "clientBuildNumber", value: FMConst.buildNumber),
                 URLQueryItem(name: "clientMasteringNumber", value: FMConst.masteringNumber),
                 URLQueryItem(name: "clientId", value: clientId)]
        if withDSID, let dsid { q.append(URLQueryItem(name: "dsid", value: dsid)) }
        return q
    }

    /// Native request first; if iCloud rejects the copied cookies, repeat it from inside the
    /// icloud.com page and, when that works, keep doing it that way.
    private func send(_ url: URL, body: Data?) async throws -> (Data, FMStatus) {
        if webMode { return try await viaWeb(url, body: body) }
        let (data, http) = try await sendNative(url, body: body)
        // Only for sessions that came from Apple's web page. A native sign-in never loads
        // icloud.com in the background (each page load can count as a new browser sign-in).
        if [401, 421, 450].contains(http.statusCode), UserDefaults.standard.bool(forKey: "fmWebSignIn") {
            FindMyLog.log("Native call got HTTP \(http.statusCode), trying from the iCloud page")
            if let (d2, st) = try? await viaWeb(url, body: body), st.statusCode == 200 {
                webMode = true
                UserDefaults.standard.set(true, forKey: "fmWebMode")
                FindMyLog.log("Working through the iCloud page from now on")
                return (d2, st)
            }
            FindMyLog.log("The iCloud page didn't get through either")
        }
        return (data, FMStatus(statusCode: http.statusCode))
    }

    private func viaWeb(_ url: URL, body: Data?) async throws -> (Data, FMStatus) {
        let (d, s) = try await FindMyWebBridge.shared.post(url, body: body)
        FindMyLog.log("page call \(url.path.split(separator: "/").last.map(String.init) ?? "") -> HTTP \(s)")
        return (d, FMStatus(statusCode: s))
    }

    private func sendNative(_ url: URL, body: Data?) async throws -> (Data, HTTPURLResponse) {
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
