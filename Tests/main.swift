import Foundation

let v = try! String(contentsOfFile: "Tests/vec.txt").split(separator: "\n").map(String.init)
let (A, B, salt, pw, M, AMK, a) = (v[0], v[1], v[2], v[3], v[4], v[5], v[6])
func h(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

var fail = false
func check(_ name: String, _ got: String, _ want: String) {
    if got == want { print("ok   \(name)") } else { print("FAIL \(name)\n  got  \(got)\n  want \(want)"); fail = true }
}

let c = SRP.Client(secret: SRP.hex(a))
check("A", h(c.A.bytes), A)
let r = c.respond(account: "test@example.com", salt: SRP.hex(salt), B: SRP.hex(B), key: SRP.hex(pw))
check("M1", r.map { h($0.m1) } ?? "nil", M)
check("M2", r.map { h($0.m2) } ?? "nil", AMK)
check("pbkdf2", h(SRP.derivePassword("hunter2", salt: SRP.hex(salt), iterations: 1000, protocolName: "s2k")),
      "03f6902f21442d23cae20dc4856c42770e6211b59ccb40f4d605d2e18deb71e9")
exit(fail ? 1 : 0)
