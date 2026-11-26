import AppKit
import SwiftUI

/// Subtitles for what is playing, shown over everything at the bottom of the
/// screen, line by line: the words of a song from LRCLIB, or a film's
/// subtitles from OpenSubtitles, translated if Settings asks for it.
/// Turned on and off by the bars in the card.
@MainActor
final class LyricsController: ObservableObject {
    static let shared = LyricsController()

    /// Settings keys.
    static let languageKey = "subtitleLanguage"
    static let openSubtitlesKey = "openSubtitlesKey"
    /// The languages Settings offers to translate into, code and name; "" is off.
    static let languages: [(code: String, name: String)] = [
        ("", "Off"), ("ru", "Русский"), ("en", "English"), ("uk", "Українська"),
        ("de", "Deutsch"), ("fr", "Français"), ("es", "Español"), ("it", "Italiano")
    ]

    @Published private(set) var isOn = false
    /// The line being said or sung, in the chosen language.
    @Published private(set) var current = ""
    /// Under it: the original when translating, else the next line.
    @Published private(set) var second = ""

    private struct Line {
        let start: Double
        /// Film subtitles end; a song's line lasts until the next.
        var end: Double?
        let text: String
        var translation: String?
    }

    private weak var model: NowPlayingModel?
    private var window: NSPanel?
    private var timer: Timer?
    /// "title|artist|language" of what the lines are for.
    private var trackKey = ""
    private var lines: [Line] = []
    /// Lines with no times: spread evenly over the track.
    private var unsynced = false
    private var tasks: [URLSessionTask] = []

    private var language: String { UserDefaults.standard.string(forKey: Self.languageKey) ?? "ru" }
    private var apiKey: String {
        (UserDefaults.standard.string(forKey: Self.openSubtitlesKey) ?? "").trimmingCharacters(in: .whitespaces)
    }

    func toggle(_ model: NowPlayingModel) {
        isOn ? stop() : start(model)
    }

    private func start(_ model: NowPlayingModel) {
        self.model = model
        isOn = true
        trackKey = ""
        showWindow()
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated { LyricsController.shared.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    private func stop() {
        isOn = false
        timer?.invalidate(); timer = nil
        cancelAll()
        window?.orderOut(nil); window = nil
        lines = []; trackKey = ""; current = ""; second = ""
    }

    private func cancelAll() {
        tasks.forEach { $0.cancel() }
        tasks = []
    }

    /// The player the subtitles are for: the one playing, else the one that
    /// played last, else the first.
    private var player: NowPlayingModel.Player? {
        guard let model else { return nil }
        let all = model.players.filter(\.hasTrack)
        return all.first(where: \.isPlaying)
            ?? all.first { $0.id == model.lastPlayedID }
            ?? all.first
    }

    private func tick() {
        guard let player else { show("Nothing is playing", ""); return }
        let key = [player.title, player.artist, language].joined(separator: "|")
        if key != trackKey {
            trackKey = key
            lines = []
            show("Searching subtitles…", player.title)
            find(for: player, key: key)
            return
        }
        guard !lines.isEmpty, let progress = player.progress else { return }
        let time = progress.elapsed(at: Date())
        let index: Int
        if unsynced {
            index = min(Int(time / max(progress.duration, 1) * Double(lines.count)), lines.count - 1)
        } else {
            index = (lines.lastIndex { $0.start <= time + 0.2 }) ?? -1
        }
        guard index >= 0, lines[index].end.map({ time <= $0 }) ?? true else { show("", ""); return }
        let line = lines[index]
        if let translation = line.translation, translation != line.text {
            show(translation, line.text)
        } else {
            show(line.text, line.end == nil && index + 1 < lines.count ? lines[index + 1].text : "")
        }
    }

    private func show(_ first: String, _ under: String) {
        if first != current { current = first }
        if under != second { second = under }
    }

    // MARK: Finding them

    /// A film when it is long or comes from a site that is not for music,
    /// and OpenSubtitles can be asked; a song otherwise. Each falls back on
    /// the other.
    private func find(for player: NowPlayingModel.Player, key: String) {
        cancelAll()
        let duration = player.progress?.duration ?? 0
        let looksLikeFilm = duration > 20 * 60
        let song = { [weak self] (then: @escaping @MainActor () -> Void) in
            self?.findLyrics(title: player.title, artist: player.artist, duration: duration, key: key, otherwise: then)
        }
        let film = { [weak self] (then: @escaping @MainActor () -> Void) in
            guard let self, !self.apiKey.isEmpty else { then(); return }
            self.findFilm(title: player.title, key: key, otherwise: then)
        }
        let nothing: @MainActor () -> Void = { [weak self] in
            guard let self, key == self.trackKey else { return }
            self.show("No subtitles found", self.apiKey.isEmpty && looksLikeFilm
                      ? "Add an OpenSubtitles key in Settings for films" : "")
        }
        if looksLikeFilm { film { song(nothing) } } else { song { film(nothing) } }
    }

    private func findLyrics(title: String, artist: String, duration: Double, key: String,
                            otherwise: @escaping @MainActor () -> Void) {
        // Tabs carry the site as the artist and "Artist - Song" as the title.
        var title = title, artist = artist
        if artist.contains("."), let dash = title.range(of: " - ") {
            artist = String(title[..<dash.lowerBound])
            title = String(title[dash.upperBound...])
        }
        title = title.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*(official|video|audio|lyrics|clip|hd|4k)[^\)\]]*[\)\]]"#,
                                           with: "", options: [.regularExpression, .caseInsensitive])
        var get = URLComponents(string: "https://lrclib.net/api/get")!
        get.queryItems = [URLQueryItem(name: "track_name", value: title),
                          URLQueryItem(name: "artist_name", value: artist)]
        if duration > 0 {
            get.queryItems?.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded()))))
        }
        var search = URLComponents(string: "https://lrclib.net/api/search")!
        search.queryItems = [URLQueryItem(name: "q", value: artist.contains(".") ? title : "\(artist) \(title)")]

        json(URLRequest(url: get.url!)) { [weak self] found in
            if let found = found as? [String: Any], Self.hasWords(found) {
                self?.useLyrics(found, key: key, otherwise: otherwise)
                return
            }
            self?.json(URLRequest(url: search.url!)) { results in
                let results = (results as? [[String: Any]]) ?? []
                let best = results.first { ($0["syncedLyrics"] as? String)?.isEmpty == false }
                    ?? results.first(where: Self.hasWords)
                self?.useLyrics(best, key: key, otherwise: otherwise)
            }
        }
    }

    private static func hasWords(_ entry: [String: Any]) -> Bool {
        (entry["syncedLyrics"] as? String)?.isEmpty == false || (entry["plainLyrics"] as? String)?.isEmpty == false
    }

    private func useLyrics(_ entry: [String: Any]?, key: String, otherwise: @escaping @MainActor () -> Void) {
        guard isOn, key == trackKey else { return }
        if let synced = entry?["syncedLyrics"] as? String, !synced.isEmpty {
            use(Self.parseLRC(synced), unsynced: false, key: key)
        } else if let plain = entry?["plainLyrics"] as? String, !plain.isEmpty {
            use(plain.split(separator: "\n").map { Line(start: 0, text: String($0)) }, unsynced: true, key: key)
        } else {
            otherwise()
        }
    }

    /// OpenSubtitles: search by the cleaned-up title, the chosen language
    /// first and English after, then download the best file as SRT.
    private func findFilm(title: String, key: String, otherwise: @escaping @MainActor () -> Void) {
        let (name, year) = Self.filmName(title)
        guard !name.isEmpty else { otherwise(); return }
        let wanted = [language, "en"].filter { !$0.isEmpty }
        var search = URLComponents(string: "https://api.opensubtitles.com/api/v1/subtitles")!
        search.queryItems = [URLQueryItem(name: "query", value: name),
                             URLQueryItem(name: "languages", value: Array(Set(wanted)).sorted().joined(separator: ","))]
        if let year { search.queryItems?.append(URLQueryItem(name: "year", value: year)) }
        json(openSubtitles(search.url!)) { [weak self] found in
            guard let self else { return }
            let data = ((found as? [String: Any])?["data"] as? [[String: Any]]) ?? []
            func fileID(_ item: [String: Any]) -> (id: Int, language: String)? {
                guard let attributes = item["attributes"] as? [String: Any],
                      let file = (attributes["files"] as? [[String: Any]])?.first,
                      let id = (file["file_id"] as? NSNumber)?.intValue else { return nil }
                return (id, attributes["language"] as? String ?? "")
            }
            let files = data.compactMap(fileID)
            guard let best = wanted.lazy.compactMap({ code in files.first { $0.language == code } }).first
                    ?? files.first else { otherwise(); return }
            var download = self.openSubtitles(URL(string: "https://api.opensubtitles.com/api/v1/download")!)
            download.httpMethod = "POST"
            download.setValue("application/json", forHTTPHeaderField: "Content-Type")
            download.httpBody = try? JSONSerialization.data(withJSONObject: ["file_id": best.id, "sub_format": "srt"])
            self.json(download) { link in
                guard let address = (link as? [String: Any])?["link"] as? String, let url = URL(string: address) else {
                    otherwise(); return
                }
                self.text(URLRequest(url: url)) { srt in
                    guard key == self.trackKey else { return }
                    let lines = srt.map(Self.parseSRT) ?? []
                    lines.isEmpty ? otherwise()
                                  : self.use(lines, unsynced: false, key: key, already: best.language)
                }
            }
        }
    }

    private func openSubtitles(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(apiKey, forHTTPHeaderField: "Api-Key")
        request.setValue("NowPlayingMenu v1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// "Inception (2010) — watch online | Site" → ("Inception", "2010").
    private static func filmName(_ title: String) -> (String, String?) {
        var name = title
        for separator in [" | ", " — ", " – ", " - "] {
            if let range = name.range(of: separator) { name = String(name[..<range.lowerBound]) }
        }
        var year: String?
        if let match = name.range(of: #"\b(19|20)\d{2}\b"#, options: .regularExpression) {
            year = String(name[match])
        }
        name = name.replacingOccurrences(of: #"[\(\[].*?[\)\]]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)(смотреть|онлайн|фильм|сериал|watch|online|full movie|hd|1080p|720p)"#,
                                  with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\b(19|20)\d{2}\b"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return (name, year)
    }

    // MARK: Using them

    /// Shows the lines, then translates them in the background unless they
    /// are in the chosen language already.
    private func use(_ found: [Line], unsynced: Bool, key: String, already: String? = nil) {
        guard isOn, key == trackKey else { return }
        lines = found
        self.unsynced = unsynced
        show("", "")
        let target = language
        guard !target.isEmpty, already != target else { return }
        translate(found.map(\.text), to: target) { [weak self] translated in
            guard let self, key == self.trackKey, translated.count == self.lines.count else { return }
            for index in self.lines.indices { self.lines[index].translation = translated[index] }
        }
    }

    /// Google's free web endpoint, in chunks; lines are kept apart by
    /// newlines, which it leaves in place.
    private func translate(_ texts: [String], to target: String, done: @escaping @MainActor ([String]) -> Void) {
        var chunks: [[String]] = [[]]
        var size = 0
        for text in texts {
            let flat = text.replacingOccurrences(of: "\n", with: " ")
            if size + flat.count > 3500, !chunks[chunks.count - 1].isEmpty { chunks.append([]); size = 0 }
            chunks[chunks.count - 1].append(flat)
            size += flat.count + 1
        }
        var results = [[String]?](repeating: nil, count: chunks.count)
        var left = chunks.count
        for (number, chunk) in chunks.enumerated() {
            var request = URLRequest(url: URL(string: "https://translate.googleapis.com/translate_a/single")!,
                                     timeoutInterval: 20)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded;charset=UTF-8", forHTTPHeaderField: "Content-Type")
            var form = URLComponents()
            form.queryItems = [URLQueryItem(name: "client", value: "gtx"), URLQueryItem(name: "sl", value: "auto"),
                               URLQueryItem(name: "tl", value: target), URLQueryItem(name: "dt", value: "t"),
                               URLQueryItem(name: "q", value: chunk.joined(separator: "\n"))]
            request.httpBody = form.percentEncodedQuery?
                .replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
            json(request) { found in
                let parts = ((found as? [Any])?.first as? [Any]) ?? []
                let joined = parts.compactMap { ($0 as? [Any])?.first as? String }.joined()
                let split = joined.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                results[number] = split.count == chunk.count ? split : chunk
                left -= 1
                if left == 0 { done(results.flatMap { $0 ?? [] }) }
            }
        }
    }

    // MARK: Network

    private func json(_ request: URLRequest, _ done: @escaping @MainActor (Any?) -> Void) {
        data(request) { done($0.flatMap { try? JSONSerialization.jsonObject(with: $0) }) }
    }

    private func text(_ request: URLRequest, _ done: @escaping @MainActor (String?) -> Void) {
        data(request) { data in
            done(data.flatMap { String(data: $0, encoding: .utf8) ?? String(data: $0, encoding: .windowsCP1251) })
        }
    }

    private func data(_ request: URLRequest, _ done: @escaping @MainActor (Data?) -> Void) {
        var request = request
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue("NowPlayingMenu v1.0", forHTTPHeaderField: "User-Agent")
        }
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            let ok = ((response as? HTTPURLResponse)?.statusCode ?? 0) < 400
            DispatchQueue.main.async { MainActor.assumeIsolated { done(ok ? data : nil) } }
        }
        tasks.append(task)
        task.resume()
    }

    // MARK: Formats

    /// "[01:23.45] words" lines into times and words.
    private static func parseLRC(_ lrc: String) -> [Line] {
        let pattern = try! NSRegularExpression(pattern: #"\[(\d+):(\d+(?:\.\d+)?)\]"#)
        var lines: [Line] = []
        for raw in lrc.split(separator: "\n") {
            let text = String(raw)
            let matches = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
            guard let last = matches.last, let end = Range(last.range, in: text) else { continue }
            let words = text[end.upperBound...].trimmingCharacters(in: .whitespaces)
            for match in matches {
                guard let m = Range(match.range(at: 1), in: text), let s = Range(match.range(at: 2), in: text),
                      let minutes = Double(text[m]), let seconds = Double(text[s]) else { continue }
                lines.append(Line(start: minutes * 60 + seconds, text: words.isEmpty ? "♪" : words))
            }
        }
        return lines.sorted { $0.start < $1.start }
    }

    /// SRT blocks — number, "00:01:02,500 --> 00:01:04,000", text — into lines.
    private static func parseSRT(_ srt: String) -> [Line] {
        let time = #"(\d+):(\d+):(\d+)[,.](\d+)"#
        let arrow = try! NSRegularExpression(pattern: time + #"\s*-->\s*"# + time)
        var lines: [Line] = []
        let blocks = srt.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        for block in blocks {
            let rows = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let at = rows.firstIndex(where: { $0.contains("-->") }) else { continue }
            let row = rows[at]
            guard let match = arrow.firstMatch(in: row, range: NSRange(row.startIndex..., in: row)) else { continue }
            func seconds(_ first: Int) -> Double {
                let parts = (first..<first + 4).map { Double(row[Range(match.range(at: $0), in: row)!]) ?? 0 }
                return parts[0] * 3600 + parts[1] * 60 + parts[2] + parts[3] / 1000
            }
            let words = rows[(at + 1)...].joined(separator: "\n")
                .replacingOccurrences(of: #"<[^>]+>|\{[^}]+\}"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !words.isEmpty else { continue }
            lines.append(Line(start: seconds(1), end: seconds(5), text: words))
        }
        return lines.sorted { $0.start < $1.start }
    }

    // MARK: The window

    private func showWindow() {
        guard window == nil, let screen = NSScreen.main else { return }
        let area = screen.frame
        let size = NSSize(width: area.width * 0.8, height: 170)
        let frame = NSRect(x: area.midX - size.width / 2, y: area.minY + 60, width: size.width, height: size.height)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: LyricsSubtitles(lyrics: self))
        panel.orderFrontRegardless()
        window = panel
    }
}

/// Two lines, see-through: the main one, and under it, fainter, the
/// original or the next line.
private struct LyricsSubtitles: View {
    @ObservedObject var lyrics: LyricsController

    var body: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 0)
            Text(lyrics.current)
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(.white.opacity(0.92))
            Text(lyrics.second)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
        }
        .multilineTextAlignment(.center)
        .lineLimit(3)
        .shadow(color: .black.opacity(0.8), radius: 3, y: 1)
        .shadow(color: .black.opacity(0.4), radius: 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.horizontal, 20)
        .animation(.easeInOut(duration: 0.2), value: lyrics.current)
    }
}
