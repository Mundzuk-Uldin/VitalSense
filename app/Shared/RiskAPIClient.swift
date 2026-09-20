import Foundation

/// Talks to the FastAPI service.
///
/// Both the iPhone and the watch use this: the phone is the normal path, and
/// the watch falls back to it directly when the phone is out of range.
actor RiskAPIClient {
    enum Failure: LocalizedError {
        case badURL(String)
        case http(Int, String)
        case transport(String)
        case decoding(String)

        var errorDescription: String? {
            switch self {
            case .badURL(let raw):
                return "\"\(raw)\" is not a valid server address."
            case .http(let code, let body):
                return "Server returned \(code). \(body)"
            case .transport(let message):
                return "Could not reach the server. \(message)"
            case .decoding(let message):
                return "Could not read the server's reply. \(message)"
            }
        }
    }

    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL) {
        self.baseURL = baseURL
        let config = URLSessionConfiguration.default
        // A hung request should surface as an error the user can act on,
        // not as a spinner that never resolves.
        config.timeoutIntervalForRequest = 12
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    init?(rawBaseURL: String) {
        guard let url = URL(string: rawBaseURL.trimmingCharacters(in: .whitespaces)),
              url.scheme != nil, url.host != nil
        else { return nil }
        self.init(baseURL: url)
    }

    /// FastAPI emits ISO-8601 with fractional seconds, which the built-in
    /// `.iso8601` strategy rejects, so we parse both spellings ourselves.
    ///
    /// The formatters are built inside the closure rather than captured from
    /// outside it: `ISO8601DateFormatter` is not `Sendable`, and the decoding
    /// strategy is a `@Sendable` closure that may run on any thread.
    private static func parseTimestamp(_ raw: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return withFractional.date(from: raw) ?? plain.date(from: raw)
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let date = parseTimestamp(raw) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "Bad date: \(raw)")
                )
            }
            return date
        }
        return decoder
    }()

    func predict(_ reading: VitalsReading) async throws -> RiskPrediction {
        var request = URLRequest(url: baseURL.appendingPathComponent("predict"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: reading.apiPayload())

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw Failure.transport("Unexpected response type.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw Failure.http(http.statusCode, String(body.prefix(300)))
        }

        do {
            return try Self.decoder.decode(RiskPrediction.self, from: data)
        } catch {
            throw Failure.decoding(error.localizedDescription)
        }
    }

    /// Cheap liveness check for the settings screen, so the user can tell a
    /// wrong address apart from a server that is simply not running.
    func ping() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.timeoutInterval = 5
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse
        else { return false }
        return http.statusCode == 200
    }
}
