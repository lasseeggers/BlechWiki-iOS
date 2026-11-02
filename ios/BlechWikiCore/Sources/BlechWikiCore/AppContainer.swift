import Foundation

/// Verdrahtet alle Teile, wie Hilt in der Android-App.
@MainActor
public final class AppContainer {

    public let changes: DataChanges
    public let db: AppDatabase
    public let preferences: UserPreferences
    public let search: SearchRepository
    public let myBooks: MyBooksRepository
    public let settings: SettingsRepository
    public let fundstellen: FundstellenRepository
    public let hymnal: HymnalRepository
    public let sync: SyncCoordinator

    public init(
        api: BlechWikiAPI = JsonBlechWikiAPI(),
        databaseURL: URL?,
        defaults: UserDefaults = .standard
    ) throws {
        changes = DataChanges()
        db = try AppDatabase(url: databaseURL, changes: changes)
        preferences = UserPreferences(defaults: defaults, changes: changes)
        search = SearchRepository(db: db, preferences: preferences)
        myBooks = MyBooksRepository(db: db, preferences: preferences)
        settings = SettingsRepository(db: db, preferences: preferences)
        fundstellen = FundstellenRepository(api: api, db: db)
        hymnal = HymnalRepository(db: db, settings: settings)
        sync = SyncCoordinator(
            sync: MasterDataSync(api: api, db: db),
            fundstellen: fundstellen,
            preferences: preferences,
            db: db
        )
    }
}
