import Foundation

public struct ManifestStore: Sendable {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder = enc
        decoder = JSONDecoder()
    }

    public func load(from url: URL) throws -> ProjectManifest {
        let data = try Data(contentsOf: url)
        return try decoder.decode(ProjectManifest.self, from: data)
    }

    public func save(_ manifest: ProjectManifest, to url: URL) throws {
        let data = try encoder.encode(manifest)
        try data.write(to: url, options: .atomic)
    }
}
