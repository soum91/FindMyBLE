import Foundation
import CryptoKit
import CommonCrypto

// SRP-6a as Apple's sign-in uses it (RFC 5054 2048-bit group, SHA-256, no username in x).
// Checked against the Python "srp" library's output in Tests/ (run by the CI compile check).

/// Minimal unsigned big integer, little-endian 32-bit limbs. Only what SRP needs.
struct BigUInt: Equatable {
    var w: [UInt32]

    init(_ limbs: [UInt32]) { w = limbs; trim() }
    init(_ v: UInt32) { w = v == 0 ? [] : [v] }
    init(bytes: [UInt8]) {
        var limbs: [UInt32] = []
        var i = bytes.count
        while i > 0 {
            var v: UInt32 = 0
            let lo = max(0, i - 4)
            for b in bytes[lo..<i] { v = (v << 8) | UInt32(b) }
            limbs.append(v)
            i = lo
        }
        w = limbs
        trim()
    }

    mutating func trim() { while let l = w.last, l == 0 { w.removeLast() } }
    var isZero: Bool { w.isEmpty }

    /// Big-endian, no leading zeros (like Python's long_to_bytes).
    var bytes: [UInt8] {
        var out: [UInt8] = []
        for l in w.reversed() { out += [UInt8(l >> 24), UInt8((l >> 16) & 255), UInt8((l >> 8) & 255), UInt8(l & 255)] }
        while let f = out.first, f == 0 { out.removeFirst() }
        return out
    }

    func padded(_ n: Int) -> [UInt8] {
        let b = bytes
        return [UInt8](repeating: 0, count: max(0, n - b.count)) + b
    }

    static func cmp(_ a: [UInt32], _ b: [UInt32]) -> Int {
        var a = a, b = b
        while let l = a.last, l == 0 { a.removeLast() }
        while let l = b.last, l == 0 { b.removeLast() }
        if a.count != b.count { return a.count < b.count ? -1 : 1 }
        for i in stride(from: a.count - 1, through: 0, by: -1) where a[i] != b[i] { return a[i] < b[i] ? -1 : 1 }
        return 0
    }

    static func < (a: BigUInt, b: BigUInt) -> Bool { cmp(a.w, b.w) < 0 }

    static func + (a: BigUInt, b: BigUInt) -> BigUInt {
        var out: [UInt32] = []
        var c: UInt64 = 0
        for i in 0..<max(a.w.count, b.w.count) {
            let s = UInt64(i < a.w.count ? a.w[i] : 0) + UInt64(i < b.w.count ? b.w[i] : 0) + c
            out.append(UInt32(truncatingIfNeeded: s)); c = s >> 32
        }
        if c > 0 { out.append(UInt32(c)) }
        return BigUInt(out)
    }

    /// a - b, requires a >= b.
    static func - (a: BigUInt, b: BigUInt) -> BigUInt {
        var out: [UInt32] = []
        var borrow: Int64 = 0
        for i in 0..<a.w.count {
            var d = Int64(a.w[i]) - Int64(i < b.w.count ? b.w[i] : 0) - borrow
            if d < 0 { d += 1 << 32; borrow = 1 } else { borrow = 0 }
            out.append(UInt32(d))
        }
        return BigUInt(out)
    }

    static func * (a: BigUInt, b: BigUInt) -> BigUInt {
        if a.isZero || b.isZero { return BigUInt([]) }
        var out = [UInt32](repeating: 0, count: a.w.count + b.w.count)
        for i in 0..<a.w.count {
            var c: UInt64 = 0
            for j in 0..<b.w.count {
                let s = UInt64(out[i + j]) + UInt64(a.w[i]) * UInt64(b.w[j]) + c
                out[i + j] = UInt32(truncatingIfNeeded: s); c = s >> 32
            }
            out[i + b.w.count] = UInt32(truncatingIfNeeded: c)
        }
        return BigUInt(out)
    }
}

/// Arithmetic modulo an odd number, using Montgomery multiplication.
struct Montgomery {
    let n: Int
    let mod: [UInt32]
    let nprime: UInt32
    let r2: [UInt32]

    init(_ m: BigUInt) {
        n = m.w.count
        mod = m.w
        var x = m.w[0]
        for _ in 0..<5 { x = x &* (2 &- m.w[0] &* x) }
        nprime = 0 &- x
        // R^2 mod m by doubling 1, 64n times.
        var r = [UInt32](repeating: 0, count: m.w.count)
        r[0] = 1
        for _ in 0..<(64 * m.w.count) {
            var carry: UInt32 = 0
            for i in 0..<r.count {
                let nc = r[i] >> 31
                r[i] = (r[i] << 1) | carry
                carry = nc
            }
            if carry != 0 || BigUInt.cmp(r, m.w) >= 0 { r = Montgomery.subtract(r, m.w) }
        }
        r2 = r
    }

    /// a - b over a.count limbs, ignoring a final borrow (which cancels a carry-out).
    private static func subtract(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
        var out = a
        var borrow: Int64 = 0
        for i in 0..<a.count {
            var d = Int64(a[i]) - Int64(i < b.count ? b[i] : 0) - borrow
            if d < 0 { d += 1 << 32; borrow = 1 } else { borrow = 0 }
            out[i] = UInt32(d)
        }
        return out
    }

    func pad(_ x: BigUInt) -> [UInt32] { x.w + [UInt32](repeating: 0, count: n - x.w.count) }

    func mul(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
        var t = [UInt32](repeating: 0, count: n + 2)
        for i in 0..<n {
            var c: UInt64 = 0
            for j in 0..<n {
                let s = UInt64(t[j]) + UInt64(a[j]) * UInt64(b[i]) + c
                t[j] = UInt32(truncatingIfNeeded: s); c = s >> 32
            }
            var s = UInt64(t[n]) + c
            t[n] = UInt32(truncatingIfNeeded: s)
            t[n + 1] = UInt32(truncatingIfNeeded: s >> 32)
            let m = t[0] &* nprime
            s = UInt64(t[0]) + UInt64(m) * UInt64(mod[0])
            c = s >> 32
            for j in 1..<n {
                s = UInt64(t[j]) + UInt64(m) * UInt64(mod[j]) + c
                t[j - 1] = UInt32(truncatingIfNeeded: s); c = s >> 32
            }
            s = UInt64(t[n]) + c
            t[n - 1] = UInt32(truncatingIfNeeded: s)
            t[n] = UInt32(truncatingIfNeeded: UInt64(t[n + 1]) + (s >> 32))
            t[n + 1] = 0
        }
        var out = Array(t[0..<n])
        if t[n] != 0 || BigUInt.cmp(out, mod) >= 0 { out = Montgomery.subtract(out, mod) }
        return out
    }

    /// a * b mod m, with a and b already below m.
    func mulmod(_ a: BigUInt, _ b: BigUInt) -> BigUInt {
        BigUInt(mul(mul(pad(a), r2), pad(b)))
    }

    /// base^exp mod m, base below m.
    func powmod(_ base: BigUInt, _ exp: BigUInt) -> BigUInt {
        let one = [UInt32(1)] + [UInt32](repeating: 0, count: n - 1)
        let bm = mul(pad(base), r2)
        var result = mul(one, r2)
        for limb in exp.w.reversed() {
            for bit in stride(from: 31, through: 0, by: -1) {
                result = mul(result, result)
                if (limb >> UInt32(bit)) & 1 == 1 { result = mul(result, bm) }
            }
        }
        return BigUInt(mul(result, one))
    }
}

enum SRP {
    static let nHex = "ac6bdb41324a9a9bf166de5e1389582faf72b6651987ee07fc3192943db56050a37329cbb4a099ed8193e0757767a13dd52312ab4b03310dcd7f48a9da04fd50e8083969edb767b0cf6095179a163ab3661a05fbd5faaae82918a9962f0b93b855f97993ec975eeaa80d740adbf4ff747359d041d5c33ea71d281e446b14773bca97b43a23fb801676bd207a436c6481f1d2b9078717461a5b9d32e688f87748544523b524b0d57d5ea77a2775d2ecfa032cfbdbf52fb3786160279004e57ae6af874e7303ce53299ccc041c7bc308d82a5698f3a8d0c38271ae35f8e9dbfbb694b5c803d89f7ae435de236d525f54759b65e372fcd68ef20fa7111f9e4aff73"

    static func hex(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16) ?? 0)
            i = j
        }
        return out
    }

    static func sha(_ parts: [UInt8]...) -> [UInt8] {
        var h = SHA256()
        for p in parts { h.update(data: Data(p)) }
        return Array(h.finalize())
    }

    /// Apple's password step: SHA-256 of the password (hex text for "s2k_fo"), then PBKDF2-SHA256.
    static func derivePassword(_ password: String, salt: [UInt8], iterations: Int, protocolName: String) -> [UInt8] {
        var pw = sha(Array(password.utf8))
        if protocolName == "s2k_fo" { pw = Array(pw.map { String(format: "%02x", $0) }.joined().utf8) }
        var out = [UInt8](repeating: 0, count: 32)
        let status = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw.map { Int8(bitPattern: $0) }, pw.count,
                                          salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                                          UInt32(iterations), &out, 32)
        return status == 0 ? out : []
    }

    struct Client {
        let a: BigUInt
        let A: BigUInt
        private let N = BigUInt(bytes: SRP.hex(SRP.nHex))
        private let mont: Montgomery

        /// `secret` is the 32 random bytes; tests pass fixed ones.
        init(secret: [UInt8]? = nil) {
            let n = BigUInt(bytes: SRP.hex(SRP.nHex))
            mont = Montgomery(n)
            var s = secret ?? []
            if s.isEmpty {
                s = (0..<32).map { _ in UInt8.random(in: 0...255) }
            }
            a = BigUInt(bytes: s)
            A = mont.powmod(BigUInt(2), a)
        }

        /// M1 and the server proof M2 we expect back. Nil if the server's B is invalid.
        func respond(account: String, salt: [UInt8], B Bbytes: [UInt8], key: [UInt8]) -> (m1: [UInt8], m2: [UInt8])? {
            let B = BigUInt(bytes: Bbytes)
            guard B < N, !B.isZero else { return nil }
            let width = 256
            let u = BigUInt(bytes: SRP.sha(A.padded(width), B.padded(width)))
            if u.isZero { return nil }
            let k = BigUInt(bytes: SRP.sha(N.padded(width), BigUInt(2).padded(width)))
            let x = BigUInt(bytes: SRP.sha(salt, SRP.sha([UInt8(ascii: ":")] + key)))
            let gx = mont.powmod(BigUInt(2), x)
            let kgx = mont.mulmod(k, gx)   // k is 256 bits, always below N
            let base = BigUInt.cmp(B.w, kgx.w) >= 0 ? B - kgx : B + N - kgx
            let exp = a + u * x
            let S = mont.powmod(base, exp)
            let K = SRP.sha(S.bytes)
            let hN = SRP.sha(N.bytes)
            let hg = SRP.sha([UInt8](repeating: 0, count: 255) + [2])
            let xor = zip(hN, hg).map { $0 ^ $1 }
            let m1 = SRP.sha(xor, SRP.sha(Array(account.utf8)), salt, A.bytes, B.bytes, K)
            let m2 = SRP.sha(A.bytes, m1, K)
            return (m1, m2)
        }
    }
}
