import Foundation

final class TranscriptionJobStore: @unchecked Sendable {
    private let fileManager: FileManager
    private let storeURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default, storeURL: URL? = nil) throws {
        self.fileManager = fileManager

        if let storeURL {
            self.storeURL = storeURL
        } else {
            let applicationSupport = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let directory = applicationSupport.appending(
                path: "Sotto/TranscriptionJobs",
                directoryHint: .isDirectory
            )
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            self.storeURL = directory.appending(path: "jobs.json")
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func load() throws -> [TranscriptionJob] {
        guard fileManager.fileExists(atPath: storeURL.path) else {
            return []
        }
        return try decoder.decode([TranscriptionJob].self, from: Data(contentsOf: storeURL))
    }

    func save(_ jobs: [TranscriptionJob]) throws {
        let data = try encoder.encode(jobs)
        try data.write(to: storeURL, options: .atomic)
    }
}
