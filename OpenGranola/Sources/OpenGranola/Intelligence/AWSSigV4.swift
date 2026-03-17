import Foundation
import CryptoKit

/// Lightweight AWS Signature Version 4 request signing using CryptoKit.
enum AWSSigV4 {

    /// Signs a URLRequest in-place with AWS SigV4 authentication headers.
    static func sign(
        request: inout URLRequest,
        body: Data,
        accessKeyId: String,
        secretAccessKey: String,
        region: String,
        service: String
    ) {
        let now = Date()
        let amzDate = amzDateString(from: now)
        let dateStamp = Self.dateStamp(from: now)

        // Set required headers before computing signature
        request.setValue(amzDate, forHTTPHeaderField: "X-Amz-Date")
        let bodyHash = sha256Hex(body)
        request.setValue(bodyHash, forHTTPHeaderField: "X-Amz-Content-Sha256")

        guard let url = request.url, let host = url.host else { return }
        request.setValue(host, forHTTPHeaderField: "Host")

        let method = request.httpMethod ?? "POST"
        let canonicalURI = Self.canonicalURI(from: url)
        let queryString = url.query ?? ""

        // Canonical headers: sorted lowercase, only sign host + content-type + x-amz-*
        var headerMap: [String: String] = [:]
        if let allHeaders = request.allHTTPHeaderFields {
            for (key, value) in allHeaders {
                let lk = key.lowercased()
                if lk == "host" || lk == "content-type" || lk.hasPrefix("x-amz-") {
                    headerMap[lk] = value.trimmingCharacters(in: .whitespaces)
                }
            }
        }

        let sortedNames = headerMap.keys.sorted()
        let canonicalHeaders = sortedNames.map { "\($0):\(headerMap[$0]!)\n" }.joined()
        let signedHeaders = sortedNames.joined(separator: ";")

        let canonicalRequest = [
            method, canonicalURI, queryString,
            canonicalHeaders, signedHeaders, bodyHash
        ].joined(separator: "\n")

        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256", amzDate, scope,
            sha256Hex(Data(canonicalRequest.utf8))
        ].joined(separator: "\n")

        // Derive signing key via HMAC chain
        let kDate = hmac(key: Data("AWS4\(secretAccessKey)".utf8), data: Data(dateStamp.utf8))
        let kRegion = hmac(key: kDate, data: Data(region.utf8))
        let kService = hmac(key: kRegion, data: Data(service.utf8))
        let kSigning = hmac(key: kService, data: Data("aws4_request".utf8))

        let signature = hmacHex(key: kSigning, data: Data(stringToSign.utf8))

        request.setValue(
            "AWS4-HMAC-SHA256 Credential=\(accessKeyId)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
            forHTTPHeaderField: "Authorization"
        )
    }

    // MARK: - Helpers

    private static func canonicalURI(from url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "/" }
        let path = components.percentEncodedPath
        return path.isEmpty ? "/" : path
    }

    private static func amzDateString(from date: Date) -> String {
        let fmt = DateFormatter()
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return fmt.string(from: date)
    }

    private static func dateStamp(from date: Date) -> String {
        let fmt = DateFormatter()
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyyMMdd"
        return fmt.string(from: date)
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }

    private static func hmac(key: Data, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    private static func hmacHex(key: Data, data: Data) -> String {
        HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key))
            .compactMap { String(format: "%02x", $0) }.joined()
    }
}
