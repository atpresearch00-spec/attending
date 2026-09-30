import AppKit
import CryptoKit
import Network
import AttendingCore

/// Spotify Web API for what AppleScript can't do: add the current song to a playlist,
/// like it, and tell whether a song is a Smart Shuffle pick. The user registers a free
/// Spotify developer app and signs in on Spotify's own page (OAuth with PKCE and a
/// loopback redirect); tokens live in a private 0600 file in the data folder.
@MainActor final class SpotifyService: ObservableObject {
    struct Playlist: Identifiable, Equatable { var id: String; var name: String }
    struct QueueTrack: Identifiable, Codable, Equatable {
        var id = UUID()
        var uri: String
        var name: String
        var artist: String
        var imageURL: String?
    }
    @Published private(set) var connected = false
    @Published private(set) var smartShuffle = false
    /// The playing song was added by Smart Shuffle (on, and not in the playlist being played).
    @Published private(set) var isSmartPick = false
    @Published private(set) var context: Playlist?
    @Published private(set) var liked: Bool?
    @Published private(set) var playlists: [Playlist] = []
    @Published var notice: String?
    @Published private(set) var connecting = false
    // MARK: Queue state
    /// Attending's editable Up Next list (reorder, remove). Songs are handed to
    /// Spotify one at a time, just before they're due, because Spotify's API can add
    /// to its queue but can't reorder or remove.
    @Published var upNext: [QueueTrack] = [] { didSet { saveUpNext() } }
    /// The song already handed to Spotify; it plays next and can't be recalled.
    @Published private(set) var pending: QueueTrack?
    /// What Spotify plays after that: the playlist and Smart Shuffle picks.
    @Published private(set) var spotifyQueue: [QueueTrack] = []
    @Published private(set) var searchResults: [QueueTrack] = []
    @Published var showingQueue = false
    private var skipPendingWhenItStarts = false

    static let redirect = "http://127.0.0.1:43821/callback"
    private var accessToken: String?
    private var accessExpiry = Date.distantPast
    private var currentURI: String?
    private var currentID: String?
    private var contextTracks: [String: Set<String>] = [:]
    private var myID: String?
    private var listener: NWListener?
    private var refreshTask: Task<Void, Never>?

    init() {
        connected = SpotifyStore.read("refreshToken") != nil
        if let data = UserDefaults.standard.data(forKey: "spotifyUpNext"), let saved = try? JSONDecoder().decode([QueueTrack].self, from: data) { upNext = saved }
    }
    private func saveUpNext() { UserDefaults.standard.set(try? JSONEncoder().encode(upNext), forKey: "spotifyUpNext") }
    var clientID: String? { SpotifyStore.read("clientID") }

    // MARK: Connect

    func connect(clientID raw: String) {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.count >= 20, id.allSatisfy({ $0.isLetter || $0.isNumber }) else { notice = "That doesn't look like a Spotify Client ID."; return }
        SpotifyStore.write("clientID", id)
        let verifier = Self.randomString(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = Self.randomString(16)
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            .init(name: "client_id", value: id), .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: Self.redirect), .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge), .init(name: "state", value: state),
            .init(name: "scope", value: "user-read-playback-state playlist-read-private playlist-read-collaborative playlist-modify-private playlist-modify-public user-library-read user-library-modify user-modify-playback-state")
        ]
        connecting = true
        listen(state: state) { [weak self] code in
            Task { await self?.exchange(code: code, verifier: verifier, clientID: id) }
        }
        NSWorkspace.shared.open(components.url!)
    }
    func disconnect() {
        SpotifyStore.delete("refreshToken"); accessToken = nil
        connected = false; isSmartPick = false; context = nil; liked = nil; playlists = []
    }

    /// One-shot loopback listener for the OAuth redirect.
    private func listen(state: String, onCode: @escaping @Sendable (String) -> Void) {
        listener?.cancel()
        // Loopback only: nothing outside this Mac can reach the listener.
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        guard let listener = try? NWListener(using: parameters, on: 43821) else { notice = "Port 43821 is busy; try again."; connecting = false; return }
        listener.newConnectionHandler = { connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                let items = URLComponents(string: "http://127.0.0.1\(target)")?.queryItems ?? []
                let code = items.first { $0.name == "code" }?.value
                let ok = code != nil && items.first { $0.name == "state" }?.value == state
                let body = ok ? "<h2 style='font-family:-apple-system'>Attending is connected to Spotify. You can close this tab.</h2>"
                              : "<h2 style='font-family:-apple-system'>Spotify sign-in didn't complete. Try again from Attending.</h2>"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                if ok, let code { onCode(code) }
            }
        }
        listener.start(queue: .main)
        self.listener = listener
        // Stop listening if sign-in isn't finished within five minutes.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(300))
            if self?.connecting == true { self?.listener?.cancel(); self?.connecting = false }
        }
    }
    private func exchange(code: String, verifier: String, clientID: String) async {
        listener?.cancel(); listener = nil
        let ok = await token(["grant_type": "authorization_code", "code": code, "redirect_uri": Self.redirect, "client_id": clientID, "code_verifier": verifier])
        connecting = false
        connected = ok
        notice = ok ? "Spotify connected." : "Spotify didn't accept the sign-in. Check the Client ID and Redirect URI."
        if ok { await refreshPlayer(); await loadPlaylists() }
    }
    private func token(_ form: [String: String]) async -> Bool {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }.joined(separator: "&").data(using: .utf8)
        guard let (data, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let access = json["access_token"] as? String else { return false }
        accessToken = access
        accessExpiry = Date().addingTimeInterval(TimeInterval(json["expires_in"] as? Int ?? 3600) - 60)
        if let refresh = json["refresh_token"] as? String { SpotifyStore.write("refreshToken", refresh) }
        return true
    }
    private func validToken() async -> String? {
        if let accessToken, Date() < accessExpiry { return accessToken }
        guard let refresh = SpotifyStore.read("refreshToken"), let clientID else { return nil }
        guard await token(["grant_type": "refresh_token", "refresh_token": refresh, "client_id": clientID]) else {
            connected = false; return nil
        }
        return accessToken
    }
    private func api(_ method: String, _ path: String, body: Any? = nil) async -> (Int, Any?) {
        guard let token = await validToken(), let url = URL(string: "https://api.spotify.com/v1" + path) else { return (401, nil) }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body { request.httpBody = try? JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return (0, nil) }
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data.isEmpty ? nil : try? JSONSerialization.jsonObject(with: data))
    }

    // MARK: Player state

    /// Called when the Spotify track changes; debounced so skipping fast stays cheap.
    func trackChanged() {
        guard connected else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            await self?.refreshPlayer()
        }
    }
    func refreshPlayer() async {
        let (status, json) = await api("GET", "/me/player")
        guard status == 200, let player = json as? [String: Any], let item = player["item"] as? [String: Any] else {
            isSmartPick = false; return
        }
        let previousURI = currentURI
        currentURI = item["uri"] as? String
        currentID = item["id"] as? String
        if currentURI != previousURI { await advanceQueue() }
        smartShuffle = player["smart_shuffle"] as? Bool ?? false
        if let ctx = player["context"] as? [String: Any], ctx["type"] as? String == "playlist", let uri = ctx["uri"] as? String {
            let id = String(uri.split(separator: ":").last ?? "")
            if context?.id != id {
                let (_, info) = await api("GET", "/playlists/\(id)?fields=name")
                context = Playlist(id: id, name: (info as? [String: Any])?["name"] as? String ?? "This playlist")
            }
            if contextTracks[id] == nil { contextTracks[id] = await playlistTrackURIs(id) }
        } else {
            context = nil
        }
        // Smart Shuffle mixes recommendations into the playlist being played: a song
        // that isn't in that playlist while Smart Shuffle is on came from Smart Shuffle.
        if smartShuffle, let context, let uri = currentURI, let tracks = contextTracks[context.id], !tracks.isEmpty {
            isSmartPick = !tracks.contains(uri)
        } else {
            isSmartPick = false
        }
        if let id = currentID {
            let (_, contains) = await api("GET", "/me/tracks/contains?ids=\(id)")
            liked = (contains as? [Bool])?.first
        }
    }
    private func playlistTrackURIs(_ id: String) async -> Set<String> {
        var uris = Set<String>()
        var path: String? = "/playlists/\(id)/tracks?fields=items(track(uri)),next&limit=100"
        var pages = 0
        while let next = path, pages < 30 {
            var (status, json) = await api("GET", next)
            if status == 404 || status == 410 {
                // Newer API versions call playlist entries "items".
                (status, json) = await api("GET", next.replacingOccurrences(of: "/tracks?", with: "/items?"))
            }
            guard status == 200, let page = json as? [String: Any] else { break }
            for entry in page["items"] as? [[String: Any]] ?? [] {
                if let uri = (entry["track"] as? [String: Any])?["uri"] as? String { uris.insert(uri) }
            }
            path = (page["next"] as? String).map { $0.replacingOccurrences(of: "https://api.spotify.com/v1", with: "") }
            pages += 1
        }
        return uris
    }

    // MARK: Queue

    /// When the handed-off song starts, hand off the next Up Next song.
    private func advanceQueue() async {
        if let pending, pending.uri == currentURI {
            self.pending = nil
            if skipPendingWhenItStarts { skipPendingWhenItStarts = false; _ = await api("POST", "/me/player/next"); return }
        }
        await feed()
        await refreshQueue()
    }
    private func feed() async {
        guard pending == nil, let next = upNext.first else { return }
        let encoded = next.uri.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? next.uri
        let (status, _) = await api("POST", "/me/player/queue?uri=\(encoded)")
        if (200..<300).contains(status) {
            pending = next
            upNext.removeFirst()
        } else if status == 403 || status == 401 {
            notice = "Reconnect Spotify in Settings to let Attending manage your queue."
        }
    }
    func refreshQueue() async {
        let (status, json) = await api("GET", "/me/player/queue")
        guard status == 200, let queue = (json as? [String: Any])?["queue"] as? [[String: Any]] else { return }
        var tracks = queue.compactMap(Self.track)
        // Spotify lists the handed-off song first; it's shown separately.
        if let pending, let index = tracks.firstIndex(where: { $0.uri == pending.uri }) { tracks.remove(at: index) }
        spotifyQueue = Array(tracks.prefix(20))
    }
    /// Whether a queued song came from Smart Shuffle (not in the playlist being played).
    func isSmartPick(_ track: QueueTrack) -> Bool {
        guard smartShuffle, let context, let tracks = contextTracks[context.id], !tracks.isEmpty else { return false }
        return !tracks.contains(track.uri)
    }
    func addToUpNext(_ track: QueueTrack, first: Bool = false) {
        var copy = track; copy.id = UUID()
        if first { upNext.insert(copy, at: 0) } else { upNext.append(copy) }
        Task { await feed(); await refreshQueue() }
    }
    func addCurrentToUpNext() {
        guard let uri = currentURI else { return }
        Task {
            let (_, json) = await api("GET", "/tracks/\(uri.split(separator: ":").last ?? "")")
            if let track = (json as? [String: Any]).flatMap(Self.track) { addToUpNext(track) }
        }
    }
    func move(from source: IndexSet, to destination: Int) { upNext.move(fromOffsets: source, toOffset: destination) }
    func remove(_ track: QueueTrack) { upNext.removeAll { $0.id == track.id } }
    /// The handed-off song can't be pulled back from Spotify, so it's skipped when it starts.
    func removePending() {
        guard pending != nil else { return }
        skipPendingWhenItStarts = true
        notice = "Will skip it when it comes up"
        Task { try? await Task.sleep(for: .seconds(3)); notice = nil }
    }
    var pendingWillBeSkipped: Bool { skipPendingWhenItStarts }
    func search(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { searchResults = []; return }
        Task {
            let q = trimmed.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? trimmed
            let (_, json) = await api("GET", "/search?type=track&limit=6&q=\(q)")
            let items = ((json as? [String: Any])?["tracks"] as? [String: Any])?["items"] as? [[String: Any]] ?? []
            searchResults = items.compactMap(Self.track)
        }
    }
    private static func track(_ json: [String: Any]) -> QueueTrack? {
        guard let uri = json["uri"] as? String, let name = json["name"] as? String else { return nil }
        let artist = (json["artists"] as? [[String: Any]])?.compactMap { $0["name"] as? String }.joined(separator: ", ") ?? ""
        let images = (json["album"] as? [String: Any])?["images"] as? [[String: Any]] ?? []
        let image = images.min { ($0["width"] as? Int ?? 999) < ($1["width"] as? Int ?? 999) }?["url"] as? String
        return QueueTrack(uri: uri, name: name, artist: artist, imageURL: image)
    }

    // MARK: Actions

    func loadPlaylists() async {
        if myID == nil { myID = ((await api("GET", "/me")).1 as? [String: Any])?["id"] as? String }
        let (_, json) = await api("GET", "/me/playlists?limit=50")
        let items = (json as? [String: Any])?["items"] as? [[String: Any]] ?? []
        playlists = items.compactMap { item in
            guard let id = item["id"] as? String, let name = item["name"] as? String else { return nil }
            let owner = (item["owner"] as? [String: Any])?["id"] as? String
            guard owner == myID || item["collaborative"] as? Bool == true else { return nil }
            return Playlist(id: id, name: name)
        }
    }
    func addCurrent(to playlist: Playlist) {
        guard let uri = currentURI else { return }
        Task {
            var (status, _) = await api("POST", "/playlists/\(playlist.id)/tracks", body: ["uris": [uri]])
            if status == 404 || status == 410 { (status, _) = await api("POST", "/playlists/\(playlist.id)/items", body: ["uris": [uri]]) }
            if (200..<300).contains(status) {
                contextTracks[playlist.id]?.insert(uri)
                if playlist.id == context?.id { isSmartPick = false }
                notice = "Added to \(playlist.name)"
            } else {
                notice = "Couldn't add to \(playlist.name)."
            }
            try? await Task.sleep(for: .seconds(3))
            notice = nil
        }
    }
    func toggleLike() {
        guard let id = currentID, let current = liked else { return }
        liked = !current
        Task {
            let (status, _) = await api(current ? "DELETE" : "PUT", "/me/tracks?ids=\(id)")
            if !(200..<300).contains(status) { liked = current }
        }
    }

    private static func randomString(_ length: Int) -> String {
        let characters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<length).map { _ in characters.randomElement()! })
    }
}

/// Spotify credentials in a private file (0600), like the Sheets connector.
enum SpotifyStore {
    nonisolated(unsafe) private static var cache: [String: String]?
    private static var file: URL { AppPaths.directory.appendingPathComponent("spotify.json") }
    static func read(_ key: String) -> String? { load()[key] }
    static func write(_ key: String, _ value: String) { var values = load(); values[key] = value; save(values) }
    static func delete(_ key: String) { var values = load(); values[key] = nil; save(values) }
    private static func load() -> [String: String] {
        if let cache { return cache }
        let values = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        cache = values
        return values
    }
    private static func save(_ values: [String: String]) {
        cache = values
        try? FileManager.default.createDirectory(at: AppPaths.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONEncoder().encode(values) else { return }
        try? data.write(to: file, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
