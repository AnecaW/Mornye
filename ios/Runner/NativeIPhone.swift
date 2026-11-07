import SwiftUI
import Flutter
import AVKit

// This channel carries presentation state and user intent only. The existing
// Dart controllers continue to own persistence, networking and audio sessions.
final class NativeIPhoneModel: ObservableObject {
    @Published var state: [String: Any] = [:]
    @Published var songs: [NativeSong] = []
    @Published var loading = false
    @Published var error: String?
    @Published var showPlayer = false
    private let channel: FlutterMethodChannel
    private var libraryRequest = 0

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: "com.zarz.mornye/native_iphone", binaryMessenger: messenger)
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self else { result(nil); return }
            switch call.method {
            case "state":
                let previous = self.state["libraryRevision"] as? String
                self.state = call.arguments as? [String: Any] ?? [:]
                if previous != nil, previous != self.state["libraryRevision"] as? String {
                    Task { @MainActor in await self.loadLibrary() }
                }
                result(nil)
            case "openPlayer": self.showPlayer = true; result(nil)
            case "error": self.error = (call.arguments as? [String: Any])?["message"] as? String; result(nil)
            default: result(FlutterMethodNotImplemented)
            }
        }
    }

    func request(_ method: String, _ args: [String: Any] = [:]) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            channel.invokeMethod(method, arguments: args) { value in
                if let failure = value as? FlutterError {
                    continuation.resume(throwing: NSError(domain: "Mornye", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: failure.message ?? failure.code]))
                } else if let object = value as? NSObject, object.isEqual(FlutterMethodNotImplemented) {
                    continuation.resume(throwing: NSError(domain: "Mornye", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Mornye is still starting. Try again in a moment."]))
                } else { continuation.resume(returning: value) }
            }
        }
    }

    func perform(_ method: String, _ args: [String: Any] = [:]) {
        Task { @MainActor in
            do { _ = try await request(method, args) }
            catch { self.error = error.localizedDescription }
        }
    }

    @MainActor func loadLibrary() async {
        libraryRequest += 1
        let generation = libraryRequest
        loading = true
        defer { if generation == libraryRequest { loading = false } }
        do {
            let value = try await request("library") as? [[String: Any]] ?? []
            if generation == libraryRequest { songs = value.map(NativeSong.init) }
        } catch { self.error = error.localizedDescription }
    }

    var ready: Bool { state["ready"] as? Bool ?? false }
    var playing: Bool { state["playing"] as? Bool ?? false }
    var now: NativeSong? { (state["now"] as? [String: Any]).map(NativeSong.init) }
    var position: Double { (state["position"] as? NSNumber)?.doubleValue ?? 0 }
    var settings: [String: Any] { state["settings"] as? [String: Any] ?? [:] }
    func rows(_ key: String) -> [[String: Any]] { state[key] as? [[String: Any]] ?? [] }
    func play(_ songs: [NativeSong], at index: Int = 0) {
        perform("playAll", ["ids": songs.map(\.id), "index": index])
    }
    func setting(_ key: String, _ value: Any) { perform("setting", ["key": key, "value": value]) }
}

struct NativeSong: Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let artwork: String
    let duration: Double
    let quality: String
    init(_ row: [String: Any]) {
        id = row["id"] as? String ?? ""
        title = row["title"] as? String ?? ""
        artist = row["artist"] as? String ?? ""
        album = row["album"] as? String ?? ""
        artwork = row["artwork"] as? String ?? ""
        duration = (row["duration"] as? NSNumber)?.doubleValue ?? 0
        quality = row["quality"] as? String ?? ""
    }
}

struct NativeAlbum: Identifiable {
    let id: String
    let title: String
    let artist: String
    let songs: [NativeSong]
}

extension Array where Element == NativeSong {
    var albums: [NativeAlbum] {
        Dictionary(grouping: self, by: { $0.album + "\u{1f}" + $0.artist })
            .map { key, songs in NativeAlbum(id: key, title: songs[0].album.isEmpty ? "Unknown Album" : songs[0].album,
                artist: songs[0].artist, songs: songs) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}

struct NativeArtwork: View {
    @EnvironmentObject private var model: NativeIPhoneModel
    let path: String
    var size: CGFloat = 52
    @State private var resolvedPath: String?
    private var effectivePath: String { resolvedPath ?? path }
    var body: some View {
        Group {
            if effectivePath.hasPrefix("http"), let url = URL(string: effectivePath) {
                AsyncImage(url: url) { image in image.resizable().scaledToFill() }
                    placeholder: { placeholder }
            } else if !effectivePath.isEmpty,
                let image = NativeArtworkCache.image(effectivePath) {
                Image(uiImage: image).resizable().scaledToFill()
            } else { placeholder }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size > 100 ? 18 : 8, style: .continuous))
        .accessibilityHidden(true)
        .task(id: path) {
            resolvedPath = nil
            if path.hasPrefix("network://") {
                resolvedPath = try? await model.request("artwork", ["path": path]) as? String
            }
        }
    }
    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [Color.accentColor.opacity(0.28), Color.secondary.opacity(0.12)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "music.note").font(.system(size: size * 0.32)).foregroundStyle(.secondary)
        }
    }
}

private enum NativeArtworkCache {
    static let images = NSCache<NSString, UIImage>()
    static func image(_ reference: String) -> UIImage? {
        if let image = images.object(forKey: reference as NSString) { return image }
        let path = reference.hasPrefix("file:") ? URL(string: reference)?.path ?? reference : reference
        guard path.hasPrefix("/"), let image = UIImage(contentsOfFile: path) else { return nil }
        images.countLimit = 120
        images.setObject(image, forKey: reference as NSString, cost: Int(image.size.width * image.size.height * 4))
        return image
    }
}

struct NativeIPhoneRoot: View {
    @ObservedObject var model: NativeIPhoneModel
    @State private var setup = false
    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                tabs.tabBarMinimizeBehavior(.onScrollDown)
                    .tabViewBottomAccessory {
                        if let song = model.now { miniPlayer(song) }
                    }
            } else {
                tabs.safeAreaInset(edge: .bottom, spacing: 0) {
                    if let song = model.now { miniPlayer(song).background(.regularMaterial) }
                }
            }
        }
        .tint(Color(red: 0.51, green: 0.30, blue: 0.93))
        .sheet(isPresented: $model.showPlayer) { NativeNowPlaying(model: model) }
        .sheet(isPresented: $setup) { NativeWelcome(model: model).interactiveDismissDisabled() }
        .onChange(of: model.ready) { ready in
            if ready {
                setup = model.state["firstLaunch"] as? Bool ?? false
                Task { await model.loadLibrary() }
            }
        }
        .onChange(of: model.state["firstLaunch"] as? Bool) { first in
            if first == false { setup = false }
        }
        .alert("Mornye", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .task {
            model.perform("refresh")
            if model.ready {
                setup = model.state["firstLaunch"] as? Bool ?? false
                await model.loadLibrary()
            }
        }
        .environmentObject(model)
    }
    private var tabs: some View {
        TabView {
            NativeHome(model: model).tabItem { Label("Listen", systemImage: "play.square.stack") }
            NativeLibrary(model: model).tabItem { Label("Library", systemImage: "music.note.house") }
            NativeSearch(model: model).tabItem { Label("Search", systemImage: "magnifyingglass") }
            NativeDownloads(model: model).tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
            NativeSettings(model: model).tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
    private func miniPlayer(_ song: NativeSong) -> some View {
        HStack(spacing: 12) {
            Button { model.showPlayer = true } label: {
                HStack {
                    NativeArtwork(path: song.artwork, size: 42)
                    VStack(alignment: .leading) {
                        Text(song.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(song.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Open Now Playing, \(song.title)")
            Button { model.perform("toggle") } label: {
                Image(systemName: model.playing ? "pause.fill" : "play.fill").font(.title3)
            }.accessibilityLabel(model.playing ? "Pause" : "Play").frame(minWidth: 44, minHeight: 44)
            Button { model.perform("next") } label: { Image(systemName: "forward.fill").font(.title3) }
                .accessibilityLabel("Next song").frame(minWidth: 44, minHeight: 44)
        }.padding(.horizontal, 16).padding(.vertical, 6)
    }
}

struct NativeHome: View {
    @ObservedObject var model: NativeIPhoneModel
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("YOUR MUSIC, YOUR WAY").font(.caption.weight(.bold)).tracking(2).foregroundStyle(.secondary)
                        Text("A little closer\nto the music.").font(.system(.largeTitle, design: .rounded, weight: .bold))
                        Text("Your collection. Every detail.").foregroundStyle(.secondary)
                        Button { model.perform("shuffleLibrary") } label: {
                            Label("Shuffle your library", systemImage: "shuffle").padding(.vertical, 6)
                        }.buttonStyle(.borderedProminent).controlSize(.large).disabled(model.songs.isEmpty)
                    }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 28))
                    if let now = model.now {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("On your turntable").font(.title2.bold())
                            Button { model.showPlayer = true } label: {
                                HStack(spacing: 16) {
                                    NativeArtwork(path: now.artwork, size: 88)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(now.title).font(.headline)
                                        Text(now.artist).foregroundStyle(.secondary)
                                        Label("Now Playing", systemImage: "waveform").font(.caption).foregroundStyle(Color.accentColor)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                    Text("From your collection").font(.title2.bold())
                    if model.loading { ProgressView().frame(maxWidth: .infinity) }
                    else if model.songs.isEmpty {
                        NativeEmpty(title: "Make room for your favorites", subtitle: "Add a music folder in Library, or install a provider in Settings to discover music.", symbol: "music.note.list")
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 18) {
                                ForEach(Array(model.songs.albums.prefix(20))) { album in
                                    NavigationLink { NativeCollection(model: model, album: album) } label: {
                                        VStack(alignment: .leading, spacing: 8) {
                                            NativeArtwork(path: album.songs.first?.artwork ?? "", size: 156)
                                            Text(album.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                            Text(album.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }.frame(width: 156, alignment: .leading)
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }.padding(20)
            }
            .navigationTitle("Mornye")
            .refreshable { await model.loadLibrary() }
            .background(Color(uiColor: .systemBackground))
        }
    }
}

struct NativeLibrary: View {
    @ObservedObject var model: NativeIPhoneModel
    @State private var filter = ""
    @State private var section = 0
    @State private var creatingPlaylist = false
    @State private var playlistName = ""
    private var songs: [NativeSong] {
        guard !filter.isEmpty else { return model.songs }
        return model.songs.filter { ($0.title + " " + $0.artist + " " + $0.album).localizedCaseInsensitiveContains(filter) }
    }
    var body: some View {
        NavigationStack {
            List {
                Picker("View", selection: $section) {
                    Text("Songs").tag(0); Text("Albums").tag(1); Text("Artists").tag(2); Text("Playlists").tag(3)
                }.pickerStyle(.segmented).listRowBackground(Color.clear)
                NavigationLink {
                    NativeSavedCollection(model: model, id: "loved", title: "Favorites")
                } label: { Label("Favorites", systemImage: "heart.fill") }
                if model.loading { ProgressView("Loading your music…") }
                if songs.isEmpty && !model.loading {
                    NativeEmpty(title: filter.isEmpty ? "Your library starts here" : "No matches",
                        subtitle: filter.isEmpty ? "Choose a folder to find your music." : "Try another title or artist.", symbol: "music.note.house")
                }
                if section == 0 {
                    ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                        NativeSongRow(song: song) { model.play(songs, at: index) }
                            .contextMenu { Button { model.perform("enqueue", ["id": song.id]) } label: {
                                Label("Add to queue", systemImage: "text.line.last.and.arrowtriangle.forward")
                            }
                                NativeSongActions(model: model, song: song)
                            }
                    }
                } else if section == 1 {
                    ForEach(songs.albums) { album in
                        NavigationLink { NativeCollection(model: model, album: album) } label: {
                            HStack { NativeArtwork(path: album.songs.first?.artwork ?? "")
                                VStack(alignment: .leading) { Text(album.title); Text(album.artist).font(.caption).foregroundStyle(.secondary) } }
                        }
                    }
                } else if section == 2 {
                    ForEach(Array(Set(songs.map(\.artist))).sorted(), id: \.self) { artist in
                        NavigationLink {
                            NativeCollection(model: model, album: NativeAlbum(id: artist, title: artist, artist: "Artist",
                                songs: songs.filter { $0.artist == artist }))
                        } label: { Label(artist, systemImage: "person.crop.circle") }
                    }
                } else {
                    ForEach(model.rows("playlists"), id: \.nativeID) { row in
                        NavigationLink {
                            NativeSavedCollection(model: model, id: row.nativeID, title: row["title"] as? String ?? "Playlist")
                        } label: {
                            Label(row["title"] as? String ?? "Playlist", systemImage: "music.note.list")
                        }
                    }
                    Button { creatingPlaylist = true } label: { Label("New playlist", systemImage: "plus") }
                }
                Section {
                    Button { model.perform("addFolder") } label: { Label("Add music folder", systemImage: "folder.badge.plus") }
                    Button { model.perform("openFiles") } label: { Label("Open audio files", systemImage: "doc.badge.plus") }
                    ForEach(model.rows("sources"), id: \.nativeID) { source in
                        Button { model.perform("scan", ["id": source.nativeID]) } label: {
                            Label(source["title"] as? String ?? "Folder", systemImage: "arrow.clockwise")
                        }
                    }
                    if model.state["scanning"] as? Bool == true { ProgressView("Scanning music…") }
                } header: { Text("Music folders") }
            }
            .navigationTitle("Library").searchable(text: $filter, prompt: "Songs, artists, albums")
            .refreshable { await model.loadLibrary() }
            .toolbar { ToolbarItem(placement: .primaryAction) { Button { model.perform("shuffleLibrary") } label: { Image(systemName: "shuffle") }.accessibilityLabel("Shuffle library") } }
            .alert("New playlist", isPresented: $creatingPlaylist) {
                TextField("Name", text: $playlistName)
                Button("Create") {
                    model.perform("createPlaylist", ["name": playlistName])
                    playlistName = ""
                }.disabled(playlistName.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel", role: .cancel) { playlistName = "" }
            }
        }
    }
}

struct NativeSongActions: View {
    @ObservedObject var model: NativeIPhoneModel
    let song: NativeSong
    var body: some View {
        Button { model.perform("love", ["id": song.id]) } label: { Label("Toggle favorite", systemImage: "heart") }
        if !model.rows("playlists").isEmpty {
            Menu("Add to playlist") {
                ForEach(model.rows("playlists"), id: \.nativeID) { row in
                    Button(row["title"] as? String ?? "Playlist") {
                        model.perform("addToPlaylist", ["id": song.id, "playlist": row.nativeID])
                    }
                }
            }
        }
    }
}

struct NativeSavedCollection: View {
    @ObservedObject var model: NativeIPhoneModel
    let id: String
    let title: String
    @State private var songs: [NativeSong] = []
    @State private var loading = true
    var body: some View {
        List {
            if loading { ProgressView("Loading music…") }
            if !loading && songs.isEmpty { NativeEmpty(title: "No songs yet", subtitle: "Add songs from your library or search results.", symbol: "music.note.list") }
            ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
                NativeSongRow(song: song) {
                    model.perform("playCatalog", ["ids": songs.map(\.id), "index": index])
                }.contextMenu { NativeSongActions(model: model, song: song) }
            }
        }.navigationTitle(title)
            .task { await load() }.refreshable { await load() }
    }
    @MainActor private func load() async {
        defer { loading = false }
        do {
            let rows = try await model.request("collection", ["id": id]) as? [[String: Any]] ?? []
            songs = rows.map(NativeSong.init)
        } catch { model.error = error.localizedDescription }
    }
}

struct NativeCollection: View {
    @ObservedObject var model: NativeIPhoneModel
    let album: NativeAlbum
    var body: some View {
        List {
            VStack(spacing: 16) {
                NativeArtwork(path: album.songs.first?.artwork ?? "", size: 230)
                Text(album.title).font(.title2.bold()).multilineTextAlignment(.center)
                Text(album.artist).foregroundStyle(.secondary)
                Button { model.play(album.songs) } label: { Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }.frame(maxWidth: .infinity).padding(.vertical).listRowBackground(Color.clear)
            ForEach(Array(album.songs.enumerated()), id: \.element.id) { index, song in
                NativeSongRow(song: song) { model.play(album.songs, at: index) }
            }
        }.navigationTitle(album.title).navigationBarTitleDisplayMode(.inline)
    }
}

struct NativeSongRow: View {
    let song: NativeSong
    var symbol = "play.fill"
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                NativeArtwork(path: song.artwork)
                VStack(alignment: .leading, spacing: 4) {
                    Text(song.title).font(.body).foregroundStyle(.primary).lineLimit(2)
                    Text(song.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    if !song.quality.isEmpty { Text(song.quality).font(.caption2).foregroundStyle(.tertiary) }
                }
                Spacer(minLength: 8)
                Image(systemName: symbol).font(.subheadline).foregroundStyle(Color.accentColor)
            }.padding(.vertical, 3).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("\(song.title), \(song.artist)")
    }
}

struct NativeSearch: View {
    @ObservedObject var model: NativeIPhoneModel
    @State private var query = ""
    @State private var results: [NativeSong] = []
    @State private var loading = false
    @State private var generation = 0
    @State private var searched = false
    var body: some View {
        NavigationStack {
            List {
                if loading { ProgressView("Searching providers…") }
                if results.isEmpty && !loading {
                    NativeEmpty(title: searched ? "No results" : "Find your next favorite",
                        subtitle: searched ? "Try a different song or artist." : "Search music using your installed metadata providers.", symbol: "magnifyingglass")
                }
                ForEach(results) { song in
                    NativeSongRow(song: song, symbol: "arrow.down.circle") { model.perform("download", ["id": song.id]) }
                        .contextMenu { NativeSongActions(model: model, song: song) }
                }
                if !results.isEmpty { Text("Tap a song to add it to Downloads.").font(.footnote).foregroundStyle(.secondary) }
            }.navigationTitle("Search")
            .searchable(text: $query, prompt: "Songs and artists")
            .onSubmit(of: .search) { search() }
            .onChange(of: query) { value in
                generation += 1
                if value.isEmpty { results = []; searched = false; loading = false }
            }
        }
    }
    private func search() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        generation += 1
        let request = generation
        loading = true
        Task { @MainActor in
            defer { if request == generation { loading = false } }
            do {
                let rows = try await model.request("search", ["query": text]) as? [[String: Any]] ?? []
                if request == generation { results = rows.map(NativeSong.init); searched = true }
            } catch { if request == generation { model.error = error.localizedDescription } }
        }
    }
}

struct NativeDownloads: View {
    @ObservedObject var model: NativeIPhoneModel
    var body: some View {
        NavigationStack {
            List {
                if model.rows("downloads").isEmpty {
                    NativeEmpty(title: "All caught up", subtitle: "Music you download appears here. Your existing queue is kept between launches.", symbol: "arrow.down.circle")
                }
                ForEach(model.rows("downloads"), id: \.nativeID) { row in
                    VStack(alignment: .leading, spacing: 10) {
                        NativeSongRow(song: NativeSong(row), symbol: row["status"] as? String == "failed" ? "arrow.clockwise" : "arrow.down") {
                            if row["status"] as? String == "failed" { model.perform("retryDownload", ["id": row.nativeID]) }
                        }
                        ProgressView(value: (row["progress"] as? NSNumber)?.doubleValue ?? 0)
                        Text(row["status"] as? String ?? "").font(.caption).foregroundStyle(.secondary)
                        if let error = row["error"] as? String, !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red) }
                    }.padding(.vertical, 4)
                    .swipeActions { Button("Cancel", role: .destructive) { model.perform("cancelDownload", ["id": row.nativeID]) } }
                }
            }.navigationTitle("Downloads")
                .toolbar { ToolbarItem(placement: .primaryAction) {
                    Button(model.state["downloadsPaused"] as? Bool == true ? "Resume" : "Pause") { model.perform("pauseDownloads") }
                        .disabled(model.rows("downloads").isEmpty)
                } }
        }
    }
}

struct NativeNowPlaying: View {
    @ObservedObject var model: NativeIPhoneModel
    @Environment(\.dismiss) private var dismiss
    @State private var seeking = false
    @State private var seekPosition = 0.0
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    if let song = model.now {
                        VStack(spacing: 24) {
                            NativeArtwork(path: song.artwork, size: min(geometry.size.width - 56, 350))
                                .shadow(color: .black.opacity(0.18), radius: 24, y: 12).padding(.top, 20)
                            VStack(spacing: 8) {
                                Text(song.title).font(.title2.bold()).multilineTextAlignment(.center)
                                Text(song.artist).font(.title3).foregroundStyle(.secondary)
                                Text(song.album).font(.subheadline).foregroundStyle(.tertiary)
                            }
                            VStack(spacing: 4) {
                                Slider(value: Binding(get: { seeking ? seekPosition : min(model.position / 1000, max(1, song.duration)) },
                                    set: { seekPosition = $0 }), in: 0...max(1, song.duration)) { editing in
                                        if editing { seekPosition = model.position / 1000 }
                                        seeking = editing
                                        if !editing { model.perform("seek", ["position": seekPosition * 1000]) }
                                    }.accessibilityLabel("Playback position")
                                HStack { Text(time(seeking ? seekPosition : model.position / 1000)); Spacer(); Text(time(song.duration)) }
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            HStack(spacing: 30) {
                                Button { model.perform("previous") } label: { Image(systemName: "backward.fill").font(.system(size: 30)) }
                                    .accessibilityLabel("Previous song").frame(minWidth: 44, minHeight: 44)
                                Button { model.perform("toggle") } label: {
                                    Image(systemName: model.playing ? "pause.fill" : "play.fill").font(.system(size: 42)).frame(width: 82, height: 82)
                                }.buttonStyle(NativeTransportStyle()).accessibilityLabel(model.playing ? "Pause" : "Play")
                                Button { model.perform("next") } label: { Image(systemName: "forward.fill").font(.system(size: 30)) }
                                    .accessibilityLabel("Next song").frame(minWidth: 44, minHeight: 44)
                            }.foregroundStyle(.primary)
                            HStack {
                                Button { model.perform("shuffle", ["enabled": !(model.state["shuffle"] as? Bool ?? false)]) } label: {
                                    Image(systemName: "shuffle").foregroundStyle(model.state["shuffle"] as? Bool == true ? Color.accentColor : Color.secondary)
                                }.accessibilityLabel("Shuffle").frame(minWidth: 44, minHeight: 44)
                                Spacer()
                                NativeRoutePicker().frame(width: 44, height: 44).accessibilityLabel("Audio output")
                                Spacer()
                                Button {
                                    let current = model.state["repeat"] as? String ?? "none"
                                    model.perform("repeat", ["mode": current == "none" ? "all" : current == "all" ? "one" : "none"])
                                } label: {
                                    Image(systemName: model.state["repeat"] as? String == "one" ? "repeat.1" : "repeat")
                                        .foregroundStyle(model.state["repeat"] as? String == "none" ? Color.secondary : Color.accentColor)
                                }.accessibilityLabel("Repeat").frame(minWidth: 44, minHeight: 44)
                            }.font(.title3)
                            NavigationLink { queue } label: { Label("Playing next", systemImage: "list.bullet") }
                            HStack(spacing: 28) {
                                NavigationLink { NativeLyrics(model: model) } label: { Label("Lyrics", systemImage: "quote.bubble") }
                                Button { model.perform("love", ["id": song.id]) } label: { Image(systemName: "heart") }.accessibilityLabel("Toggle favorite")
                                NavigationLink { NativeTrackDetails(model: model) } label: { Image(systemName: "info.circle") }.accessibilityLabel("Track details")
                            }
                        }.padding(.horizontal, 28).padding(.bottom, 30)
                    } else {
                        NativeEmpty(title: "Nothing playing yet", subtitle: "Choose a song from your library.", symbol: "music.note")
                    }
                }
            }
            .navigationTitle("Now Playing").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Image(systemName: "chevron.down") }.accessibilityLabel("Close player") } }
        }.presentationDragIndicator(.visible)
    }
    private var queue: some View {
        List {
            ForEach(Array(model.rows("queue").enumerated()), id: \.offset) { index, row in
                NativeSongRow(song: NativeSong(row)) { model.perform("jump", ["index": index]) }
            }
        }.navigationTitle("Playing next")
    }
    private func time(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.isFinite ? seconds : 0))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

struct NativeLyrics: View {
    @ObservedObject var model: NativeIPhoneModel
    @State private var lyrics: [String: Any] = [:]
    @State private var busy = false
    private var lines: [[String: Any]] { lyrics["lines"] as? [[String: Any]] ?? [] }
    private var activeIndex: Int? {
        guard lyrics["synced"] as? Bool == true else { return nil }
        return lines.lastIndex { (($0["time"] as? NSNumber)?.doubleValue ?? .infinity) <= model.position }
    }
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if busy { ProgressView("Loading lyrics…").frame(maxWidth: .infinity) }
                    if lines.isEmpty {
                        if let plain = lyrics["plain"] as? String, !plain.isEmpty {
                            Text(plain).font(.title2.weight(.semibold)).textSelection(.enabled)
                        } else if !busy {
                            NativeEmpty(title: "No lyrics yet", subtitle: "Find lyrics using your configured providers.", symbol: "quote.bubble")
                        }
                    }
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Button {
                            if lyrics["synced"] as? Bool == true {
                                model.perform("seek", ["position": (line["time"] as? NSNumber)?.doubleValue ?? 0])
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(line["text"] as? String ?? "").font(.system(.title, design: .rounded, weight: .bold))
                                if let translation = line["translation"] as? String, !translation.isEmpty { Text(translation).font(.body) }
                            }.foregroundStyle(activeIndex == nil || activeIndex == index ? Color.primary : Color.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain).id(index)
                    }
                }.padding(28)
            }
            .onChange(of: activeIndex) { index in
                if let index { withAnimation { proxy.scrollTo(index, anchor: .center) } }
            }
        }
        .navigationTitle("Lyrics")
        .toolbar { ToolbarItem(placement: .primaryAction) { Button("Find lyrics") { Task { await load(search: true) } }.disabled(busy) } }
        .task(id: model.now?.id) { await load(search: false) }
    }
    @MainActor private func load(search: Bool) async {
        let id = model.now?.id
        busy = true
        defer { busy = false }
        do {
            let result = try await model.request(search ? "searchLyrics" : "lyrics") as? [String: Any] ?? [:]
            if id == model.now?.id { lyrics = result }
        } catch { model.error = error.localizedDescription }
    }
}

struct NativeTrackDetails: View {
    @ObservedObject var model: NativeIPhoneModel
    @State private var details: [String: Any] = [:]
    var body: some View {
        List {
            ForEach(details.keys.sorted(), id: \.self) { key in
                if key != "lyrics", let value = details[key], !String(describing: value).isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(key.replacingOccurrences(of: "_", with: " ").capitalized).font(.caption).foregroundStyle(.secondary)
                        Text(String(describing: value)).textSelection(.enabled)
                    }
                }
            }
        }.navigationTitle("Track details").task(id: model.now?.id) {
            do { details = try await model.request("trackDetails") as? [String: Any] ?? [:] }
            catch { model.error = error.localizedDescription }
        }
    }
}

struct NativeTransportStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        if #available(iOS 26.0, *) {
            configuration.label.glassEffect(.regular.interactive(), in: .circle)
                .scaleEffect(configuration.isPressed ? 0.94 : 1)
        } else {
            configuration.label.background(.regularMaterial, in: Circle())
                .scaleEffect(configuration.isPressed ? 0.94 : 1)
        }
    }
}

struct NativeRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

struct NativeSettings: View {
    @ObservedObject var model: NativeIPhoneModel
    private func toggle(_ title: String, _ key: String) -> some View {
        Toggle(title, isOn: Binding(get: { model.settings[key] as? Bool ?? false }, set: { model.setting(key, $0) }))
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: "waveform").font(.largeTitle).foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading) { Text("Mornye").font(.title2.bold()); Text("Made for your music.").foregroundStyle(.secondary) }
                    }.padding(.vertical, 10)
                }
                Section("Playback") {
                    toggle("Gapless playback", "gaplessPlayback")
                    toggle("Autoplay", "autoplay")
                    toggle("Volume normalization", "playbackNormalization")
                    toggle("Music Haptics", "musicHaptics")
                }
                Section("Downloads") {
                    Picker("Provider", selection: Binding(get: { model.settings["defaultService"] as? String ?? "" }, set: { model.setting("defaultService", $0) })) {
                        Text("Choose a provider").tag("")
                        ForEach(model.rows("extensions").filter { $0["canDownload"] as? Bool == true && $0["enabled"] as? Bool == true }, id: \.nativeID) { row in Text(row["title"] as? String ?? row.nativeID).tag(row.nativeID) }
                    }
                    Picker("Quality", selection: Binding(get: { model.settings["audioQuality"] as? String ?? "" }, set: { model.setting("audioQuality", $0) })) {
                        ForEach(qualities, id: \.nativeID) { row in Text(row["title"] as? String ?? row.nativeID).tag(row.nativeID) }
                    }
                    toggle("Provider fallback", "autoFallback")
                    toggle("Embed metadata", "embedMetadata")
                    toggle("Embed lyrics", "embedLyrics")
                }
                Section("Extensions") {
                    NavigationLink { NativeExtensionStore(model: model) } label: { Label("Browse extensions", systemImage: "square.grid.2x2") }
                    ForEach(model.rows("extensions"), id: \.nativeID) { row in
                        NavigationLink {
                            NativeExtensionEditor(model: model, id: row.nativeID, title: row["title"] as? String ?? row.nativeID)
                        } label: {
                            VStack(alignment: .leading) { Text(row["title"] as? String ?? row.nativeID); Text(row["version"] as? String ?? "").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                Section("About") {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                    Link("Source code", destination: URL(string: "https://github.com/AnecaW/Mornye/tree/codex/native-iphone")!)
                    Link("Licenses", destination: URL(string: "https://github.com/mornyeapp/Mornye/blob/main/LICENSE")!)
                }
            }.navigationTitle("Settings")
        }
    }
    private var qualities: [[String: Any]] {
        let provider = model.settings["defaultService"] as? String ?? ""
        let options = model.rows("extensions").first { $0.nativeID == provider }?["qualities"] as? [[String: Any]] ?? []
        let current = model.settings["audioQuality"] as? String ?? "LOSSLESS"
        return options.contains { $0.nativeID == current } ? options : [["id": current, "title": current]] + options
    }
}

struct NativeExtensionEditor: View {
    @ObservedObject var model: NativeIPhoneModel
    let id: String
    let title: String
    @State private var fields: [[String: Any]] = []
    @State private var values: [String: String] = [:]
    @State private var busy = false
    @State private var accountForm: [String: Any]?
    @State private var accountValues: [String: String] = [:]
    @State private var message: String?
    var body: some View {
        Form {
            Toggle("Enabled", isOn: Binding(get: {
                model.rows("extensions").first { $0.nativeID == id }?["enabled"] as? Bool ?? false
            }, set: { model.perform("toggleExtension", ["id": id, "enabled": $0]) }))
            ForEach(fields, id: \.nativeID) { field in
                Section {
                    fieldEditor(field)
                } footer: { Text(field["description"] as? String ?? "") }
            }
            if busy { ProgressView() }
            if let message { Text(message).foregroundStyle(.secondary) }
        }
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(isPresented: Binding(get: { accountForm != nil }, set: { if !$0 { cancelForm() } })) {
            NavigationStack {
                Form {
                    Text(accountForm?["description"] as? String ?? "")
                    ForEach(accountForm?["fields"] as? [[String: Any]] ?? [], id: \.accountKey) { field in
                        let key = field.accountKey
                        let label = field["label"] as? String ?? key
                        let binding = Binding(get: { accountValues[key] ?? "" }, set: { accountValues[key] = $0 })
                        if field["type"] as? String == "password" {
                            SecureField(label, text: binding).textInputAutocapitalization(.never).autocorrectionDisabled()
                        } else if field["type"] as? String == "select" {
                            Picker(label, selection: binding) {
                                ForEach(field["options"] as? [String] ?? [], id: \.self) { Text($0).tag($0) }
                            }
                        } else {
                            TextField(label, text: binding).textInputAutocapitalization(.never).autocorrectionDisabled()
                                .keyboardType(field["type"] as? String == "otp" ? .numberPad : .default)
                        }
                    }
                    Button("Continue") { submitForm() }.disabled(busy)
                }.navigationTitle(accountForm?["title"] as? String ?? "Sign in")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { cancelForm() } } }
            }.interactiveDismissDisabled(busy)
        }
        .onDisappear { values.removeAll(); accountValues.removeAll() }
    }

    @ViewBuilder private func fieldEditor(_ field: [String: Any]) -> some View {
        let key = field.nativeID
        let label = field["title"] as? String ?? key
        let type = field["type"] as? String ?? "string"
        let binding = Binding(get: { values[key] ?? "" }, set: { values[key] = $0 })
        if let action = field["action"] as? String, !action.isEmpty {
            Button(label) { runAction(action) }.disabled(busy)
        } else if type == "boolean" || type == "bool" {
            Toggle(label, isOn: Binding(get: { values[key] == "true" }, set: { value in
                values[key] = value ? "true" : "false"
                model.perform("saveExtensionSetting", ["id": id, "key": key, "value": value])
            }))
        } else if let options = field["options"] as? [String], !options.isEmpty {
            Picker(label, selection: Binding(get: { values[key] ?? options[0] }, set: { value in
                values[key] = value
                model.perform("saveExtensionSetting", ["id": id, "key": key, "value": value])
            })) { ForEach(options, id: \.self) { Text($0).tag($0) } }
        } else {
            if type == "password" || type == "secret" {
                SecureField(label, text: binding).textInputAutocapitalization(.never).autocorrectionDisabled()
            } else {
                TextField(label, text: binding).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            Button("Save") {
                let value: Any = type == "number" ? (Double(values[key] ?? "") ?? 0) : (values[key] ?? "")
                model.perform("saveExtensionSetting", ["id": id, "key": key, "value": value])
            }
        }
    }

    @MainActor private func load() async {
        do {
            let result = try await model.request("extensionSettings", ["id": id]) as? [String: Any] ?? [:]
            fields = result["fields"] as? [[String: Any]] ?? []
            for field in fields {
                let value = field["value"]
                values[field.nativeID] = (value as? Bool).map { $0 ? "true" : "false" } ?? value.map { String(describing: $0) } ?? ""
            }
        } catch { model.error = error.localizedDescription }
    }
    private func runAction(_ action: String, input: [String: String]? = nil) {
        busy = true
        Task { @MainActor in
            defer { busy = false; accountValues.removeAll() }
            do {
                var args: [String: Any] = ["id": id, "action": action]
                if let input { args["input"] = input }
                let result = try await model.request("extensionAction", args) as? [String: Any] ?? [:]
                if let form = (result["action_form"] ?? result["byoa_form"]) as? [String: Any] {
                    accountForm = form
                } else {
                    accountForm = nil
                    message = result["error"] as? String ?? result["message"] as? String ?? "Done"
                    await load()
                }
            } catch { model.error = error.localizedDescription }
        }
    }
    private func submitForm() {
        guard let action = accountForm?["submit_action"] as? String else { return }
        runAction(action, input: accountValues)
    }
    private func cancelForm() {
        if let cancel = accountForm?["cancel_action"] as? String, !cancel.isEmpty {
            model.perform("extensionAction", ["id": id, "action": cancel])
        }
        accountForm = nil
        accountValues.removeAll()
    }
}

struct NativeExtensionStore: View {
    @ObservedObject var model: NativeIPhoneModel
    @State private var rows: [[String: Any]] = []
    @State private var loading = true
    @State private var installing: String?
    var body: some View {
        List {
            if loading { ProgressView("Loading extensions…") }
            ForEach(rows, id: \.nativeID) { row in
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(row["name"] as? String ?? row.nativeID).font(.headline)
                        Text(row["description"] as? String ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.rows("extensions").contains(where: { $0.nativeID == row.nativeID }) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Installed")
                    } else if installing == row.nativeID { ProgressView() }
                    else { Button("Get") { install(row.nativeID) }.buttonStyle(.bordered).disabled(installing != nil) }
                }.padding(.vertical, 4)
            }
        }.navigationTitle("Extensions")
            .task {
                defer { loading = false }
                do { rows = try await model.request("store") as? [[String: Any]] ?? [] }
                catch { model.error = error.localizedDescription }
            }
    }
    private func install(_ id: String) {
        installing = id
        Task { @MainActor in
            defer { installing = nil }
            do { _ = try await model.request("install", ["id": id]) }
            catch { model.error = error.localizedDescription }
        }
    }
}

struct NativeWelcome: View {
    @ObservedObject var model: NativeIPhoneModel
    @State private var busy = false
    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer()
                Image(systemName: "waveform").font(.system(size: 76)).foregroundStyle(Color.accentColor)
                Text("Welcome to Mornye").font(.largeTitle.bold()).multilineTextAlignment(.center)
                Text("Your music, beautifully at home on iPhone.").font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
                VStack(alignment: .leading, spacing: 20) {
                    Label("Bring your own music collection", systemImage: "music.note.house")
                    Label("Discover music with extensions", systemImage: "square.grid.2x2")
                    Label("Listen with native iPhone controls", systemImage: "airplay.audio")
                }.padding(.vertical)
                Spacer()
                Button {
                    busy = true
                    Task { @MainActor in
                        defer { busy = false }
                        do { _ = try await model.request("completeSetup") }
                        catch { model.error = error.localizedDescription }
                    }
                } label: { HStack { if busy { ProgressView() }; Text("Get started") }.frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(busy)
            }.padding(30)
        }
    }
}

struct NativeEmpty: View {
    let title: String
    let subtitle: String
    let symbol: String
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 42)).foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(.vertical, 34).padding(.horizontal, 16)
    }
}

extension Dictionary where Key == String, Value == Any {
    var nativeID: String { self["id"] as? String ?? "" }
    var accountKey: String { self["key"] as? String ?? "" }
}

/// Retain and attach the existing engine for plugins requiring a view
/// controller. It paints no app UI; SwiftUI owns the visible hierarchy.
final class NativeIPhoneController: UIViewController {
    private let engine: FlutterEngine
    private let model: NativeIPhoneModel
    init(engine: FlutterEngine, model: NativeIPhoneModel) {
        self.engine = engine; self.model = model
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        let runtime = FlutterViewController(engine: engine, nibName: nil, bundle: nil)
        addChild(runtime)
        runtime.view.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        runtime.view.alpha = 0
        runtime.view.isUserInteractionEnabled = false
        runtime.view.accessibilityElementsHidden = true
        view.addSubview(runtime.view)
        runtime.didMove(toParent: self)
        let host = UIHostingController(rootView: NativeIPhoneRoot(model: model))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
    }
}
