import Combine
import Foundation

@MainActor
final class SearchPageModel: ObservableObject {
    @Published var category: CatalogCategory = .songs
    @Published private(set) var items: [CatalogItem] = []
    @Published private(set) var artistTracks: [SongData] = []
    @Published private(set) var selectedArtist: CatalogItem?
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var hasMore = false
    @Published private(set) var history: [String]
    @Published var linkMode = false
    @Published var linkText = ""
    @Published private(set) var linkedSongs: [SongData] = []
    private let defaults: UserDefaults
    private let historyKey = "online.searchHistory"
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var page = 1

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        history = Array((defaults.stringArray(forKey: historyKey) ?? []).prefix(30))
    }
    deinit { task?.cancel() }

    func remember(_ query: String) {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, RecognizedMusicLink.parse(value) == nil, !value.contains("://") else { return }
        history.removeAll { $0.localizedCaseInsensitiveCompare(value) == .orderedSame }
        history.insert(value, at: 0)
        history = Array(history.prefix(30))
        defaults.set(history, forKey: historyKey)
    }
    func clearHistory() { history = []; defaults.removeObject(forKey: historyKey) }
    func removeHistory(_ value: String) { history.removeAll { $0 == value }; defaults.set(history, forKey: historyKey) }

    func search(using online: OnlineViewModel, append: Bool = false, debounce: Bool = false) {
        task?.cancel(); generation = UUID(); error = nil; selectedArtist = nil; artistTracks = []
        let query = online.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard category != .songs, !query.isEmpty else { items = []; isLoading = false; hasMore = false; return }
        let token = generation, category = self.category, source = online.source
        let nextPage = append ? page + 1 : 1
        if !append { items = []; page = 1 }
        isLoading = true
        task = Task { [weak self] in
            do {
                if debounce { try await Task.sleep(nanoseconds: 300_000_000) }
                try Task.checkCancellation()
                let values = try await online.searchCatalog(query: query, category: category, page: nextPage)
                guard let self, generation == token, online.source == source, !Task.isCancelled else { return }
                if append {
                    let ids = Set(items.map(\.id)); items += values.filter { !ids.contains($0.id) }
                } else { items = values }
                page = nextPage; hasMore = !values.isEmpty; isLoading = false
            } catch {
                guard let self, generation == token, !Task.isCancelled else { return }
                self.error = error.localizedDescription; isLoading = false
            }
        }
    }

    func openArtist(_ item: CatalogItem, using online: OnlineViewModel) {
        task?.cancel(); generation = UUID()
        let token = generation
        selectedArtist = item; artistTracks = []; isLoading = true; error = nil
        task = Task { [weak self] in
            do {
                let songs = try await online.artistSongs(item)
                guard let self, generation == token, !Task.isCancelled else { return }
                artistTracks = songs; isLoading = false
            } catch {
                guard let self, generation == token, !Task.isCancelled else { return }
                self.error = error.localizedDescription; isLoading = false
            }
        }
    }
    func closeArtist() { task?.cancel(); generation = UUID(); selectedArtist = nil; artistTracks = []; isLoading = false }

    func recognize(using online: OnlineViewModel, openCollection: @escaping (OnlineCollection) -> Void) {
        task?.cancel(); generation = UUID(); linkedSongs = []; error = nil; isLoading = false
        guard let link = RecognizedMusicLink.parse(linkText) else {
            error = "请输入网易云歌曲/歌单/专辑、Bilibili 视频/收藏夹或 YouTube 链接；也可输入 BV/av 号。"
            return
        }
        if let kind = link.kind {
            openCollection(OnlineCollection(source: link.source, sourceID: link.id, title: "链接歌单", kind: kind)); return
        }
        let token = generation; isLoading = true
        task = Task { [weak self] in
            do {
                let songs = try await online.songsForLink(link)
                guard let self, generation == token, !Task.isCancelled else { return }
                linkedSongs = songs; isLoading = false
            } catch {
                guard let self, generation == token, !Task.isCancelled else { return }
                self.error = error.localizedDescription; isLoading = false
            }
        }
    }
}
