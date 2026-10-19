import Foundation
import CoreBluetooth

/// LARQ-specific Bluetooth bits that are safe and useful: service UUIDs, standard battery,
/// and the one command we actually want, "turn power-saving off", which is the likely reason
/// the cap keeps dropping its link.
///
/// Deliberately scoped. The cap also exposes UV activation, firmware (DFU) and factory-reset
/// commands over this same pipe. Those drive the UV-C emitter and its safety limits, so they
/// are intentionally not implemented here.
enum Larq {
    // Nordic UART service the cap talks over.
    static let uartService = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    static let uartWrite   = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E") // phone -> cap
    static let uartNotify  = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E") // cap -> phone

    // Standard BLE battery service.
    static let batteryService = CBUUID(string: "180F")
    static let batteryLevel   = CBUUID(string: "2A19")

    static let allServices = [uartService, batteryService]

    /// Builds a CapBleRequest wrapping RequestSetCapPowerSavingMode{ mode = OFF }.
    ///
    /// Wire format, from the app's own protobuf schema:
    ///   RequestSetCapPowerSavingMode { CapPowerSavingMode mode = 1; }   OFF = 1
    ///   google.protobuf.Any          { string type_url = 1; bytes value = 2; }
    ///   CapBleRequest                { fixed32 requestId = 1; Any body = 2; }
    static func powerSavingOff(requestId: UInt32 = UInt32.random(in: 1...UInt32.max)) -> Data {
        // RequestSetCapPowerSavingMode { mode = OFF(1) } -> field 1, varint
        let inner: [UInt8] = [0x08, 0x01]

        // Any
        let typeURL = Array("type.googleapis.com/RequestSetCapPowerSavingMode".utf8)
        var any: [UInt8] = []
        any += [0x0A] + varint(typeURL.count) + typeURL   // field 1: type_url (string)
        any += [0x12] + varint(inner.count) + inner        // field 2: value (bytes)

        // CapBleRequest
        var req: [UInt8] = []
        req += [0x0D] + leFixed32(requestId)               // field 1: requestId (fixed32)
        req += [0x12] + varint(any.count) + any            // field 2: body (Any)
        return Data(req)
    }

    private static func varint(_ value: Int) -> [UInt8] {
        var v = UInt(value), out: [UInt8] = []
        repeat {
            var b = UInt8(v & 0x7F); v >>= 7
            if v != 0 { b |= 0x80 }
            out.append(b)
        } while v != 0
        return out
    }

    private static func leFixed32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }
}
