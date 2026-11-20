import Foundation

actor TapeStore {
    private let url: URL?
    private var lastSaved = 0

    init(url: URL?) { self.url = url }

    func load() throws -> TapeBook {
        guard let url else { return TapeBook() }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return TapeBook()
        }
        return try Self.decode(data)
    }

    static func decode(_ data: Data) throws -> TapeBook {
        let decoder = JSONDecoder()
        struct Version: Decodable { let version: Int? }
        let version = try decoder.decode(Version.self, from: data).version ?? 0
        guard version <= 1, version >= 0 else { throw TapeIssue.version }
        var book: TapeBook
        if version == 0 {
            struct Legacy: Decodable {
                let tapes: [Tape]
                let currentID: UUID
                let useDays: Set<String>?
                let detailShares: Int?
                let ratingRequested: Bool?
            }
            let legacy = try decoder.decode(Legacy.self, from: data)
            book = TapeBook()
            book.tapes = legacy.tapes
            book.currentID = legacy.currentID
            book.useDays = legacy.useDays ?? []
            book.detailShares = legacy.detailShares ?? 0
            book.ratingRequested = legacy.ratingRequested ?? false
        } else {
            book = try decoder.decode(TapeBook.self, from: data)
        }
        let ids = Set(book.tapes.map(\.id))
        guard ids.count == book.tapes.count, ids.contains(book.currentID),
              book.tapes.allSatisfy({ $0.remaining >= 0 && Set($0.lines.map(\.id)).count == $0.lines.count }) else {
            throw TapeIssue.invalidFile
        }
        for index in book.tapes.indices {
            let updated = book.tapes[index].updated
            book.tapes[index].recalculate()
            book.tapes[index].updated = updated
        }
        return book
    }

    func save(_ book: TapeBook, revision: Int) throws {
        guard let url, revision > lastSaved else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(book).write(to: url, options: .atomic)
        lastSaved = revision
    }

    static func readImport(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<Data, Error> = .failure(TapeIssue.invalidFile)
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinated in
            result = Result {
                let size = try coordinated.resourceValues(forKeys: [.fileSizeKey]).fileSize
                if let size, size > TapeTransfer.fileLimit { throw TapeIssue.tooLarge }
                let handle = try FileHandle(forReadingFrom: coordinated)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: TapeTransfer.fileLimit + 1) ?? Data()
                guard data.count <= TapeTransfer.fileLimit else { throw TapeIssue.tooLarge }
                return data
            }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }
}
