import Foundation

enum NetworkHostnameInspector {
    enum TLSClientHelloResult: Equatable {
        case notTLS
        case incomplete(requiredBytes: Int)
        case serverName(String)
        case encryptedClientHello
        case missingServerName
        case malformed
    }

    /// TLS records are limited to 16 KiB of plaintext, but a ClientHello can
    /// span records. This cap comfortably covers current browser hellos while
    /// preventing a peer from making the filter retain an unbounded prefix.
    static let maximumClientHelloBytes = 64 * 1_024

    static func hostname(in data: Data) -> String? {
        httpHost(in: data) ?? tlsServerName(in: data) ?? dnsQueryName(in: data)
    }

    /// True when a TLS ClientHello carries the `encrypted_client_hello`
    /// extension (RFC 9460, type 0xFE0D).
    ///
    /// ECH moves the real server name inside an encrypted payload and leaves a
    /// generic public name in the visible SNI, so a name-based rule silently
    /// stops matching. A client only sends it after deliberately opting into
    /// DoH plus ECH, which is precisely the configuration used to slip past a
    /// website rule.
    static func usesEncryptedClientHello(in data: Data) -> Bool {
        tlsClientHello(in: data) == .encryptedClientHello
    }

    /// Classifies a TLS ClientHello without treating a partial record as an
    /// unrecognised payload. `requiredBytes` is an absolute prefix length: a
    /// data provider that has passed zero bytes can ask Network Extension to
    /// present that larger prefix on its next callback.
    static func tlsClientHello(in data: Data) -> TLSClientHelloResult {
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else { return .notTLS }

        // A short prefix beginning like a handshake record is still TLS; the
        // record header tells us its exact size once all five bytes arrive.
        guard bytes[0] == 22 else { return .notTLS }
        if bytes.count >= 2, bytes[1] != 3 { return .notTLS }
        guard bytes.count >= 5 else { return .incomplete(requiredBytes: 5) }

        var recordOffset = 0
        var handshake: [UInt8] = []
        var handshakeLength: Int?

        while true {
            guard recordOffset + 5 <= bytes.count else {
                return incompleteOrMalformed(recordOffset + 5)
            }
            guard bytes[recordOffset] == 22, bytes[recordOffset + 1] == 3 else {
                return .malformed
            }
            let recordLength = int16(bytes, recordOffset + 3)
            guard recordLength > 0, recordLength <= 16_384 else { return .malformed }
            let recordEnd = recordOffset + 5 + recordLength
            guard recordEnd <= bytes.count else { return incompleteOrMalformed(recordEnd) }
            handshake += bytes[(recordOffset + 5)..<recordEnd]

            if handshakeLength == nil, handshake.count >= 4 {
                guard handshake[0] == 1 else { return .malformed }
                let bodyLength = Int(handshake[1]) << 16 | Int(handshake[2]) << 8 | Int(handshake[3])
                let totalLength = bodyLength + 4
                guard totalLength <= maximumClientHelloBytes else { return .malformed }
                handshakeLength = totalLength
            }

            if let handshakeLength, handshake.count >= handshakeLength {
                return parseCompleteClientHello(Array(handshake.prefix(handshakeLength)))
            }

            recordOffset = recordEnd
            if recordOffset == bytes.count {
                // The next record header is needed before its exact length is
                // knowable. Browsers write the rest of ClientHello without
                // waiting for the server, so this cannot deadlock a valid TLS
                // handshake.
                return incompleteOrMalformed(recordOffset + 5)
            }
        }
    }

    static func dnsQueryName(in data: Data) -> String? {
        let bytes = [UInt8](data)
        if let name = dnsQueryName(in: bytes, messageOffset: 0) { return name }
        guard bytes.count >= 14 else { return nil }
        let declaredLength = int16(bytes, 0)
        guard declaredLength >= 12, declaredLength <= bytes.count - 2 else { return nil }
        return dnsQueryName(in: bytes, messageOffset: 2)
    }

    private static func httpHost(in data: Data) -> String? {
        guard let text = String(data: data.prefix(16_384), encoding: .utf8) else { return nil }
        for line in text.components(separatedBy: "\r\n") {
            guard line.count >= 5, line.prefix(5).caseInsensitiveCompare("host:") == .orderedSame else { continue }
            let value = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
            let host = value.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
            return host.isEmpty ? nil : host.lowercased()
        }
        return nil
    }

    /// Extracts the SNI host from a complete TLS ClientHello.
    private static func tlsServerName(in data: Data) -> String? {
        guard case let .serverName(name) = tlsClientHello(in: data) else { return nil }
        return name
    }

    private static func incompleteOrMalformed(_ requiredBytes: Int) -> TLSClientHelloResult {
        requiredBytes <= maximumClientHelloBytes
            ? .incomplete(requiredBytes: requiredBytes)
            : .malformed
    }

    private static func parseCompleteClientHello(_ bytes: [UInt8]) -> TLSClientHelloResult {
        guard bytes.count >= 4 + 2 + 32 + 1 else { return .malformed }
        var index = 4 + 2 + 32
        let sessionLength = Int(bytes[index]); index += 1
        guard index + sessionLength + 2 <= bytes.count else { return .malformed }
        index += sessionLength
        let cipherLength = int16(bytes, index); index += 2
        guard cipherLength >= 2, cipherLength.isMultiple(of: 2), index + cipherLength + 1 <= bytes.count else {
            return .malformed
        }
        index += cipherLength
        let compressionLength = Int(bytes[index]); index += 1
        guard compressionLength > 0, index + compressionLength <= bytes.count else { return .malformed }
        index += compressionLength

        // TLS permits a ClientHello without extensions, but such a connection
        // has no enforceable server identity and must not escape a domain rule.
        if index == bytes.count { return .missingServerName }
        guard index + 2 <= bytes.count else { return .malformed }
        let extensionsLength = int16(bytes, index); index += 2
        guard index + extensionsLength == bytes.count else { return .malformed }
        let extensionsEnd = index + extensionsLength
        var serverName: String?
        var hasECH = false

        while index < extensionsEnd {
            guard index + 4 <= extensionsEnd else { return .malformed }
            let type = int16(bytes, index)
            let length = int16(bytes, index + 2)
            index += 4
            guard index + length <= extensionsEnd else { return .malformed }
            if type == 0xFE0D { hasECH = true }
            if type == 0 {
                guard length >= 5 else { return .malformed }
                let extensionEnd = index + length
                let listLength = int16(bytes, index)
                guard index + 2 + listLength == extensionEnd else { return .malformed }
                var nameIndex = index + 2
                while nameIndex < extensionEnd {
                    guard nameIndex + 3 <= extensionEnd else { return .malformed }
                    let nameType = bytes[nameIndex]
                    let nameLength = int16(bytes, nameIndex + 1)
                    nameIndex += 3
                    guard nameIndex + nameLength <= extensionEnd else { return .malformed }
                    if nameType == 0 {
                        guard nameLength > 0 else { return .malformed }
                        guard let decoded = String(
                            bytes: bytes[nameIndex..<(nameIndex + nameLength)],
                            encoding: .utf8
                        ), decoded.utf8.allSatisfy({ byte in
                            byte == 45 || byte == 46 || (byte >= 48 && byte <= 57)
                                || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
                        }) else { return .malformed }
                        serverName = decoded.lowercased()
                    }
                    nameIndex += nameLength
                }
            }
            index += length
        }
        // A visible server name wins, even alongside ECH.
        //
        // Chrome sends the ECH extension on *every* connection as GREASE, to
        // make real ECH indistinguishable from ordinary traffic. It was
        // measured here at 250 bytes next to a plainly readable SNI. Treating
        // the extension's presence as concealment therefore refuses all Chrome
        // browsing, not just concealed connections.
        //
        // Only a hello that offers no readable name at all is concealed. Real
        // ECH still leaves a public outer name, and enforcement matches on
        // that; a domain reachable *only* behind a public ECH name remains a
        // documented limit rather than a reason to block the whole browser.
        if let serverName { return .serverName(serverName) }
        return hasECH ? .encryptedClientHello : .missingServerName
    }

    private static func dnsQueryName(in bytes: [UInt8], messageOffset: Int) -> String? {
        guard messageOffset + 12 <= bytes.count else { return nil }
        let flags = int16(bytes, messageOffset + 2)
        let questionCount = int16(bytes, messageOffset + 4)
        guard flags & 0x8000 == 0, flags & 0x7800 == 0,
              questionCount > 0, questionCount <= 32 else { return nil }

        var index = messageOffset + 12
        var labels: [String] = []
        var wireLength = 0
        while index < bytes.count {
            let length = Int(bytes[index]); index += 1
            if length == 0 { break }
            // Compression pointers aren't valid in ordinary question names.
            guard length <= 63, index + length <= bytes.count else { return nil }
            let labelBytes = bytes[index..<(index + length)]
            guard labelBytes.allSatisfy({ byte in
                (byte >= 45 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
            }) else { return nil }
            labels.append(String(decoding: labelBytes, as: UTF8.self))
            wireLength += length + 1
            guard wireLength <= 253 else { return nil }
            index += length
        }
        guard !labels.isEmpty, index + 4 <= bytes.count else { return nil }
        let queryClass = int16(bytes, index + 2)
        guard queryClass == 1 else { return nil }
        return labels.joined(separator: ".").lowercased()
    }

    private static func int16(_ bytes: [UInt8], _ index: Int) -> Int {
        guard index + 1 < bytes.count else { return 0 }
        return Int(bytes[index]) << 8 | Int(bytes[index + 1])
    }
}
