import CloudKit
import CoreLocation
import ImageIO
import Photos
import SwiftUI
import UIKit
import WidgetKit

/// 共有アルバムの 1 枚
struct AlbumPhoto: Identifiable, Equatable {
    let id: CKRecord.ID
    let takenAt: Date
    let mode: String
    var thumbnail: UIImage?
    /// 入れた人（CloudKit が自動で記録する作成者。自分が入れたものは "__defaultOwner__" のこともある）
    let creator: String?
    /// 撮った場所（記録されていれば）
    var location: CLLocationCoordinate2D? = nil
    /// 落書きで上書きした写真か（元の写真に戻せる）
    var edited = false

    static func == (a: AlbumPhoto, b: AlbumPhoto) -> Bool { a.id == b.id }
}

/// 写真へのいいね・絵文字・コメント（レコード型 AlbumReaction。写真と同じゾーンに置くので、アルバムのメンバー全員に見える）
struct AlbumReaction: Identifiable, Equatable {
    enum Kind: String { case like, emoji, comment }
    let id: CKRecord.ID
    /// どの写真への反応か（写真のレコード名）
    let photo: String
    let kind: Kind
    /// 絵文字、またはコメントの文
    let text: String
    let creator: String?
    let createdAt: Date

    static func == (a: AlbumReaction, b: AlbumReaction) -> Bool { a.id == b.id }
}

/// 見られるアルバム（自分のアルバム、または招待された友だちのアルバム）
struct AlbumRef: Identifiable, Hashable {
    let zoneID: CKRecordZone.ID
    let isOwner: Bool
    let title: String
    var id: String { zoneID.ownerName + "/" + zoneID.zoneName }
}

/// iCloud（CloudKit）を使った共有アルバム。
/// 自分のアルバムは非公開データベースのゾーン 1 つずつ（最初の 1 つは "SharedAlbum"、追加分は "Album-…"）に置き、
/// ゾーンごと CKShare で共有する。友だちのグループごとにアルバムを分けて、それぞれ別の人を招待できる。
/// 招待を受けた友だちのアルバムは共有データベースに現れる。写真は「AlbumPhoto」レコードとして保存する
/// （フル解像度の image、一覧用の thumbnail、撮影日時 takenAt、モード名 mode）。
/// 一覧は検索（インデックスが要る）ではなく、ゾーンの変更の取得で読む
@MainActor
final class AlbumStore: ObservableObject {
    static let shared = AlbumStore()

    nonisolated static let container = CKContainer.default()
    nonisolated static let recordType = "AlbumPhoto"
    nonisolated static let reactionType = "AlbumReaction"
    nonisolated static let ownZoneID = CKRecordZone.ID(zoneName: "SharedAlbum", ownerName: CKCurrentUserDefaultName)
    /// 追加で作ったアルバムのゾーン名の頭
    nonisolated static let albumZonePrefix = "Album-"
    nonisolated static let defaultShareTitle = "フィルムカメラの共有アルバム"

    /// 自分で作ったアルバムの名前（ゾーン名 → 名前）。招待した後は共有の題名からも読める
    private var albumTitles: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "albumTitles") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "albumTitles") }
    }

    @Published private(set) var albums: [AlbumRef] = []
    @Published var selectedID: String? {
        didSet {
            UserDefaults.standard.set(selectedID, forKey: "albumSelected")
            if oldValue != selectedID {
                share = nil
                Task { await loadPhotos() }
            }
        }
    }
    @Published private(set) var photos: [AlbumPhoto] = []
    /// アルバムごとの表紙（いちばん新しい写真）と枚数。切り替えのカードに出す
    @Published private(set) var covers: [String: UIImage] = [:]
    @Published private(set) var counts: [String: Int] = [:]
    /// 選んでいるアルバムのメンバー（ユーザーの recordName → 名前）。写真を入れた人の表示に使う
    @Published private(set) var members: [String: String] = [:]
    /// 写真ごとの反応（写真のレコード名 → いいね・絵文字・コメント、古い順）
    @Published private(set) var reactions: [String: [AlbumReaction]] = [:]
    /// 撮影画面で使いたいモード（写真の「このフィルタで撮る」）。カメラの画面が受け取って切り替える
    @Published var requestedMode: String?
    /// ウィジェットの「カメラ」から開かれた（そのままのモードでカメラを開く）
    @Published var openCamera = false
    /// 自分の recordName（自分が入れた写真を見分ける）
    private var myRecordName: String?
    /// 大きく見た写真をしばらく取っておく
    private var fullCache: [CKRecord.ID: UIImage] = [:]
    private var fullOrder: [CKRecord.ID] = []
    @Published private(set) var isLoading = false
    @Published private(set) var uploading = 0
    /// うまくいかなかったときの説明（iCloud に未サインインなど）
    @Published var status: String?
    /// 撮った写真を自動で共有アルバムにも入れるか
    @Published var autoAdd: Bool {
        didSet { UserDefaults.standard.set(autoAdd, forKey: "albumAutoAdd") }
    }
    /// 用意できた招待（自分のアルバムの共有）。これがあると「招待を送る」が出る
    @Published private(set) var share: CKShare?
    @Published private(set) var isPreparingShare = false
    /// このアルバムに参加している友だちの名前（作った人は除く）
    var participantNames: [String] {
        guard let share else { return [] }
        return share.participants
            .filter { $0.role != .owner && $0.acceptanceStatus == .accepted }
            .map { participant in
                participant.userIdentity.nameComponents
                    .map { PersonNameComponentsFormatter().string(from: $0) }
                    .flatMap { $0.isEmpty ? nil : $0 } ?? "名前なしの参加者"
            }
    }

    /// 招待を受け取ったときなどに、アルバムの画面を開く
    @Published var showAlbum = false

    var selected: AlbumRef? { albums.first { $0.id == selectedID } ?? albums.first }

    /// 一覧用の小さい画像を、読み込み直さずに使い回す（アルバム ID|レコード名 → 画像）
    private var thumbMemory: [String: UIImage] = [:]
    /// いま画面に出している写真がどのアルバムのものか
    private var shownAlbumID: String?

    private init() {
        AlbumCache.clearFullImagesOnce()
        autoAdd = UserDefaults.standard.bool(forKey: "albumAutoAdd")
        selectedID = UserDefaults.standard.string(forKey: "albumSelected")
        // 前回の控えから、アルバムの一覧と写真をすぐ出す（iCloud からは後で差分だけ取り込む）
        albums = AlbumCache.loadAlbums().map {
            AlbumRef(zoneID: CKRecordZone.ID(zoneName: $0.zoneName, ownerName: $0.ownerName),
                     isOwner: $0.isOwner, title: $0.title)
        }
        for album in albums {
            apply(AlbumCache(albumID: album.id).load(), to: album)
        }
    }

    private func database(for album: AlbumRef) -> CKDatabase {
        album.isOwner ? Self.container.privateCloudDatabase : Self.container.sharedCloudDatabase
    }

    // MARK: - 読み込み

    /// アルバムの一覧と、選んでいるアルバムの写真を読み直す
    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            guard try await Self.container.accountStatus() == .available else {
                status = "iCloud にサインインすると使えます（設定 → 自分の名前 → iCloud）"
                return
            }
            // 自分のアルバム（最初の 1 つは必ず用意する）
            try await Self.ensureZone(Self.ownZoneID)
            let privateDB = Self.container.privateCloudDatabase
            let titles = albumTitles
            var own: [AlbumRef] = []
            for zone in try await privateDB.allRecordZones() {
                let name = zone.zoneID.zoneName
                guard name == Self.ownZoneID.zoneName || name.hasPrefix(Self.albumZonePrefix) else { continue }
                let info = await Self.shareInfo(of: zone.zoneID, in: privateDB)
                let title = titles[name] ?? info.title
                    ?? (name == Self.ownZoneID.zoneName ? "自分のアルバム" : "アルバム")
                own.append(AlbumRef(zoneID: zone.zoneID, isOwner: true, title: title))
            }
            own.sort { a, b in
                if a.zoneID.zoneName == Self.ownZoneID.zoneName { return true }
                if b.zoneID.zoneName == Self.ownZoneID.zoneName { return false }
                return a.title < b.title
            }
            // 友だちのアルバム（招待を受けたもの）
            var list = own
            let shared = Self.container.sharedCloudDatabase
            for (index, zone) in try await shared.allRecordZones().enumerated() {
                let info = await Self.shareInfo(of: zone.zoneID, in: shared)
                let title = info.title ?? "友だちのアルバム \(index + 1)"
                list.append(AlbumRef(zoneID: zone.zoneID, isOwner: false,
                                     title: info.owner.map { "\(title)（\($0)）" } ?? title))
            }
            albums = list
            AlbumCache.saveAlbums(list.map {
                AlbumCache.Album(zoneName: $0.zoneID.zoneName, ownerName: $0.zoneID.ownerName,
                                 isOwner: $0.isOwner, title: $0.title)
            })
            status = nil
            await loadPhotos()
        } catch {
            // 読み込み中に画面を離れた・読み直しが重なったなどで取り消されたのはエラーではない
            guard !Self.isCancellation(error) else { return }
            status = Self.describe(error)
        }
    }

    /// 選んでいるアルバムの写真を読む。まず端末の控えをすぐ出し、
    /// iCloud からは前回読んだ位置より後の変更（追加・削除・反応）だけを受け取って控えに足す
    func loadPhotos() async {
        guard let album = selected else { return }
        let cache = AlbumCache(albumID: album.id)
        var state = cache.load()
        if state.token != nil || !state.photos.isEmpty {
            apply(state, to: album)
        } else if shownAlbumID != album.id {
            // 控えがまだない（初めて開く）アルバム：読み終わるまで「読み込み中」を出す
            photos = []
            reactions = [:]
        }
        isLoading = true
        defer { isLoading = false }
        let db = database(for: album)
        do {
            if album.isOwner { try await Self.ensureZone(album.zoneID) }
            if myRecordName == nil { myRecordName = try? await Self.container.userRecordID().recordName }
            // 招待があれば読んでおく（参加した人を表示し、すぐ招待を送れるように。写真を入れた人の名前にも使う）
            let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: album.zoneID)
            let existing = try? await db.record(for: shareID) as? CKShare
            if album.id == selected?.id {
                if album.isOwner { share = existing }
                members = Self.memberNames(of: existing)
            }
            do {
                try await fetchChanges(db, album: album, cache: cache, state: &state)
            } catch let error as CKError where error.code == .changeTokenExpired {
                // 読んだ位置が古すぎるときは、控えを捨てて最初から
                cache.clear()
                thumbMemory = thumbMemory.filter { !$0.key.hasPrefix(album.id + "|") }
                state = AlbumCache.State()
                try await fetchChanges(db, album: album, cache: cache, state: &state)
            }
            cache.save(state)
            apply(state, to: album)
        } catch {
            guard !Self.isCancellation(error) else { return }
            // つながらないときも、控えの写真はそのまま見られる
            status = Self.describe(error)
        }
    }

    /// 前回の位置から後の変更を受け取って、控え（state と画像のファイル）に反映する
    private func fetchChanges(_ db: CKDatabase, album: AlbumRef, cache: AlbumCache,
                              state: inout AlbumCache.State) async throws {
        var token = state.changeToken
        var more = true
        while more {
            let changes = try await db.recordZoneChanges(inZoneWith: album.zoneID, since: token,
                                                         desiredKeys: ["thumbnail", "takenAt", "mode", "location", "edited",
                                                                       "photo", "kind", "text", "createdAt"])
            for (_, result) in changes.modificationResultsByID {
                guard case .success(let modification) = result else { continue }
                let record = modification.record
                let name = record.recordID.recordName
                switch record.recordType {
                case Self.recordType:
                    // 前からある写真が書き換わった（落書き・元に戻す）：大きく見る用の控えは古いので捨てて、次に開いたとき読み直す
                    if state.photos[name] != nil {
                        try? FileManager.default.removeItem(at: cache.fullURL(name))
                        fullCache[record.recordID] = nil
                    }
                    state.photos[name] = AlbumCache.Photo(
                        name: name,
                        takenAt: record["takenAt"] as? Date ?? record.creationDate ?? .distantPast,
                        mode: record["mode"] as? String ?? "",
                        creator: record.creatorUserRecordID?.recordName,
                        latitude: (record["location"] as? CLLocation)?.coordinate.latitude,
                        longitude: (record["location"] as? CLLocation)?.coordinate.longitude,
                        edited: (record["edited"] as? Int64 ?? 0) != 0)
                    if let url = (record["thumbnail"] as? CKAsset)?.fileURL,
                       let image = Self.downsample(url, maxPixel: 600) {
                        cache.store(image, at: cache.thumbnailURL(name), quality: 0.8)
                        thumbMemory[album.id + "|" + name] = image
                    }
                case Self.reactionType:
                    guard let photo = record["photo"] as? String, let kind = record["kind"] as? String else { continue }
                    state.reactions[name] = AlbumCache.Reaction(
                        name: name, photo: photo, kind: kind,
                        text: record["text"] as? String ?? "",
                        creator: record.creatorUserRecordID?.recordName,
                        createdAt: record["createdAt"] as? Date ?? record.creationDate ?? .distantPast)
                default:
                    break
                }
            }
            for deletion in changes.deletions {
                let name = deletion.recordID.recordName
                state.photos[name] = nil
                state.reactions[name] = nil
                cache.removeImages(name)
                thumbMemory[album.id + "|" + name] = nil
            }
            token = changes.changeToken
            more = changes.moreComing
        }
        state.changeToken = token
    }

    /// 控えの中身を画面に出す。選んでいないアルバムは、枚数と表紙だけ
    private func apply(_ state: AlbumCache.State, to album: AlbumRef) {
        let cache = AlbumCache(albumID: album.id)
        counts[album.id] = state.photos.count
        guard album.id == selected?.id else {
            if let newest = state.photos.values.max(by: { $0.takenAt < $1.takenAt }) {
                covers[album.id] = thumbnail(newest.name, album: album, cache: cache)
            } else {
                covers[album.id] = nil
            }
            return
        }
        let list = state.photos.values.map { photo in
            AlbumPhoto(id: CKRecord.ID(recordName: photo.name, zoneID: album.zoneID),
                       takenAt: photo.takenAt, mode: photo.mode,
                       thumbnail: thumbnail(photo.name, album: album, cache: cache),
                       creator: photo.creator,
                       location: photo.latitude.flatMap { latitude in
                           photo.longitude.map { CLLocationCoordinate2D(latitude: latitude, longitude: $0) }
                       },
                       edited: photo.edited ?? false)
        }
        .sorted { $0.takenAt > $1.takenAt }
        covers[album.id] = list.first?.thumbnail
        photos = list
        shownAlbumID = album.id
        updateWidget(list, album: album)
        let loaded = state.reactions.values.compactMap { item -> AlbumReaction? in
            guard let kind = AlbumReaction.Kind(rawValue: item.kind) else { return nil }
            return AlbumReaction(id: CKRecord.ID(recordName: item.name, zoneID: album.zoneID), photo: item.photo,
                                 kind: kind, text: item.text, creator: item.creator, createdAt: item.createdAt)
        }
        reactions = Dictionary(grouping: loaded, by: \.photo).mapValues { $0.sorted { $0.createdAt < $1.createdAt } }
    }

    /// ホーム画面のウィジェットに、選んでいるアルバムの新しい写真を渡す（変わったときだけ書き直す）
    private func updateWidget(_ list: [AlbumPhoto], album: AlbumRef) {
        let newest = Array(list.prefix(AlbumWidgetData.maxEntries))
        let files = newest.map { $0.id.recordName + ".jpg" }
        let current = AlbumWidgetData.load()
        let dates = Array(list.prefix(AlbumWidgetData.maxDates).map(\.takenAt))
        guard current.entries.map(\.file) != files || current.entries.first?.albumTitle != album.title
                || current.totalCount != list.count || current.recentDates != dates,
              let folder = AlbumWidgetData.folder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // 前の画像は消して、新しい分だけ置く
        for old in current.entries where !files.contains(old.file) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(old.file))
        }
        var data = AlbumWidgetData()
        data.totalCount = list.count
        data.recentDates = dates
        for (photo, file) in zip(newest, files) {
            if let image = photo.thumbnail.map(Self.widgetSized), let jpeg = image.jpegData(compressionQuality: 0.8) {
                try? jpeg.write(to: folder.appendingPathComponent(file), options: .atomic)
            }
            data.entries.append(.init(file: file, albumTitle: album.title, who: creatorName(of: photo),
                                      takenAt: photo.takenAt))
        }
        data.save()
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func thumbnail(_ name: String, album: AlbumRef, cache: AlbumCache) -> UIImage? {
        let key = album.id + "|" + name
        if let image = thumbMemory[key] { return image }
        let image = cache.thumbnail(name)
        if let image { thumbMemory[key] = image }
        return image
    }

    /// 1 枚をフル解像度で読む（表示用に長い辺 2400px まで縮める）
    func fullImage(of photo: AlbumPhoto) async -> UIImage? {
        if let cached = fullCache[photo.id] { return cached }
        // 一度見た写真は端末の控えから（iCloud から受け取り直さない）
        let cache = selected.map { AlbumCache(albumID: $0.id) }
        let image: UIImage
        if let stored = cache?.fullImage(photo.id.recordName) {
            image = stored
        } else {
            guard let url = await fullFile(of: photo), let downloaded = Self.downsample(url, maxPixel: 2400) else { return nil }
            if let cache { cache.store(downloaded, at: cache.fullURL(photo.id.recordName), quality: 0.9) }
            image = downloaded
        }
        fullCache[photo.id] = image
        fullOrder.append(photo.id)
        if fullOrder.count > 12 { fullCache[fullOrder.removeFirst()] = nil }
        return image
    }

    /// 1 枚の元のファイル（CloudKit が一時的に置いた場所）
    private func fullFile(of photo: AlbumPhoto) async -> URL? {
        guard let album = selected else { return nil }
        guard let results = try? await database(for: album).records(for: [photo.id], desiredKeys: ["image"]),
              case .success(let record)? = results[photo.id],
              let asset = record["image"] as? CKAsset else { return nil }
        return asset.fileURL
    }

    // MARK: - 入れた人

    /// 写真を入れた人の名前（自分なら「自分」）
    func creatorName(of photo: AlbumPhoto) -> String {
        guard let creator = photo.creator else { return "だれか" }
        if isMine(photo) { return "自分" }
        return members[creator] ?? "メンバー"
    }

    func isMine(_ photo: AlbumPhoto) -> Bool { isMine(photo.creator) }

    func isMine(_ creator: String?) -> Bool {
        guard let creator else { return false }
        return creator == CKCurrentUserDefaultName || creator == myRecordName
    }

    /// 反応した人の名前（自分なら「自分」）
    func name(of creator: String?) -> String {
        guard let creator else { return "だれか" }
        if isMine(creator) { return "自分" }
        return members[creator] ?? "メンバー"
    }

    /// 消せる写真か（自分が入れたもの。自分のアルバムなら全部）
    func canDelete(_ photo: AlbumPhoto) -> Bool {
        selected?.isOwner == true || isMine(photo)
    }

    nonisolated static func memberNames(of share: CKShare?) -> [String: String] {
        AlbumActivity.memberNames(of: share)
    }

    // MARK: - いいね・絵文字・コメント

    func likes(of photo: AlbumPhoto) -> [AlbumReaction] {
        (reactions[photo.id.recordName] ?? []).filter { $0.kind == .like }
    }

    func comments(of photo: AlbumPhoto) -> [AlbumReaction] {
        (reactions[photo.id.recordName] ?? []).filter { $0.kind == .comment }
    }

    /// 絵文字ごとの反応（よく使われた順）
    func emojis(of photo: AlbumPhoto) -> [(emoji: String, people: [AlbumReaction])] {
        let list = (reactions[photo.id.recordName] ?? []).filter { $0.kind == .emoji }
        return Dictionary(grouping: list, by: \.text)
            .map { (emoji: $0.key, people: $0.value) }
            .sorted { $0.people.count > $1.people.count || ($0.people.count == $1.people.count && $0.emoji < $1.emoji) }
    }

    func hasLiked(_ photo: AlbumPhoto) -> Bool { likes(of: photo).contains { isMine($0.creator) } }

    func hasReacted(_ photo: AlbumPhoto, with emoji: String) -> Bool {
        emojis(of: photo).first { $0.emoji == emoji }?.people.contains { isMine($0.creator) } ?? false
    }

    /// いいねを付ける・外す
    func toggleLike(_ photo: AlbumPhoto) async {
        if let mine = likes(of: photo).first(where: { isMine($0.creator) }) {
            await removeReaction(mine)
        } else {
            await addReaction(to: photo, kind: .like, text: "", key: "like")
        }
    }

    /// 絵文字の反応を付ける・外す
    func toggleEmoji(_ emoji: String, on photo: AlbumPhoto) async {
        let mine = (reactions[photo.id.recordName] ?? [])
            .first { $0.kind == .emoji && $0.text == emoji && isMine($0.creator) }
        if let mine {
            await removeReaction(mine)
        } else {
            let code = emoji.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: "-")
            await addReaction(to: photo, kind: .emoji, text: emoji, key: "emoji-" + code)
        }
    }

    func comment(on photo: AlbumPhoto, text: String) async {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        await addReaction(to: photo, kind: .comment, text: String(body.prefix(500)), key: nil)
    }

    /// 反応を保存する。いいねと絵文字は「写真＋人＋種類」で 1 つだけになるよう、決まった名前のレコードにする
    private func addReaction(to photo: AlbumPhoto, kind: AlbumReaction.Kind, text: String, key: String?) async {
        guard let album = selected else { return }
        let me = myRecordName ?? CKCurrentUserDefaultName
        let name = key.map { "\($0)-\(photo.id.recordName)-\(me)" } ?? UUID().uuidString
        let recordID = CKRecord.ID(recordName: name, zoneID: album.zoneID)
        let record = CKRecord(recordType: Self.reactionType, recordID: recordID)
        record["photo"] = photo.id.recordName as NSString
        record["kind"] = kind.rawValue as NSString
        record["text"] = text as NSString
        record["createdAt"] = Date() as NSDate
        // 先に画面に出しておく（失敗したら戻す）
        let pending = AlbumReaction(id: recordID, photo: photo.id.recordName, kind: kind, text: text,
                                    creator: CKCurrentUserDefaultName, createdAt: Date())
        reactions[photo.id.recordName, default: []].append(pending)
        do {
            _ = try await database(for: album).modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
            status = nil
        } catch {
            reactions[photo.id.recordName]?.removeAll { $0.id == recordID }
            status = (kind == .comment ? "コメントできませんでした：" : "反応できませんでした：") + Self.describe(error)
        }
    }

    func removeReaction(_ reaction: AlbumReaction) async {
        guard let album = selected else { return }
        let backup = reactions[reaction.photo]
        reactions[reaction.photo]?.removeAll { $0.id == reaction.id }
        do {
            _ = try await database(for: album).deleteRecord(withID: reaction.id)
        } catch let error as CKError where error.code == .unknownItem {
            // もう消えている
        } catch {
            reactions[reaction.photo] = backup
            status = "取り消せませんでした：" + Self.describe(error)
        }
    }

    /// 消せる反応か（自分のもの。自分のアルバムなら全部）
    func canDelete(_ reaction: AlbumReaction) -> Bool {
        selected?.isOwner == true || isMine(reaction.creator)
    }

    nonisolated private static func reaction(from record: CKRecord) -> AlbumReaction? {
        guard let photo = record["photo"] as? String,
              let kind = (record["kind"] as? String).flatMap(AlbumReaction.Kind.init(rawValue:)) else { return nil }
        return AlbumReaction(id: record.recordID, photo: photo, kind: kind,
                             text: record["text"] as? String ?? "",
                             creator: record.creatorUserRecordID?.recordName,
                             createdAt: record["createdAt"] as? Date ?? record.creationDate ?? .distantPast)
    }

    // MARK: - 落書き（上書きと、元に戻す）

    func isEdited(_ id: CKRecord.ID) -> Bool {
        photos.first { $0.id == id }?.edited ?? false
    }

    /// 落書きした画像で写真を上書きする。元の写真は original に取っておく（2 回目以降の落書きでは、最初の元の写真を残す）
    func applyDoodle(to photo: AlbumPhoto, image: UIImage) async -> Bool {
        guard let album = selected, let jpeg = image.jpegData(compressionQuality: 0.9) else { return false }
        let db = database(for: album)
        let folder = FileManager.default.temporaryDirectory
        let imageURL = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
        let thumbURL = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
        let originalURL = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
        defer {
            for url in [imageURL, thumbURL, originalURL] { try? FileManager.default.removeItem(at: url) }
        }
        do {
            let record = try await Self.retrying { try await db.record(for: photo.id) }
            try jpeg.write(to: imageURL)
            if let small = Self.thumbnailJPEG(image) { try small.write(to: thumbURL) }
            if (record["edited"] as? Int64 ?? 0) == 0 {
                // 元の写真は、iCloud が置いた場所のファイルをそのまま使わず、自分の一時ファイルに写してから送る
                guard let source = (record["image"] as? CKAsset)?.fileURL else {
                    status = "元の写真を読み込めませんでした"
                    return false
                }
                try FileManager.default.copyItem(at: source, to: originalURL)
                record["original"] = CKAsset(fileURL: originalURL)
            }
            record["image"] = CKAsset(fileURL: imageURL)
            record["thumbnail"] = CKAsset(fileURL: thumbURL)
            record["edited"] = 1 as Int64
            _ = try await Self.retrying {
                try await db.modifyRecords(saving: [record], deleting: [], savePolicy: .changedKeys)
            }
            updateLocally(photo, full: image, edited: true)
            status = nil
            return true
        } catch {
            status = "落書きを保存できませんでした：" + Self.describe(error)
            return false
        }
    }

    /// 落書きを消して、元の写真に戻す
    func revertDoodle(_ photo: AlbumPhoto) async -> Bool {
        guard let album = selected else { return false }
        let db = database(for: album)
        let folder = FileManager.default.temporaryDirectory
        let thumbURL = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
        let url = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
        defer {
            try? FileManager.default.removeItem(at: thumbURL)
            try? FileManager.default.removeItem(at: url)
        }
        do {
            let record = try await Self.retrying { try await db.record(for: photo.id) }
            guard let source = (record["original"] as? CKAsset)?.fileURL else {
                status = "元の写真が見つかりませんでした"
                return false
            }
            try FileManager.default.copyItem(at: source, to: url)
            guard let full = Self.downsample(url, maxPixel: 2400) else {
                status = "元の写真を読み込めませんでした"
                return false
            }
            if let small = Self.downsample(url, maxPixel: 800).flatMap(Self.thumbnailJPEG(_:)) {
                try small.write(to: thumbURL)
                record["thumbnail"] = CKAsset(fileURL: thumbURL)
            }
            record["image"] = CKAsset(fileURL: url)
            record["original"] = nil
            record["edited"] = nil
            _ = try await Self.retrying {
                try await db.modifyRecords(saving: [record], deleting: [], savePolicy: .changedKeys)
            }
            updateLocally(photo, full: full, edited: false)
            status = nil
            return true
        } catch {
            status = "元に戻せませんでした：" + Self.describe(error)
            return false
        }
    }

    /// iCloud が一時的に使えないとき（混雑・つながらない）は、少し待って 2 回までやり直す
    private static func retrying<T>(_ work: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await work()
            } catch let error as CKError where attempt < 2 &&
                [.serviceUnavailable, .requestRateLimited, .zoneBusy, .networkFailure].contains(error.code) {
                attempt += 1
                let wait = error.retryAfterSeconds ?? Double(attempt) * 1.5
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    /// 上書き・元に戻したあと、画面と端末の控えをすぐ新しくする（次の差分の取り込みでも同じ内容が届く）
    private func updateLocally(_ photo: AlbumPhoto, full: UIImage, edited: Bool) {
        guard let album = selected else { return }
        let cache = AlbumCache(albumID: album.id)
        let name = photo.id.recordName
        let small = Self.thumbnailJPEG(full).flatMap(UIImage.init(data:))
        if let small {
            cache.store(small, at: cache.thumbnailURL(name), quality: 0.8)
            thumbMemory[album.id + "|" + name] = small
        }
        cache.store(full, at: cache.fullURL(name), quality: 0.9)
        fullCache[photo.id] = full
        var state = cache.load()
        if let entry = state.photos[name] {
            state.photos[name] = AlbumCache.Photo(name: entry.name, takenAt: entry.takenAt, mode: entry.mode,
                                                  creator: entry.creator, latitude: entry.latitude,
                                                  longitude: entry.longitude, edited: edited)
            cache.save(state)
        }
        if let index = photos.firstIndex(where: { $0.id == photo.id }) {
            photos[index].thumbnail = small ?? photos[index].thumbnail
            photos[index].edited = edited
        }
        if photos.first?.id == photo.id { covers[album.id] = small }
    }

    // MARK: - ほかのアルバムへ

    /// 写真を元の画質のまま、ほかのアルバムにも入れる
    func copy(_ photo: AlbumPhoto, to target: AlbumRef) async -> Bool {
        guard let url = await fullFile(of: photo), let data = try? Data(contentsOf: url) else { return false }
        let type = CGImageSourceCreateWithData(data as CFData, nil)
            .flatMap { CGImageSourceGetType($0) as String? } ?? "public.jpeg"
        add(data: data, type: type, thumbnail: photo.thumbnail, mode: photo.mode,
            location: photo.location.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }, to: target)
        return true
    }

    // MARK: - 消す・保存する

    /// 写真を消す（消せないものは飛ばす）
    func delete(_ targets: [AlbumPhoto]) async {
        guard let album = selected else { return }
        let ids = targets.filter { canDelete($0) }.map(\.id)
        guard !ids.isEmpty else { return }
        // 写真についた反応も消す（自分のアルバムなら全部、そうでなければ自分の分）
        let reactionIDs = ids.flatMap { id in
            (reactions[id.recordName] ?? []).filter { album.isOwner || isMine($0.creator) }.map(\.id)
        }
        do {
            let result = try await database(for: album).modifyRecords(saving: [], deleting: ids + reactionIDs)
            var deleted: Set<CKRecord.ID> = []
            for (id, outcome) in result.deleteResults {
                if case .success = outcome { deleted.insert(id) }
            }
            photos.removeAll { deleted.contains($0.id) }
            for id in ids where deleted.contains(id) { reactions[id.recordName] = nil }
            counts[album.id] = photos.count
            covers[album.id] = photos.first?.thumbnail
            status = deleted.isSuperset(of: ids) ? nil : "消せなかった写真があります"
        } catch {
            status = "消せませんでした：" + Self.describe(error)
        }
    }

    /// 写真を元の画質で写真アプリに保存する。保存できた枚数を返す
    func saveToLibrary(_ targets: [AlbumPhoto]) async -> Int {
        let allowed = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard allowed == .authorized || allowed == .limited else {
            status = "写真への保存が許可されていません（設定 → フィルムカメラ → 写真）"
            return 0
        }
        var saved = 0
        for photo in targets {
            guard let url = await fullFile(of: photo), let data = try? Data(contentsOf: url) else { continue }
            let ok = (try? await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            }) != nil
            if ok { saved += 1 }
        }
        return saved
    }

    /// 写真アプリから選んだ写真をアルバムに入れる
    func importPhotos(_ files: [Data]) {
        for data in files {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { continue }
            let type = CGImageSourceGetType(source) as String? ?? "public.jpeg"
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 800,
            ]
            let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map(UIImage.init(cgImage:))
            add(data: data, type: type, thumbnail: thumbnail, mode: "写真から",
                location: LocationProvider.location(inImage: data))
        }
    }

    // MARK: - 追加

    /// 撮った写真を自動で入れる設定なら、選んでいるアルバムに入れる
    func addIfAutomatic(data: Data, type: String, thumbnail: UIImage?, mode: String) {
        guard autoAdd else { return }
        add(data: data, type: type, thumbnail: thumbnail, mode: mode, location: LocationProvider.shared.recent)
    }

    /// 写真をアルバムに入れる（target を省くと、選んでいるアルバム）
    func add(data: Data, type: String, thumbnail: UIImage?, mode: String, location: CLLocation? = nil,
             to target: AlbumRef? = nil) {
        Task { await upload(data: data, type: type, thumbnail: thumbnail, mode: mode, location: location, to: target) }
    }

    /// 写真をアルバムに入れて、うまくいったかを返す（失敗したら呼んだ側で取っておいて、あとでやり直せる）
    @discardableResult
    func upload(data: Data, type: String, thumbnail: UIImage?, mode: String, location: CLLocation? = nil,
                to target: AlbumRef? = nil) async -> Bool {
        do {
            if albums.isEmpty { await refresh() }
            guard let album = target ?? selected else {
                status = status ?? "共有アルバムを準備できませんでした"
                return false
            }
            uploading += 1
            defer { uploading -= 1 }
            do {
                if album.isOwner { try await Self.ensureZone(album.zoneID) }
                let folder = FileManager.default.temporaryDirectory
                let ext = type == "public.heic" ? "heic" : "jpg"
                let imageURL = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
                try data.write(to: imageURL)
                defer { try? FileManager.default.removeItem(at: imageURL) }

                let record = CKRecord(recordType: Self.recordType,
                                      recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: album.zoneID))
                record["image"] = CKAsset(fileURL: imageURL)
                record["takenAt"] = Date() as NSDate
                record["mode"] = mode as NSString
                var thumbURL: URL?
                if let jpeg = thumbnail.flatMap(Self.thumbnailJPEG(_:)) {
                    let url = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
                    try jpeg.write(to: url)
                    record["thumbnail"] = CKAsset(fileURL: url)
                    thumbURL = url
                }
                defer { if let thumbURL { try? FileManager.default.removeItem(at: thumbURL) } }

                // 撮った場所。iCloud のスキーマに location がまだない（Deploy 前）ときは、場所なしで保存し直す
                record["location"] = location
                let saved: CKRecord
                if location != nil, let withPlace = try? await database(for: album).save(record) {
                    saved = withPlace
                } else {
                    record["location"] = nil
                    saved = try await database(for: album).save(record)
                }
                if album.id == selected?.id {
                    photos.insert(AlbumPhoto(id: saved.recordID, takenAt: Date(), mode: mode, thumbnail: thumbnail,
                                             creator: CKCurrentUserDefaultName,
                                             location: (saved["location"] as? CLLocation)?.coordinate), at: 0)
                }
                counts[album.id, default: 0] += 1
                if let thumbnail { covers[album.id] = thumbnail }
                status = nil
                return true
            } catch {
                status = "共有アルバムに追加できませんでした：" + Self.describe(error)
                return false
            }
        }
    }

    // MARK: - 共有

    /// 自分のアルバムの共有（招待のリンク）を用意する。なければ作る。
    /// LINE などにリンクだけ送れるよう「リンクを知っている人は誰でも参加して追加できる」にする
    /// （宛先を指定する方式だと、メールアドレスや電話番号を求められる）。題名はアルバムの名前にする
    nonisolated static func prepareShare(zoneID: CKRecordZone.ID, title: String) async throws -> CKShare {
        try await ensureZone(zoneID)
        let db = container.privateCloudDatabase
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        if let existing = try? await db.record(for: shareID) as? CKShare {
            let currentTitle = existing[CKShare.SystemFieldKey.title] as? String
            guard existing.publicPermission != .readWrite || currentTitle != title else { return existing }
            existing.publicPermission = .readWrite
            existing[CKShare.SystemFieldKey.title] = title as NSString
            return try await db.save(existing) as? CKShare ?? existing
        }
        let share = CKShare(recordZoneID: zoneID)
        share[CKShare.SystemFieldKey.title] = title as NSString
        share.publicPermission = .readWrite
        return try await db.save(share) as? CKShare ?? share
    }

    /// 選んでいるアルバムの招待を用意する（うまくいかなければ理由を status に出す）
    func makeShare() async {
        guard let album = selected, album.isOwner else { return }
        isPreparingShare = true
        defer { isPreparingShare = false }
        do {
            let title = album.zoneID.zoneName == Self.ownZoneID.zoneName && album.title == "自分のアルバム"
                ? Self.defaultShareTitle : album.title
            share = try await Self.prepareShare(zoneID: album.zoneID, title: title)
            status = nil
        } catch {
            status = "招待を作れませんでした：" + Self.describe(error)
        }
    }

    // MARK: - アルバムを作る・消す

    /// 自分のアルバムの名前を変える（招待を作ってあれば、その題名も変える）
    func renameSelectedAlbum(to name: String) async {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let album = selected, album.isOwner, !title.isEmpty else { return }
        var titles = albumTitles
        titles[album.zoneID.zoneName] = title
        albumTitles = titles
        if share != nil {
            share = try? await Self.prepareShare(zoneID: album.zoneID, title: title)
        }
        await refresh()
    }

    /// 友だちのグループ用に、新しいアルバムを作って選ぶ
    func createAlbum(named name: String) async {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let zoneID = CKRecordZone.ID(zoneName: Self.albumZonePrefix + UUID().uuidString,
                                     ownerName: CKCurrentUserDefaultName)
        do {
            try await Self.ensureZone(zoneID)
            var titles = albumTitles
            titles[zoneID.zoneName] = title
            albumTitles = titles
            await refresh()
            if let album = albums.first(where: { $0.zoneID == zoneID }) { selectedID = album.id }
        } catch {
            status = "アルバムを作れませんでした：" + Self.describe(error)
        }
    }

    /// 選んでいるアルバムを消す（自分のアルバムなら写真ごと消え、招待した人も見られなくなる。
    /// 友だちのアルバムなら、そのアルバムから抜ける）。最初の「自分のアルバム」は消さない
    func removeSelectedAlbum() async {
        guard let album = selected, album.zoneID.zoneName != Self.ownZoneID.zoneName || !album.isOwner else { return }
        do {
            _ = try await database(for: album).deleteRecordZone(withID: album.zoneID)
            AlbumCache(albumID: album.id).clear()
            if album.isOwner {
                var titles = albumTitles
                titles[album.zoneID.zoneName] = nil
                albumTitles = titles
            }
            selectedID = nil
            await refresh()
        } catch {
            status = (album.isOwner ? "アルバムを消せませんでした：" : "アルバムから抜けられませんでした：")
                + Self.describe(error)
        }
    }

    /// ウィジェットをタップして開かれたとき（filmcamera://camera?mode=film、filmcamera://album）
    func open(_ url: URL) {
        guard url.scheme == "filmcamera" else { return }
        switch url.host {
        case "camera":
            let mode = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "mode" })?.value
            if let mode, let look = LookMode(rawValue: mode) {
                requestedMode = look.title
            } else {
                openCamera = true
            }
        default:
            showAlbum = true
        }
    }

    /// 友だちからの招待を受ける（招待のリンクを開いたとき）
    func accept(_ metadata: CKShare.Metadata) {
        showAlbum = true
        Task {
            do {
                let container = CKContainer(identifier: metadata.containerIdentifier)
                _ = try await container.accept(metadata)
                let zoneID = metadata.share.recordID.zoneID
                await refresh()
                if let album = albums.first(where: { $0.zoneID == zoneID }) {
                    selectedID = album.id
                }
            } catch {
                status = "招待を受けられませんでした：" + Self.describe(error)
            }
        }
    }

    // MARK: - 下ごしらえ

    nonisolated private static func ensureZone(_ zoneID: CKRecordZone.ID) async throws {
        let db = container.privateCloudDatabase
        if (try? await db.recordZone(for: zoneID)) != nil { return }
        _ = try await db.save(CKRecordZone(zoneID: zoneID))
    }

    /// アルバムの共有の題名と、作った人の名前（共有していなければどちらも nil）
    nonisolated private static func shareInfo(of zoneID: CKRecordZone.ID,
                                              in db: CKDatabase) async -> (title: String?, owner: String?) {
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        guard let share = try? await db.record(for: shareID) as? CKShare else { return (nil, nil) }
        var title = share[CKShare.SystemFieldKey.title] as? String
        if title == defaultShareTitle || title?.isEmpty == true { title = nil }
        let owner = share.owner.userIdentity.nameComponents
            .map { PersonNameComponentsFormatter().string(from: $0) }
            .flatMap { $0.isEmpty ? nil : $0 }
        return (title, owner)
    }

    nonisolated private static func photo(from record: CKRecord) -> AlbumPhoto {
        let thumbnail = (record["thumbnail"] as? CKAsset)?.fileURL.flatMap { downsample($0, maxPixel: 600) }
        return AlbumPhoto(id: record.recordID,
                          takenAt: record["takenAt"] as? Date ?? record.creationDate ?? .distantPast,
                          mode: record["mode"] as? String ?? "",
                          thumbnail: thumbnail,
                          creator: record.creatorUserRecordID?.recordName)
    }

    nonisolated private static func thumbnailJPEG(_ image: UIImage) -> Data? {
        let long = max(image.size.width, image.size.height)
        let scale = min(1, 800 / max(long, 1))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let small = UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return small.jpegData(compressionQuality: 0.8)
    }

    /// ウィジェットに渡す画像は長い辺 600px まで（撮ったばかりの写真は元の大きさのことがある）
    nonisolated private static func widgetSized(_ image: UIImage) -> UIImage {
        let longest = max(image.size.width, image.size.height) * image.scale
        guard longest > 600 else { return image }
        let ratio = 600 / longest * image.scale
        let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    nonisolated static func downsample(_ url: URL, maxPixel: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    /// 処理が取り消されただけか（LINE などから戻ったとき、前の読み込みが取り消されて「コード 20」と出ていた）
    nonisolated private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        guard let ck = error as? CKError else { return false }
        if ck.code == .operationCancelled { return true }
        if ck.code == .partialFailure, let inner = ck.partialErrorsByItemID?.values.first { return isCancellation(inner) }
        return false
    }

    nonisolated private static func describe(_ error: Error) -> String {
        guard let ck = error as? CKError else { return error.localizedDescription }
        // まとめて送ったうちの一部が失敗したときは、中身のエラーで説明する
        if ck.code == .partialFailure, let inner = ck.partialErrorsByItemID?.values.first {
            return describe(inner)
        }
        switch ck.code {
        case .notAuthenticated: return "iCloud にサインインしてください"
        case .networkUnavailable, .networkFailure: return "ネットにつながっていません"
        case .quotaExceeded: return "iCloud の空き容量が足りません"
        case .permissionFailure: return "このアルバムに追加する権限がありません"
        case .badContainer, .missingEntitlement: return "iCloud の設定が済んでいません（Apple Developer で iCloud コンテナの設定が必要）"
        case .serverRejectedRequest, .invalidArguments:
            return "iCloud の準備が済んでいません（CloudKit Console でスキーマの読み込みと公開が必要・コード \(ck.code.rawValue)）"
        default: return "\(ck.localizedDescription)（コード \(ck.code.rawValue)）"
        }
    }
}
