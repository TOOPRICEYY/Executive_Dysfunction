import Foundation

struct BlockPageHTTPRequest: Equatable, Sendable {
    var method: String
    var target: String
    var headers: [String: String]
    var body: Data

    var host: String? {
        headers["host"].flatMap(Self.normalizedHostHeader)
    }

    var formValues: [String: String]? {
        guard headers["content-type"]?
            .lowercased()
            .hasPrefix("application/x-www-form-urlencoded") == true,
              let text = String(data: body, encoding: .utf8) else { return nil }
        var result: [String: String] = [:]
        for pair in text.split(separator: "&", omittingEmptySubsequences: false) {
            let components = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard components.count == 2,
                  let key = Self.decodeFormComponent(String(components[0])),
                  let value = Self.decodeFormComponent(String(components[1])),
                  !key.isEmpty,
                  result[key] == nil else { return nil }
            result[key] = value
        }
        return result
    }

    func hasSameOrigin(_ origin: String?) -> Bool {
        guard let origin,
              let host,
              let components = URLComponents(string: origin),
              components.user == nil,
              components.password == nil,
              components.path.isEmpty,
              components.query == nil,
              components.fragment == nil,
              components.scheme == "https" || components.scheme == "http",
              let originHost = components.host.flatMap(BlockPageHostPolicy.normalizedDomain) else {
            return false
        }
        if let fetchSite = headers["sec-fetch-site"]?.lowercased(),
           fetchSite != "same-origin" && fetchSite != "none" {
            return false
        }
        return originHost == host
    }

    private static func normalizedHostHeader(_ raw: String) -> String? {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasPrefix("[") { return nil }
        if let colon = host.lastIndex(of: ":"),
           host[host.index(after: colon)...].allSatisfy(\.isNumber) {
            host = String(host[..<colon])
        }
        return BlockPageHostPolicy.normalizedDomain(host)
    }

    private static func decodeFormComponent(_ raw: String) -> String? {
        raw.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
    }
}

enum BlockPageHTTPRequestState: Equatable {
    case incomplete
    case complete(length: Int)
}

enum BlockPageHTTPRequestError: Error, Equatable {
    case tooLarge
    case malformed
    case unsupportedTransferEncoding
    case missingContentLength
}

enum BlockPageHTTPRequestParser {
    static let maximumHeaderBytes = 16_384
    static let maximumBodyBytes = 16_384
    static let maximumRequestBytes = maximumHeaderBytes + maximumBodyBytes

    static func state(for data: Data) throws -> BlockPageHTTPRequestState {
        guard data.count <= maximumRequestBytes else { throw BlockPageHTTPRequestError.tooLarge }
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) else {
            guard data.count <= maximumHeaderBytes else { throw BlockPageHTTPRequestError.tooLarge }
            return .incomplete
        }
        let headerEnd = headerRange.upperBound
        guard headerEnd <= maximumHeaderBytes else { throw BlockPageHTTPRequestError.tooLarge }
        let headerData = data[..<headerEnd]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw BlockPageHTTPRequestError.malformed
        }
        let fields = try parseHeaderFields(headerText)
        if let encoding = fields["transfer-encoding"],
           encoding.lowercased() != "identity" {
            throw BlockPageHTTPRequestError.unsupportedTransferEncoding
        }
        let requestMethod = headerText.prefix { $0 != " " }.uppercased()
        let contentLength: Int
        if let rawLength = fields["content-length"] {
            guard let value = Int(rawLength), value >= 0, value <= maximumBodyBytes else {
                throw BlockPageHTTPRequestError.tooLarge
            }
            contentLength = value
        } else if requestMethod == "POST" {
            throw BlockPageHTTPRequestError.missingContentLength
        } else {
            contentLength = 0
        }
        let total = headerEnd + contentLength
        guard total <= maximumRequestBytes else { throw BlockPageHTTPRequestError.tooLarge }
        return data.count >= total ? .complete(length: total) : .incomplete
    }

    static func parse(_ data: Data) throws -> BlockPageHTTPRequest {
        guard case let .complete(length) = try state(for: data) else {
            throw BlockPageHTTPRequestError.malformed
        }
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) else {
            throw BlockPageHTTPRequestError.malformed
        }
        let headerEnd = headerRange.upperBound
        guard let headerText = String(data: data[..<headerEnd], encoding: .utf8) else {
            throw BlockPageHTTPRequestError.malformed
        }
        let lines = headerText.components(separatedBy: "\r\n")
        let requestParts = lines[0].split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count == 3,
              requestParts[2].hasPrefix("HTTP/1."),
              !requestParts[0].isEmpty,
              !requestParts[1].isEmpty else {
            throw BlockPageHTTPRequestError.malformed
        }
        let headers = try parseHeaderFields(headerText)
        guard headers["host"] != nil else { throw BlockPageHTTPRequestError.malformed }
        return BlockPageHTTPRequest(
            method: String(requestParts[0]).uppercased(),
            target: String(requestParts[1]),
            headers: headers,
            body: Data(data[headerEnd..<length])
        )
    }

    private static func parseHeaderFields(_ text: String) throws -> [String: String] {
        let lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { throw BlockPageHTTPRequestError.malformed }
        var result: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let first = line.first,
                  first != " ",
                  first != "\t",
                  let colon = line.firstIndex(of: ":") else {
                throw BlockPageHTTPRequestError.malformed
            }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty,
                  name.utf8.allSatisfy({ byte in
                      (byte >= 0x61 && byte <= 0x7a) || byte == 0x2d
                  }),
                  result[name] == nil else {
                throw BlockPageHTTPRequestError.malformed
            }
            result[name] = value
        }
        return result
    }
}

enum BlockPageHTTPResponse {
    static func data(
        status: Int,
        reason: String,
        body: String,
        additionalHeaders: [String: String] = [:]
    ) -> Data {
        let bodyData = Data(body.utf8)
        var headers = [
            "Cache-Control": "no-store, must-revalidate",
            "Connection": "close",
            "Content-Length": String(bodyData.count),
            "Content-Security-Policy": "default-src 'none'; script-src \(BlockPageTypingGuard.cspSource); style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'",
            "Content-Type": "text/html; charset=utf-8",
            "Permissions-Policy": "camera=(), microphone=(), geolocation=()",
            // no-referrer makes ordinary browser form POSTs send Origin: null,
            // which correctly fails our CSRF check. Preserve same-origin form
            // provenance without disclosing referrers to other sites.
            "Referrer-Policy": "same-origin",
            "X-Content-Type-Options": "nosniff",
            "X-Frame-Options": "DENY"
        ]
        additionalHeaders.forEach { headers[$0.key] = $0.value }
        let lines = headers.keys.sorted().compactMap { name in
            headers[name].map { "\(name): \($0)\r\n" }
        }.joined()
        return Data("HTTP/1.1 \(status) \(reason)\r\n\(lines)\r\n".utf8) + bodyData
    }
}
