import Foundation

/// The wire format between the watch and the phone.
///
/// `WCSession` dictionaries only carry property-list types, so everything
/// travels as JSON `Data` under a known key. Keeping the encoding in one
/// place means the two session managers cannot drift apart.
enum ConnectivityPayload {
    static let readingKey = "reading"
    static let predictionKey = "prediction"
    static let errorKey = "error"

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func encode<T: Encodable>(_ value: T, key: String) throws -> [String: Any] {
        [key: try encoder.encode(value)]
    }

    static func decode<T: Decodable>(_ type: T.Type, from message: [String: Any], key: String) -> T? {
        guard let data = message[key] as? Data else { return nil }
        return try? decoder.decode(type, from: data)
    }
}
