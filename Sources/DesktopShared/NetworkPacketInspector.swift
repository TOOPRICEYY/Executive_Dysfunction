import Foundation

enum NetworkPacketInspector {
    struct TransportView: Equatable {
        var transportProtocol: UInt8
        var destinationPort: Int?
        var payload: Data
        var isFragment: Bool
    }

    static func shouldDropOutboundPacket(
        _ packet: Data,
        policy: DesktopEnforcementPolicy,
        at date: Date = Date()
    ) -> Bool {
        guard policy.hasActiveWebRestrictions(at: date),
              let view = transportView(in: packet) else { return false }

        if view.isFragment { return true }
        // IP-in-IP, IPv6 tunnelling, GRE and ESP are common ways to carry a
        // bypass tunnel outside the content filter's hostname visibility.
        if [4, 41, 47, 50].contains(view.transportProtocol) { return true }

        guard let port = view.destinationPort else { return false }
        if [784, 853, 8853].contains(port) { return true } // DoQ / DoT
        // UDP 443 is ordinary QUIC web traffic. Dropping it globally is not a
        // safe enforcement strategy: some browsers do not promptly retry over
        // TCP, which turns one active website rule into a total web outage.
        if [500, 1194, 1701, 4500, 51820].contains(port) { return true } // common VPN defaults
        if view.transportProtocol == 6 && port == 1723 { return true } // PPTP

        if port == 53 {
            guard let hostname = NetworkHostnameInspector.dnsQueryName(in: view.payload) else {
                return policy.hasActiveFortress(at: date)
            }
            return policy.blocksNetworkHostname(hostname, at: date)
        }
        return false
    }

    static func transportView(in packet: Data) -> TransportView? {
        let bytes = [UInt8](packet)
        guard !bytes.isEmpty else { return nil }
        switch bytes[0] >> 4 {
        case 4: return ipv4View(bytes)
        case 6: return ipv6View(bytes)
        default: return nil
        }
    }

    private static func ipv4View(_ bytes: [UInt8]) -> TransportView? {
        guard bytes.count >= 20 else { return nil }
        let headerLength = Int(bytes[0] & 0x0F) * 4
        guard headerLength >= 20, headerLength <= bytes.count else { return nil }
        let fragmentField = int16(bytes, 6)
        let isFragment = fragmentField & 0x3FFF != 0
        return transportView(
            bytes: bytes,
            transportProtocol: bytes[9],
            transportOffset: headerLength,
            isFragment: isFragment
        )
    }

    private static func ipv6View(_ bytes: [UInt8]) -> TransportView? {
        guard bytes.count >= 40 else { return nil }
        var nextHeader = bytes[6]
        var offset = 40
        var isFragment = false

        for _ in 0..<8 {
            switch nextHeader {
            case 0, 43, 60:
                guard offset + 2 <= bytes.count else { return nil }
                let length = (Int(bytes[offset + 1]) + 1) * 8
                guard length >= 8, offset + length <= bytes.count else { return nil }
                nextHeader = bytes[offset]
                offset += length
            case 44:
                guard offset + 8 <= bytes.count else { return nil }
                let fragmentField = int16(bytes, offset + 2)
                isFragment = true
                nextHeader = bytes[offset]
                offset += 8
                if fragmentField & 0xFFF8 != 0 {
                    return TransportView(
                        transportProtocol: nextHeader,
                        destinationPort: nil,
                        payload: Data(),
                        isFragment: true
                    )
                }
            case 51:
                guard offset + 2 <= bytes.count else { return nil }
                let length = (Int(bytes[offset + 1]) + 2) * 4
                guard length >= 8, offset + length <= bytes.count else { return nil }
                nextHeader = bytes[offset]
                offset += length
            default:
                return transportView(
                    bytes: bytes,
                    transportProtocol: nextHeader,
                    transportOffset: offset,
                    isFragment: isFragment
                )
            }
        }
        return nil
    }

    private static func transportView(
        bytes: [UInt8],
        transportProtocol: UInt8,
        transportOffset: Int,
        isFragment: Bool
    ) -> TransportView? {
        switch transportProtocol {
        case 6: // TCP
            guard transportOffset + 20 <= bytes.count else { return nil }
            let headerLength = Int(bytes[transportOffset + 12] >> 4) * 4
            guard headerLength >= 20, transportOffset + headerLength <= bytes.count else { return nil }
            return TransportView(
                transportProtocol: transportProtocol,
                destinationPort: int16(bytes, transportOffset + 2),
                payload: Data(bytes[(transportOffset + headerLength)...]),
                isFragment: isFragment
            )
        case 17: // UDP
            guard transportOffset + 8 <= bytes.count else { return nil }
            return TransportView(
                transportProtocol: transportProtocol,
                destinationPort: int16(bytes, transportOffset + 2),
                payload: Data(bytes[(transportOffset + 8)...]),
                isFragment: isFragment
            )
        default:
            return TransportView(
                transportProtocol: transportProtocol,
                destinationPort: nil,
                payload: Data(),
                isFragment: isFragment
            )
        }
    }

    private static func int16(_ bytes: [UInt8], _ index: Int) -> Int {
        guard index + 1 < bytes.count else { return 0 }
        return Int(bytes[index]) << 8 | Int(bytes[index + 1])
    }
}
