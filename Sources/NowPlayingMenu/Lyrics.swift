import AppKit
import SwiftUI

/// The words of the track that is playing, found on LRCLIB and shown over
/// everything at the bottom of the screen, line by line, like subtitles.
/// Turned on and off from the card.
@MainActor
final class LyricsController: ObservableObject {
    static let shared = LyricsController()

    @Published private(set) var isOn = false
    /// The line being sung, and the one after it.
    @Published private(set) var current = ""
    @Published private(set) var next = ""

    private struct Line { let time: Double; let text: String }

    private weak var model: NowPlayingModel?
    private var window: NSPanel?
    private var timer: Timer?
    /// "title|artist" of the track the lines are for.
    private var trackKey = ""
    private var lines: [Line] = []
    /// Lines with no times: spread evenly over the track.
    private var unsynced = false
    private var task: URLSessionDataTask?

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
        task?.cancel(); task = nil
        window?.orderOut(nil); window = nil
        lines = []; trackKey = ""; current = ""; next = ""
    }

    /// The player the words are for: the one playing, else the one that
    /// played last, else the first.
    private var player: NowPlayingModel.Player? {
        guard let model else { return nil }
        let all = model.players.filter(\.hasTrack)
        return all.first(where: \.isPlaying)
            ?? all.first { $0.id == model.lastPlayedID }
            ?? all.first
    }

    private func tick() {
        guard let player else { current = "Nothing is playing"; next = ""; return }
        let key = player.title + "|" + player.artist
        if key != trackKey {
            trackKey = key
            lines = []
            current = "Searching lyrics…"; next = player.title
            fetch(title: player.title, artist: player.artist, duration: player.progress?.duration)
            return
        }
        guard !lines.isEmpty, let progress = player.progress else { return }
        let time = progress.elapsed(at: Date())
        let index: Int
        if unsynced {
            index = min(Int(time / max(progress.duration, 1) * Double(lines.count)), lines.count - 1)
        } else {
            index = (lines.lastIndex { $0.time <= time + 0.2 }) ?? -1
        }
        let now = index >= 0 ? lines[index].text : ""
        let after = index + 1 < lines.count ? lines[index + 1].text : ""
        if now != current { current = now }
        if after != next { next = after }
    }

    // MARK: Finding the words

    private func fetch(title: String, artist: String, duration: Double?) {
        task?.cancel()
        let key = trackKey
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
        if let duration, duration > 0 {
            get.queryItems?.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded()))))
        }
        var search = URLComponents(string: "https://lrclib.net/api/search")!
        search.queryItems = [URLQueryItem(name: "q", value: artist.contains(".") ? title : "\(artist) \(title)")]

        request(get.url!) { [weak self] json in
            if let found = json as? [String: Any], Self.hasWords(found) {
                self?.use(found, for: key)
            } else {
                self?.request(search.url!) { json in
                    let results = (json as? [[String: Any]]) ?? []
                    let best = results.first { ($0["syncedLyrics"] as? String)?.isEmpty == false }
                        ?? results.first(where: Self.hasWords)
                    self?.use(best, for: key)
                }
            }
        }
    }

    private static func hasWords(_ entry: [String: Any]) -> Bool {
        (entry["syncedLyrics"] as? String)?.isEmpty == false || (entry["plainLyrics"] as? String)?.isEmpty == false
    }

    private func request(_ url: URL, _ done: @escaping @MainActor (Any?) -> Void) {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("NowPlayingMenu (https://github.com)", forHTTPHeaderField: "User-Agent")
        let task = URLSession.shared.dataTask(with: request) { data, _, _ in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(json) } }
        }
        self.task = task
        task.resume()
    }

    private func use(_ entry: [String: Any]?, for key: String) {
        guard isOn, key == trackKey else { return }
        if let synced = entry?["syncedLyrics"] as? String, !synced.isEmpty {
            lines = Self.parse(synced)
            unsynced = false
        } else if let plain = entry?["plainLyrics"] as? String, !plain.isEmpty {
            lines = plain.split(separator: "\n").map { Line(time: 0, text: String($0)) }
            unsynced = true
        } else {
            lines = []
        }
        if lines.isEmpty { current = "No lyrics found"; next = "" }
    }

    /// "[01:23.45] words" lines into times and words.
    private static func parse(_ lrc: String) -> [Line] {
        let pattern = try! NSRegularExpression(pattern: #"\[(\d+):(\d+(?:\.\d+)?)\]"#)
        var lines: [Line] = []
        for raw in lrc.split(separator: "\n") {
            let text = String(raw)
            let range = NSRange(text.startIndex..., in: text)
            let matches = pattern.matches(in: text, range: range)
            guard let last = matches.last, let end = Range(last.range, in: text) else { continue }
            let words = text[end.upperBound...].trimmingCharacters(in: .whitespaces)
            for match in matches {
                guard let m = Range(match.range(at: 1), in: text), let s = Range(match.range(at: 2), in: text),
                      let minutes = Double(text[m]), let seconds = Double(text[s]) else { continue }
                lines.append(Line(time: minutes * 60 + seconds, text: words.isEmpty ? "♪" : words))
            }
        }
        return lines.sorted { $0.time < $1.time }
    }

    // MARK: The window

    private func showWindow() {
        guard window == nil, let screen = NSScreen.main else { return }
        let area = screen.frame
        let size = NSSize(width: area.width * 0.8, height: 150)
        let frame = NSRect(x: area.midX - size.width / 2, y: area.minY + 70, width: size.width, height: size.height)
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

/// Two lines, see-through: the one being sung, and the next, fainter.
private struct LyricsSubtitles: View {
    @ObservedObject var lyrics: LyricsController

    var body: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 0)
            Text(lyrics.current)
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(.white.opacity(0.92))
            Text(lyrics.next)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
        }
        .multilineTextAlignment(.center)
        .lineLimit(2)
        .shadow(color: .black.opacity(0.8), radius: 3, y: 1)
        .shadow(color: .black.opacity(0.4), radius: 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.horizontal, 20)
        .animation(.easeInOut(duration: 0.25), value: lyrics.current)
    }
}
