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
    public let lists: ListsRepository
    public let sync: SyncCoordinator

    /// `listsDatabaseURL` liefert die Datei der Listen, `nil` legt sie im Speicher an (Tests).
    public init(
        api: BlechWikiAPI = JsonBlechWikiAPI(),
        databaseURL: URL?,
        listsDatabaseURL: () throws -> URL? = { nil },
        defaults: UserDefaults = .standard,
        snapshot: PieceSnapshot = BundlePieceSnapshot()
    ) throws {
        changes = DataChanges()
        db = try AppDatabase(url: databaseURL, changes: changes)
        preferences = UserPreferences(defaults: defaults, changes: changes)
        search = SearchRepository(db: db, preferences: preferences)
        myBooks = MyBooksRepository(db: db, preferences: preferences)
        settings = SettingsRepository(db: db, preferences: preferences)
        let masterDataSync = MasterDataSync(api: api, db: db, snapshot: snapshot)
        fundstellen = FundstellenRepository(api: api, db: db, sync: masterDataSync)
        hymnal = HymnalRepository(db: db, settings: settings)
        // Listen sind Nutzerdaten in eigener Datei. Lässt sie sich nicht öffnen, läuft die App ohne
        // Listen weiter. Gelöscht wird sie nie, auch nicht, wenn `db` neu aufgebaut wird.
        let changes = changes
        lists = ListsRepository(
            lists: Result { try ListsDatabase(url: listsDatabaseURL(), changes: changes) },
            db: db,
            preferences: preferences
        )
        sync = SyncCoordinator(
            sync: masterDataSync,
            fundstellen: fundstellen,
            preferences: preferences,
            db: db
        )
    }
}
