import Foundation

/// Fundstellen mit dauerhaftem Cache (stale-while-revalidate): `fundstellen` liefert sofort,
/// was lokal liegt, `refresh` lädt nur nach, wenn nichts da oder der Eintrag veraltet ist.
public actor FundstellenRepository {

    public static let maxAge: TimeInterval = 30 * 24 * 3600

    private let api: BlechWikiAPI
    private let db: AppDatabase
    private let now: @Sendable () -> Date
    private var inFlight: [String: Task<Bool, Error>] = [:]

    public init(api: BlechWikiAPI, db: AppDatabase, now: @escaping @Sendable () -> Date = Date.init) {
        self.api = api
        self.db = db
        self.now = now
    }

    public nonisolated func fundstellen(_ query: FundstellenQuery) throws -> [Fundstelle] {
        try db.fundstellen(queryKey: query.cacheKey).map {
            Fundstelle(
                bookId: $0.bookId, bookTitle: $0.bookTitle, bookSubtitle: $0.bookSubtitle, number: $0.number,
                title: $0.title, addition: $0.addition, composer: $0.composer, scoring: $0.scoring,
                keySignature: $0.keySignature, coverUrl: $0.coverUrl
            )
        }
    }

    /// Zeitpunkt des letzten erfolgreichen Abrufs, `nil` wenn noch nie geladen.
    public nonisolated func fetchedAt(_ query: FundstellenQuery) throws -> Date? {
        try db.fetchState(queryKey: query.cacheKey).map { Date(timeIntervalSince1970: TimeInterval($0.fetchedAtMillis) / 1000) }
    }

    /// - Returns: `true`, wenn ein Request an den Server ging
    /// - Throws: `BlechWikiError` bei Netz- oder Serverfehlern; der Cache bleibt dann unverändert
    @discardableResult
    public func refresh(_ query: FundstellenQuery, force: Bool = false) async throws -> Bool {
        let key = query.cacheKey
        // Gleichzeitige Aufrufe für denselben Schlüssel warten aufeinander. Der zweite sieht
        // danach den frischen Cache und schickt keinen eigenen Request.
        while let running = inFlight[key] {
            _ = try? await running.value
            if inFlight[key] == running { inFlight[key] = nil }
        }
        let task = Task { try await load(query, key: key, force: force) }
        inFlight[key] = task
        defer { if inFlight[key] == task { inFlight[key] = nil } }
        return try await task.value
    }

    private func load(_ query: FundstellenQuery, key: String, force: Bool) async throws -> Bool {
        let titleVersion = try db.syncState()?.lastTitleNumber
        if !force, isFresh(try db.fetchState(queryKey: key), currentTitleVersion: titleVersion) { return false }

        let dtos = try await fetch(query)
        let entities = dtos.enumerated().map { index, dto in
            FundstelleEntity(
                queryKey: key, position: index, bookId: dto.bookId, bookTitle: dto.bookTitle,
                bookSubtitle: dto.bookSubtitle, number: dto.number, title: dto.title,
                titleNorm: SearchNormalizer.normalize(dto.title), addition: dto.addition,
                composer: dto.composer, scoring: dto.scoring, keySignature: dto.keySignature, coverUrl: dto.coverUrl
            )
        }
        let state = FetchState(queryKey: key, fetchedAtMillis: Int(now().timeIntervalSince1970 * 1000), titleVersion: titleVersion)
        try db.write { try AppDatabase.replaceFundstellen($0, queryKey: key, entities, state: state) }
        return true
    }

    private func isFresh(_ state: FetchState?, currentTitleVersion: Int?) -> Bool {
        guard let state else { return false }
        let ageMillis = Int(now().timeIntervalSince1970 * 1000) - state.fetchedAtMillis
        return ageMillis < Int(Self.maxAge * 1000) && state.titleVersion == currentTitleVersion
    }

    private func fetch(_ query: FundstellenQuery) async throws -> [FundstelleDto] {
        switch query {
        case .byTitle(let title): try await api.getFundstellenByTitle(title)
        case .byEgMelody(let ixUr): try await api.getFundstellenByEgSong(ixUr)
        case .byBook(let bookId): try await api.getFundstellenByBook(bookId)
        case .byComposer(let shortName): try await api.getFundstellenByComposer(shortName)
        }
    }
}
