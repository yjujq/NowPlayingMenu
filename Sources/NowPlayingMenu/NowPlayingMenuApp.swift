import SwiftUI
import AppKit
import Combine
import MediaRemoteBridge
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = DisplaySettings()
    private lazy var player = NowPlayingModel(settings: settings)
    private var marquee: MarqueeStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        marquee = MarqueeStatusItem(player: player, settings: settings)
    }
}

/// Runs `body` on the main thread in every run loop mode, now or after
/// `delay`. `DispatchQueue.main` is not served while a menu is tracking, so
/// anything sent that way waits for the menu to close — the card showed the
/// track as it was when it opened, and kept its old height when folded.
func onMain(after delay: TimeInterval = 0, _ body: @escaping @MainActor () -> Void) {
    let run = { MainActor.assumeIsolated { body() } }
    let main = CFRunLoopGetMain()
    if delay > 0 {
        let timer = Timer(timeInterval: delay, repeats: false) { _ in run() }
        CFRunLoopAddTimer(main, timer, .commonModes)
    } else {
        CFRunLoopPerformBlock(main, CFRunLoopMode.commonModes.rawValue, run)
        CFRunLoopWakeUp(main)
    }
}

@main
enum NowPlayingMenuMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }
}

@MainActor
final class NowPlayingModel: ObservableObject {
    private let settings: DisplaySettings
    @Published private(set) var title = "Nothing playing"
    @Published private(set) var artist = ""
    @Published private(set) var album = ""
    @Published private(set) var artwork: NSImage?
    @Published private(set) var isPlaying = false
    /// Whether there is a track at all. Differs from isPlaying: while paused
    /// a track exists but nothing plays — and the title must stay on screen.
    @Published private(set) var hasTrack = false
    /// Where the track stands, when the source says how long it is. Nil when
    /// it does not: a good many of them publish a position and no duration,
    /// and a fraction of an unknown whole is not something that can be drawn.
    @Published private(set) var progress: Progress?
    /// The bundle identifier of the app that is playing, for bringing it
    /// forward. A browser rather than WebKit when the sound is from the web.
    @Published private(set) var source: String?
    /// Every player with something loaded, as the helper lists them — the
    /// system's pick among them. Looked for only while the card is open.
    @Published private(set) var listed: [Player] = []
    /// Their pictures, by `Player.artworkKey`.
    @Published private(set) var otherArtwork: [String: NSImage] = [:]
    /// The player the card shows opened out, the rest folded.
    @Published private(set) var openID: String?

    /// One player, as the card shows it: the system's own pick — the one the
    /// fields above describe — or one of the others.
    struct Player: Identifiable, Equatable {
        static let systemID = "system"

        /// Names the player to the helper when it is sent a command.
        let id: String
        /// The app's bundle identifier.
        let source: String?
        let name: String
        /// Empty when nothing is loaded.
        let title: String
        let artist: String
        let album: String
        var isPlaying: Bool
        let progress: Progress?
        /// Where its picture is kept, in `otherArtwork`; the system's pick
        /// has its picture in `artwork`.
        let artworkKey: String?
        /// What it says it can do. Nil until the card has asked, and then
        /// taken to be a music player's: play and pause, change track, seek.
        var abilities: Abilities? = nil

        /// The system's pick — the player the fields of the model describe.
        var isSystem = false
        var hasTrack: Bool { !title.isEmpty }

        /// Skips by a few seconds rather than changing track — a video in a
        /// browser does — so its buttons are −15 and +15, as in Control Center.
        var skips: Bool { abilities.map { $0.has(17) && !$0.has(4) } ?? false }
        var skipInterval: Double { abilities?.skipInterval ?? 15 }
        var canGoBack: Bool { abilities.map { $0.has(skips ? 18 : 5) } ?? true }
        var canGoForward: Bool { abilities.map { $0.has(skips ? 17 : 4) } ?? true }
        var canPlayPause: Bool { abilities.map { $0.has(0) || $0.has(1) || $0.has(2) } ?? true }
        var canScrub: Bool { abilities.map { $0.has(24) && $0.scrubbable } ?? true }
    }

    /// The commands a player takes, as it lists them for the system — the
    /// list Control Center reads to choose its buttons — with the interval
    /// it skips by, whether its bar may be dragged, and its colour.
    struct Abilities: Equatable {
        let commands: Set<Int>
        let skipInterval: Double?
        let scrubbable: Bool
        let tint: NSColor?

        func has(_ command: Int) -> Bool { commands.contains(command) }

        init?(_ entry: [String: Any]) {
            guard let commands = entry["commands"] as? [NSNumber] else { return nil }
            self.commands = Set(commands.map(\.intValue))
            skipInterval = (entry["skipInterval"] as? NSNumber)?.doubleValue
            scrubbable = (entry["scrubbable"] as? Bool) ?? true
            tint = (entry["tint"] as? [NSNumber]).flatMap { rgb in
                rgb.count == 3 ? NSColor(srgbRed: CGFloat(rgb[0].doubleValue), green: CGFloat(rgb[1].doubleValue),
                                         blue: CGFloat(rgb[2].doubleValue), alpha: 1) : nil
            }
        }
    }

    /// The player the system sends commands to. Not always the one it
    /// reports as now playing: that one can be Safari, playing, while
    /// commands go to Chrome, paused. Nil until the helper has said.
    @Published private(set) var commandTargetID: String?

    /// The one player the buttons can reach.
    var controllableID: String { commandTargetID ?? systemPlayer.id }

    /// The system's pick as the helper lists it, matched by app and title.
    /// Worked out afresh each time, so that when the pick changes the list
    /// follows at once instead of showing one player in two places.
    private var systemEntry: Player? {
        guard hasTrack else { return nil }
        if let exact = listed.first(where: { $0.source == source && $0.title == title }) { return exact }
        // Between polls the title may have moved on in one list and not the
        // other; the app's only player is then the one.
        let sameApp = listed.filter { $0.source == source }
        return sameApp.count == 1 ? sameApp[0] : nil
    }

    /// The others, the system's pick taken out.
    var others: [Player] {
        let pick = systemEntry?.id
        return listed.filter { $0.id != pick }
    }

    /// From the model's own fields, under the helper's name for it once it
    /// has listed it — until then `Player.systemID`.
    private var systemPlayer: Player {
        let entry = systemEntry
        return Player(id: entry?.id ?? Player.systemID, source: source, name: sourceName ?? "",
                      title: hasTrack ? title : "", artist: artist, album: album,
                      isPlaying: isPlaying, progress: progress, artworkKey: nil,
                      abilities: entry?.abilities, isSystem: true)
    }

    /// The order players were first seen in. Each keeps its place: starting
    /// one, which makes it the system's pick, does not move it to the top.
    @Published private(set) var order: [String] = []

    /// Everything that is playing or paused, each in its place. The system's
    /// pick is left out only when it has nothing and another player has
    /// something.
    var players: [Player] {
        let all = (hasTrack || others.isEmpty ? [systemPlayer] : []) + others
        let place = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        // Not placed yet: the system's pick ahead of all, others at the end.
        func rank(_ item: (offset: Int, element: Player)) -> Int {
            place[item.element.id] ?? (item.element.isSystem ? -1 : order.count + item.offset)
        }
        return all.enumerated().sorted { rank($0) < rank($1) }.map(\.element)
    }

    /// When each player was last seen playing.
    private var lastPlayed: [String: Date] = [:]

    /// The player that played last: one playing now, the system's pick if it
    /// is, else whichever was seen playing most recently.
    var lastPlayedID: String? {
        let seen = players.compactMap { player in lastPlayed[player.id].map { (player, $0) } }
        guard let latest = seen.map(\.1).max() else { return nil }
        let candidates = seen.filter { $0.1 == latest }.map(\.0)
        return (candidates.first { $0.isSystem } ?? candidates.first)?.id
    }

    private func notePlaying() {
        let now = Date()
        for player in players where player.isPlaying { lastPlayed[player.id] = now }
    }

    /// Set when the card opens, until the system's pick has been put first.
    private var putPickFirst = false

    /// The system's pick — Now Playing — to the top, once, as the card
    /// opens; after that each keeps its place while the card is open.
    private func placePickFirst() {
        guard putPickFirst, let id = systemEntry?.id else { return }
        order.removeAll { $0 == id }
        order.insert(id, at: 0)
        putPickFirst = false
    }

    /// Whether one of the players is opened out.
    var hasOpen: Bool { players.contains { $0.id == openID } }

    /// Opens a player out and folds the one that was; or folds it, if it was
    /// the one.
    func toggleOpen(_ player: Player) {
        openID = openID == player.id ? nil : player.id
    }

    /// Done each time the card opens. If a player was opened out when it
    /// was last closed, the one opened out now is the one that played last.
    /// If all were folded, they stay folded.
    func openActive() {
        guard openID != nil else { return }
        if let id = lastPlayedID ?? players.first?.id { openID = id }
    }

    func artwork(for player: Player) -> NSImage? {
        player.isSystem ? artwork : player.artworkKey.flatMap { otherArtwork[$0] }
    }

    /// A reading of the position, not the position itself.
    ///
    /// The system does not count the seconds out; it writes down where the
    /// track was at `taken` and leaves it there until playback changes. So a
    /// reading stays the same across polls — which is what makes it worth
    /// comparing — and the current position is carried forward from it.
    struct Progress: Equatable {
        /// Seconds into the track, as of `taken`.
        let reading: Double
        let taken: Date
        let duration: Double
        /// 1 while playing, 0 while paused. The reading stands still at 0.
        let rate: Double

        func elapsed(at moment: Date) -> Double {
            let carried = reading + moment.timeIntervalSince(taken) * rate
            return min(max(carried, 0), duration)
        }

        func fraction(at moment: Date) -> Double {
            duration > 0 ? elapsed(at: moment) / duration : 0
        }

        func remaining(at moment: Date) -> Double {
            max(duration - elapsed(at: moment), 0)
        }
    }

    var displayText: String {
        guard hasTrack else { return "Nothing playing" }
        var parts: [String] = []
        if settings.showsArtist && !artist.isEmpty { parts.append(artist) }
        parts.append(title)
        if settings.showsAlbum && !album.isEmpty { parts.append(album) }
        return parts.joined(separator: settings.separator)
    }

    private var pollTimer: Timer?
    /// The track the artwork belongs to, and the name the source gave the
    /// picture. The name changes on its own when a source publishes the
    /// picture a moment after the title, which Spotify does.
    private var artworkTrack = ""
    private var artworkIdentifier: String?

    init(settings: DisplaySettings) {
        self.settings = settings
        refresh()
        schedulePolling()
    }

    /// Every poll spawns a separate osascript process, which is not cheap.
    /// While nothing is playing there is no point asking often.
    private func schedulePolling() {
        let interval: TimeInterval = isPlaying ? 5 : 15
        guard pollTimer == nil || pollTimer?.timeInterval != interval else { return }
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let info = SystemNowPlaying.fetch()
            onMain { self?.apply(info) }
        }
    }

    private func apply(_ info: [String: Any]) {
        let newTitle = info["title"] as? String ?? ""
        let playbackRate = (info["playbackRate"] as? NSNumber)?.doubleValue ?? 0

        isPlaying = !newTitle.isEmpty && playbackRate > 0
        hasTrack = !newTitle.isEmpty
        title = newTitle.isEmpty ? "Nothing playing" : newTitle
        artist = info["artist"] as? String ?? ""
        album = info["album"] as? String ?? ""
        source = hasTrack ? info["source"] as? String : nil
        progress = Self.progress(from: info, playbackRate: playbackRate, hasTrack: hasTrack)
        notePlaying()
        updateArtwork(identifier: info["artworkIdentifier"] as? String)
        schedulePolling()
    }

    /// Fetched only when the track or its picture changes: it takes a process
    /// of its own and comes to a megabyte, so it is not asked for every poll.
    private func updateArtwork(identifier: String?) {
        let track = hasTrack ? [title, artist, album].joined(separator: "\u{1F}") : ""
        guard track != artworkTrack || identifier != artworkIdentifier else { return }
        // A new track drops the old picture at once rather than leaving it
        // beside the wrong title while the new one loads.
        if track != artworkTrack { artwork = nil }
        artworkTrack = track
        artworkIdentifier = identifier
        guard hasTrack else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let data = SystemArtwork.fetch()
            onMain { [weak self] in
                guard let self, self.artworkTrack == track else { return }
                // A source can stop publishing the picture partway through a
                // track — Safari does, for some videos — and the one it gave
                // stays. A new track has already let go of the old one.
                if let image = data.flatMap(NSImage.init(data:)) { self.artwork = image }
            }
        }
    }

    // MARK: Other players

    private var watchTimer: Timer?

    /// While the card is open the main track and the other players are asked
    /// after every two seconds: someone is looking at them.
    func startWatching() {
        putPickFirst = true
        placePickFirst()
        refresh()
        refreshOthers()
        watchTimer?.invalidate()
        watchTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
                self?.refreshOthers()
            }
        }
    }

    func stopWatching() {
        watchTimer?.invalidate()
        watchTimer = nil
    }

    func refreshOthers() {
        // Pictures already in hand are not sent again.
        let known = otherArtwork.keys.joined(separator: "\n")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let data = SystemHelper.call("NPMWritePlayers", environment: ["NPM_KNOWN_ARTWORK": known])
            let entries = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [[String: Any]] ?? []
            onMain { self?.applyOthers(entries) }
        }
    }

    private func applyOthers(_ entries: [[String: Any]]) {
        var pictures = otherArtwork
        var players: [Player] = []
        var targetID: String?
        for entry in entries {
            guard let id = entry["id"] as? String, let title = entry["title"] as? String,
                  let key = entry["artworkKey"] as? String else { continue }
            let rate = (entry["playbackRate"] as? NSNumber)?.doubleValue ?? 0
            players.append(Player(
                id: id,
                source: entry["source"] as? String,
                name: entry["name"] as? String ?? "",
                title: title,
                artist: entry["artist"] as? String ?? "",
                album: entry["album"] as? String ?? "",
                isPlaying: rate > 0,
                progress: Self.progress(from: entry, playbackRate: rate, hasTrack: true),
                artworkKey: key,
                abilities: Abilities(entry)
            ))
            if entry["target"] as? Bool ?? false { targetID = id }
            if let encoded = entry["artwork"] as? String, let data = Data(base64Encoded: encoded),
               let image = NSImage(data: data) {
                pictures[key] = image
            }
        }
        let keys = Set(players.compactMap(\.artworkKey))
        pictures = pictures.filter { keys.contains($0.key) }
        if pictures.keys != otherArtwork.keys { otherArtwork = pictures }
        if players != listed { listed = players }
        // The opened one stays opened once it has its real name.
        if openID == Player.systemID, let entry = systemEntry { openID = entry.id }
        if targetID != commandTargetID { commandTargetID = targetID }
        updateOrder(with: players.map(\.id))
        placePickFirst()
        notePlaying()
    }

    /// Players new to the list go at the end; ones gone are forgotten.
    private func updateOrder(with present: [String]) {
        var updated = order.filter(present.contains)
        for id in present where !updated.contains(id) { updated.append(id) }
        if updated != order { order = updated }
    }

    // The system's pick is sent its commands the way it always was; the
    // others through the helper, by name.

    /// The player the system sends commands to is told directly. Any other
    /// cannot be reached that way, so its button is pressed in Control
    /// Center, which can.
    func togglePlayPause(_ player: Player) {
        guard player.id != controllableID else { return togglePlayPause() }
        // Shown at once; the next poll says whether it took.
        if let index = listed.firstIndex(where: { $0.id == player.id }) { listed[index].isPlaying.toggle() }
        ControlCenterRemote.press(.playPause, on: player.title) { [weak self] _ in
            self?.refresh()
            self?.refreshOthers()
        }
    }

    /// Next track, or a skip forward for a player that skips.
    func goForward(_ player: Player) {
        guard player.id == controllableID else {
            return ControlCenterRemote.press(.forward, on: player.title) { [weak self] _ in
                self?.refresh()
                self?.refreshOthers()
            }
        }
        if player.skips {
            _ = MRBSkip(true, player.skipInterval)
            refreshSoon()
        } else {
            nextTrack()
        }
    }

    /// Previous track, or a skip back for a player that skips.
    func goBack(_ player: Player) {
        guard player.id == controllableID else { return send(player.skips ? 18 : 5, to: player) }
        if player.skips {
            _ = MRBSkip(false, player.skipInterval)
            refreshSoon()
        } else {
            previousTrack()
        }
    }

    func seek(_ player: Player, to seconds: Double) {
        player.id == controllableID ? seek(to: seconds) : send(24, to: player, position: max(seconds, 0))
    }

    private func send(_ command: Int, to player: Player, position: Double? = nil) {
        var environment = ["NPM_PLAYER": player.id, "NPM_COMMAND": String(command)]
        if let position { environment["NPM_POSITION"] = String(position) }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = SystemHelper.call("NPMSendPlayerCommand", environment: environment)
            onMain {
                self?.refresh()
                self?.refreshOthers()
            }
        }
    }

    // MARK: Commands
    //
    // All of them go through the system, as Control Center's do. The system
    // hands a command from an app like this one to the player it has
    // elected; a player that publishes what it plays but takes no commands
    // (VLC 3 is one) does not answer them here, nor in Control Center.

    /// Plays or pauses the player the system sends commands to. The helper
    /// asks the system whether that one is playing and sends Pause or Play
    /// outright, as Control Center does: some players — Safari among them —
    /// take no Toggle, and the player this app shows first is not always the
    /// one the command reaches, so its own state would be the wrong guide.
    func togglePlayPause() {
        guard SystemHelper.available else { return toggleDirectly() }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = SystemHelper.call("NPMTogglePlayPause")
            onMain {
                guard let self else { return }
                self.refreshSoon()
                if self.watchTimer != nil { onMain(after: 0.4) { self.refreshOthers() } }
            }
        }
    }

    /// Without the helper: the system's Toggle, or the media key.
    private func toggleDirectly() {
        if !MRBTogglePlayPause() {
            // Fallback for systems that don't expose the direct command symbol.
            postMediaKey(16)
        }
        refreshSoon()
    }

    func nextTrack() {
        if !MRBSendCommand(.nextTrack) { postMediaKey(17) }
        refreshSoon()
    }

    func previousTrack() {
        if !MRBSendCommand(.previousTrack) { postMediaKey(18) }
        refreshSoon()
    }

    static func icon(of source: String) -> NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: source)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    /// Brings a playing app forward — the way clicking the artwork in
    /// Control Center does.
    static func open(_ source: String) {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: source).first {
            running.activate(options: [.activateAllWindows])
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: source) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    var sourceName: String? {
        guard let source else { return nil }
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: source).first,
           let name = running.localizedName { return name }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: source)?
            .deletingPathExtension().lastPathComponent
    }

    func seek(to seconds: Double) {
        guard MRBSetElapsedTime(max(seconds, 0)) else { return }
        refreshSoon()
    }

    private func refreshSoon() {
        onMain(after: 0.4) { [weak self] in self?.refresh() }
    }

    private func postMediaKey(_ key: Int) {
        for isKeyDown in [true, false] {
            let flags = (isKeyDown ? 0xA : 0xB) << 8
            let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags)),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: (key << 16) | flags,
                data2: -1
            )
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    /// Falls back to now for the timestamp, which every source seen so far
    /// does send. Without one the reading can only be taken as current, and
    /// it is then a new reading every poll — so the display re-syncs each
    /// time rather than running smoothly between polls.
    private static func progress(from info: [String: Any],
                                 playbackRate: Double, hasTrack: Bool) -> Progress? {
        let duration = (info["duration"] as? NSNumber)?.doubleValue ?? 0
        guard hasTrack, duration > 0 else { return nil }
        let taken = (info["timestamp"] as? NSNumber).map {
            Date(timeIntervalSince1970: $0.doubleValue)
        }
        return Progress(reading: (info["elapsedTime"] as? NSNumber)?.doubleValue ?? 0,
                        taken: taken ?? Date(),
                        duration: duration,
                        rate: playbackRate)
    }
}

@MainActor
final class DisplaySettings: ObservableObject {
    @Published var displayMode: Int { didSet { save("displayMode", displayMode) } }
    @Published var width: Double { didSet { save("width", width) } }
    @Published var fontName: String { didSet { save("fontName", fontName) } }
    @Published var fontSize: Double { didSet { save("fontSize", fontSize) } }
    @Published var showsArtist: Bool { didSet { save("showsArtist", showsArtist) } }
    @Published var showsAlbum: Bool { didSet { save("showsAlbum", showsAlbum) } }
    @Published var showsProgress: Bool { didSet { save("showsProgress", showsProgress) } }
    @Published var alignment: Int { didSet { save("alignment", alignment) } }
    @Published var scrollDirection: Int { didSet { save("scrollDirection", scrollDirection) } }
    @Published var scrollSpeed: Double { didSet { save("scrollSpeed", scrollSpeed) } }
    @Published var pageInterval: Double { didSet { save("pageInterval", pageInterval) } }
    /// Which click does what on the status item. Off: a click plays or
    /// pauses and a secondary (two-finger) click opens the card. On: the
    /// other way round.
    @Published var clickOpensCard: Bool { didSet { save("clickOpensCard", clickOpensCard) } }

    let separator = " — "
    private let defaults = UserDefaults.standard

    init() {
        displayMode = defaults.object(forKey: "displayMode") as? Int ?? 0
        width = defaults.object(forKey: "width") as? Double ?? 167
        fontName = defaults.string(forKey: "fontName") ?? "System"
        fontSize = defaults.object(forKey: "fontSize") as? Double ?? 13
        showsArtist = defaults.object(forKey: "showsArtist") as? Bool ?? true
        showsAlbum = defaults.object(forKey: "showsAlbum") as? Bool ?? false
        showsProgress = defaults.object(forKey: "showsProgress") as? Bool ?? true
        alignment = defaults.object(forKey: "alignment") as? Int ?? 0
        scrollDirection = defaults.object(forKey: "scrollDirection") as? Int ?? 0
        scrollSpeed = defaults.object(forKey: "scrollSpeed") as? Double ?? 3
        pageInterval = defaults.object(forKey: "pageInterval") as? Double ?? 2
        clickOpensCard = defaults.object(forKey: "clickOpensCard") as? Bool ?? false
    }

    func reset() {
        displayMode = 0; width = 167; fontName = "System"; fontSize = 13
        showsArtist = true; showsAlbum = false; showsProgress = true; alignment = 0
        scrollDirection = 0; scrollSpeed = 3; pageInterval = 2
        clickOpensCard = false
    }

    /// The typefaces Settings offers, in its order. The first four are the
    /// system's own; the rest are fonts every Mac ships with.
    static let typefaces = [
        "System", "Condensed", "Monospaced", "Rounded", "Serif",
        "Helvetica Neue", "Avenir Next", "Futura", "Gill Sans", "Optima",
        "Georgia", "Baskerville", "Menlo", "American Typewriter"
    ]

    /// The installed font behind each typeface that is not the system's.
    private static let postScriptNames = [
        "Condensed": "HelveticaNeue-CondensedBold",
        "Helvetica Neue": "HelveticaNeue",
        "Avenir Next": "AvenirNext-Regular",
        "Futura": "Futura-Medium",
        "Gill Sans": "GillSans",
        "Optima": "Optima-Regular",
        "Georgia": "Georgia",
        "Baskerville": "Baskerville",
        "Menlo": "Menlo-Regular",
        "American Typewriter": "AmericanTypewriter"
    ]

    func font() -> NSFont {
        switch fontName {
        case "Monospaced": return NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        case "Rounded": return systemFont(design: .rounded)
        case "Serif": return systemFont(design: .serif)
        default:
            if let name = Self.postScriptNames[fontName], let font = NSFont(name: name, size: fontSize) {
                return font
            }
            return NSFont.menuBarFont(ofSize: fontSize)
        }
    }

    /// The system font in one of its other cuts: SF Rounded, or New York.
    private func systemFont(design: NSFontDescriptor.SystemDesign) -> NSFont {
        let base = NSFont.menuBarFont(ofSize: fontSize)
        guard let descriptor = base.fontDescriptor.withDesign(design) else { return base }
        return NSFont(descriptor: descriptor, size: fontSize) ?? base
    }

    private func save(_ key: String, _ value: Any) { defaults.set(value, forKey: key) }
}

private enum SystemNowPlaying {
    /// From the helper, which can tell a paused player from a playing one
    /// by its playback state; the script can read only the rate the player
    /// left in its info, and VLC leaves 1 there when paused. The script is
    /// kept for when the helper is not to be found.
    static func fetch() -> [String: Any] {
        if SystemHelper.available {
            let data = SystemHelper.call("NPMWriteNowPlaying")
            return data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
        }
        return fetchByScript()
    }

    private static func fetchByScript() -> [String: Any] {
        guard let scriptURL = Bundle.module.url(forResource: "now-playing", withExtension: "js") else { return [:] }

        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", scriptURL.path]
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
            // Read before waiting for exit: otherwise a full pipe buffer
            // stalls the child process and both of us get stuck.
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let errorData = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                report("script exited with code \(process.terminationStatus)", errorData)
                return [:]
            }
            guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                report("could not parse the script output", data)
                return [:]
            }
            return parsed
        } catch {
            report("script failed to start: \(error.localizedDescription)", nil)
            return [:]
        }
    }

    /// Report failures out loud. Silently returning an empty dictionary made
    /// a broken script indistinguishable from "nothing playing", so breakage
    /// went unnoticed.
    private static var lastReport = ""
    private static func report(_ message: String, _ detail: Data?) {
        let text = String(data: detail ?? Data(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let full = text.isEmpty ? message : "\(message): \(text)"
        guard full != lastReport else { return }   // do not repeat the same line every five seconds
        lastReport = full
        FileHandle.standardError.write(Data(("NowPlaying: " + full + "\n").utf8))
    }
}

/// Set while Control Center is being worked out of sight: any window it
/// makes then is moved off the screen the moment it exists.
private var controlCenterOffstage = false

private let moveNewWindowAway: AXObserverCallback = { _, element, _, _ in
    guard controlCenterOffstage else { return }
    var point = CGPoint(x: -10_000, y: -10_000)
    if let value = AXValueCreate(.cgPoint, &point) {
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
    }
}

/// Presses a player's button in Control Center's Now Playing.
///
/// The system sends commands from an app like this one only to the one
/// player it has chosen; Control Center, being Apple's, can reach each of
/// them. So for any other player this opens Control Center, opens its Now
/// Playing out to the list of players, presses the button in that player's
/// row, and closes it again — all through the accessibility interface, which
/// the user allows once in Privacy & Security.
///
/// Control Center is kept out of sight while it does: its window is moved
/// off the screen the moment the system announces it, before it has much
/// more than begun to draw, and everything is pressed there. (Hiding
/// Control Center first, as an app is with Command-H, would hide it better,
/// but then it opens no window at all.)
///
/// The layout it relies on, as macOS 27 draws it: the Control Center item is
/// in MenuBarAgent's windows; Control Center's window holds a group with a
/// play or pause button, whose "show details" action lists every player as
/// a group of a text — "title, artist" — and buttons named by their symbols.
@MainActor
enum ControlCenterRemote {
    enum Button {
        case playPause, forward

        func matches(_ identifier: String, _ description: String) -> Bool {
            switch self {
            case .playPause:
                return ["play.fill", "pause.fill"].contains(identifier) || ["play", "pause"].contains(description)
            case .forward:
                return identifier == "forward.fill" || identifier.contains("arrow.trianglehead.clockwise")
                    || description.hasPrefix("next") || description.hasPrefix("fast-forward")
            }
        }
    }

    private static var busy = false

    static func press(_ button: Button, on title: String, done: @escaping (Bool) -> Void) {
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard !busy, !title.isEmpty, AXIsProcessTrustedWithOptions(prompt),
              let controlCenter = app("com.apple.controlcenter"),
              let menuBar = app("com.apple.MenuBarAgent"),
              let item = children(menuBar, kAXWindowsAttribute).lazy
                .compactMap({ find($0, identifier: "com.apple.menuextra.controlcenter") }).first
        else { return done(false) }
        busy = true

        let wasOpen = !children(controlCenter, kAXWindowsAttribute).isEmpty
        if !wasOpen {
            watchForWindows(of: controlCenter)
            controlCenterOffstage = true
            AXUIElementPerformAction(item, kAXPressAction as CFString)
        }
        func finish(_ pressed: Bool) {
            // Closed again only if it was opened here; the next time the
            // user opens it, it is left where it belongs.
            onMain(after: 0.15) {
                if !wasOpen { AXUIElementPerformAction(item, kAXPressAction as CFString) }
                onMain(after: 0.3) {
                    if !wasOpen { controlCenterOffstage = false }
                    // The card gets the keyboard back from Control Center.
                    NSApp.windows.first { $0 is CardPanel && $0.isVisible }?.makeKey()
                    busy = false
                    onMain(after: 0.1) { done(pressed) }
                }
            }
        }

        // Each step waits for what it needs to appear, a little at a time;
        // the first watches closely, to catch the window before it is drawn.
        waitFor({ children(controlCenter, kAXWindowsAttribute).first }, every: 0.003, tries: 300) { window in
            guard let window else { return finish(false) }
            if !wasOpen { moveAway(window) }
            waitFor({ nowPlayingModule(in: controlCenter) }) { module in
            guard let module else { return finish(false) }
            if let details = actionNames(module).first(where: { $0.contains("show details") }) {
                AXUIElementPerformAction(module, details as CFString)
            }
            // Opening the list out may set the window back in place.
            if !wasOpen { moveAway(window) }
            waitFor({ row(for: title, in: controlCenter) }) { row in
                guard let row,
                      let target = children(row).first(where: {
                          button.matches(string($0, kAXIdentifierAttribute), string($0, kAXDescriptionAttribute))
                      })
                else { return finish(false) }
                AXUIElementPerformAction(target, kAXPressAction as CFString)
                finish(true)
            }
            }
        }
    }

    private static var observer: AXObserver?
    private static var observedProcess: pid_t = 0

    /// Asks to be told the instant Control Center makes a window. Set up
    /// once, and again if Control Center has been restarted.
    private static func watchForWindows(of controlCenter: AXUIElement) {
        var pid: pid_t = 0
        AXUIElementGetPid(controlCenter, &pid)
        guard pid != observedProcess else { return }
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        var created: AXObserver?
        guard AXObserverCreate(pid, moveNewWindowAway, &created) == .success, let created else { return }
        AXObserverAddNotification(created, controlCenter, kAXWindowCreatedNotification as CFString, nil)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        observer = created
        observedProcess = pid
    }

    private static func moveAway(_ window: AXUIElement) {
        var point = CGPoint(x: -10_000, y: -10_000)
        guard let value = AXValueCreate(.cgPoint, &point) else { return }
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
    }

    // MARK: Finding things

    /// The group holding a play or pause button. Found by its button, not
    /// its picture: a player without one shows none.
    private static func nowPlayingModule(in controlCenter: AXUIElement) -> AXUIElement? {
        children(controlCenter, kAXWindowsAttribute).lazy.compactMap {
            group(in: $0, holdingIdentifier: ["play.fill", "pause.fill"])
        }.first
    }

    /// The row whose text begins with the title, once the list is out.
    private static func row(for title: String, in controlCenter: AXUIElement) -> AXUIElement? {
        let wanted = title.lowercased()
        for window in children(controlCenter, kAXWindowsAttribute) {
            for host in children(window) {
                for row in children(host) where actionNames(row).contains(where: { $0.contains("hide details") }) {
                    let text = children(row).first { string($0, kAXRoleAttribute) == kAXStaticTextRole }
                    if let text, string(text, kAXValueAttribute).lowercased().hasPrefix(wanted) { return row }
                }
            }
        }
        return nil
    }

    private static func waitFor(_ look: @escaping () -> AXUIElement?, every interval: TimeInterval = 0.05,
                                tries: Int = 30, then: @escaping (AXUIElement?) -> Void) {
        if let found = look() { return then(found) }
        guard tries > 0 else { return then(nil) }
        onMain(after: interval) { waitFor(look, every: interval, tries: tries - 1, then: then) }
    }

    private static func group(in node: AXUIElement, holdingIdentifier identifiers: Set<String>,
                              depth: Int = 0) -> AXUIElement? {
        guard depth < 6 else { return nil }
        for child in children(node) {
            if identifiers.contains(string(child, kAXIdentifierAttribute)) { return node }
            if let hit = group(in: child, holdingIdentifier: identifiers, depth: depth + 1) { return hit }
        }
        return nil
    }

    private static func find(_ node: AXUIElement, identifier: String, depth: Int = 0) -> AXUIElement? {
        guard depth < 6 else { return nil }
        if string(node, kAXIdentifierAttribute) == identifier { return node }
        for child in children(node) {
            if let hit = find(child, identifier: identifier, depth: depth + 1) { return hit }
        }
        return nil
    }

    private static func app(_ bundleID: String) -> AXUIElement? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
            .map { AXUIElementCreateApplication($0.processIdentifier) }
    }

    private static func children(_ node: AXUIElement, _ attribute: String = kAXChildrenAttribute) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, attribute as CFString, &value) == .success else { return [] }
        return (value as? [AXUIElement]) ?? []
    }

    private static func string(_ node: AXUIElement, _ attribute: String) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, attribute as CFString, &value) == .success else { return "" }
        return value as? String ?? ""
    }

    private static func actionNames(_ node: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(node, &names) == .success else { return [] }
        return names as? [String] ?? []
    }
}

/// Calls a function of the helper library and returns what it wrote. The
/// app may not ask mediaremoted for these things itself (see
/// ArtworkHelper.m), so the system's own perl asks instead, loading the
/// helper library and calling into it; arguments go in the environment.
private enum SystemHelper {
    static func call(_ function: String, environment: [String: String] = [:]) -> Data? {
        guard let library = helperURL() else { return nil }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", """
            use DynaLoader;
            my $h = DynaLoader::dl_load_file($ARGV[0]) or die DynaLoader::dl_error();
            my $f = DynaLoader::dl_find_symbol($h, $ARGV[1]) or die "no symbol";
            DynaLoader::dl_install_xsub("main::call", $f);
            call();
            """, library.path, function]
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 && !data.isEmpty ? data : nil
        } catch {
            return nil
        }
    }

    static var available: Bool { helperURL() != nil }

    /// In the app it is in Contents/Frameworks; under `swift run` it is
    /// beside the executable.
    private static func helperURL() -> URL? {
        let name = "libArtworkHelper.dylib"
        let places = [
            Bundle.main.privateFrameworksURL?.appendingPathComponent(name),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(name)
        ]
        return places.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

/// The artwork of the current item.
private enum SystemArtwork {
    static func fetch() -> Data? { SystemHelper.call("NPMWriteArtwork") }
}

@MainActor
private final class MarqueeStatusItem: NSObject {
    private let player: NowPlayingModel
    private let settings: DisplaySettings
    // A fixed width prevents the menu bar from shifting as track metadata changes.
    private let statusItem = NSStatusBar.system.statusItem(withLength: 167)

    /// The clear space between the end of the line and the copy of it that
    /// follows, so a loop does not read as one run-on sentence.
    private static let loopGap: CGFloat = 28
    private static let motionKey = "marquee"

    /// The progress rule along the bottom of the item: as long a part of the
    /// item's width as the track has been played.
    ///
    /// A point tall and a point and a half up from the bottom. Both numbers
    /// are what a menu bar of 22 points leaves: the line is drawn centred in
    /// it and its descenders reach three points from the bottom, so a rule
    /// any thicker or any higher is struck through by every g and y. Moving
    /// the line up to make room was tried and is worse — it lifts the title a
    /// visible step above the clock and everything else in the bar, and the
    /// step appears and disappears with the setting.
    private static let progressHeight: CGFloat = 1
    private static let progressInset: CGFloat = 1.5
    private static let progressKey = "progress"

    /// The line lives in a layer of its own inside the button, and moves by a
    /// Core Animation handed to the render server once.
    ///
    /// It was drawn by setting `button.image` on a timer instead, and that is
    /// not affordable at any frame rate worth having: every change to the
    /// content of a status item makes AppKit re-snapshot the whole item
    /// (`-[NSStatusItem _updateReplicants]` → `_cacheDisplayInRect:`), about
    /// three milliseconds a time. Thirty frames a second cost a quarter of a
    /// core; the same line as an animated layer costs nothing per frame,
    /// because the app is not woken for the frames at all.
    ///
    /// Neither layer carries a colour. Each is the mask of a view that fills
    /// itself with the menu bar's text colour, and AppKit repaints that view in
    /// the same pass as every other item on the bar — so when the bar turns
    /// light or dark, the line turns with the icons beside it instead of
    /// catching up on the next tick with a blink.
    private let lineLayer = CALayer()
    private let progressLayer = CALayer()
    private let lineFill = BarTextFill()
    private let progressFill = BarTextFill()

    /// The line, measured and rasterised: the text twice over, one loop apart,
    /// on a single transparent strip. Frames are windows onto this strip.
    private struct Line: Equatable {
        let text: String
        let font: NSFont
        /// Light or dark. A template image was tinted by the menu bar for
        /// free; a layer holds pixels, so the colour is baked in here and the
        /// strip is redrawn when the bar changes.
        let appearance: NSAppearance.Name
        let width: CGFloat
        let height: CGFloat
        /// The average glyph, used to keep the speed setting in characters
        /// per second now that the travel itself is measured in points.
        let characterWidth: CGFloat
        /// The distance from one copy of the line to the next.
        let loop: CGFloat
        let scale: CGFloat
        let strip: CGImage?

        // Rasterising is drawing, and drawing belongs on the main thread.
        @MainActor
        init(text: String, font: NSFont, gap: CGFloat, scale: CGFloat,
             color: NSColor, appearance: NSAppearance.Name) {
            self.text = text
            self.font = font
            self.scale = scale
            self.appearance = appearance
            let string = NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: color
            ])
            let size = string.size()
            width = ceil(size.width)
            let bar = NSStatusBar.system.thickness
            // A little short of the full bar: a line the height of the bar
            // would sit against its edges.
            height = min(max(bar - 4, ceil(size.height)), bar)
            characterWidth = width / CGFloat(max(text.count, 1))
            loop = width + gap
            // Locals, because a closure may not capture the properties of a
            // value that is still being initialised.
            let stripLoop = loop
            let stripHeight = height
            let y = (stripHeight - ceil(size.height)) / 2
            strip = MarqueeStatusItem.raster(
                NSSize(width: stripLoop + ceil(size.width), height: stripHeight), scale: scale
            ) {
                string.draw(at: NSPoint(x: 0, y: y))
                // The second copy is what makes the loop seamless: it is
                // already entering as the first one leaves.
                string.draw(at: NSPoint(x: stripLoop, y: y))
            }
        }
    }

    /// The line held still: aligned in the item, and shortened with an
    /// ellipsis if it is longer than the item — a sliced glyph reads as a
    /// fault, an ellipsis as a decision. Kept because it depends on the width
    /// and the alignment as well as on the line.
    private struct Still: Equatable {
        let width: CGFloat
        let alignment: Int
        let image: CGImage?
    }

    /// The animation currently installed on the layer.
    private struct Motion: Equatable {
        let loop: CGFloat
        /// Points per second.
        let speed: Double
        let direction: Int
        let running: Bool
    }

    /// What the layer is holding, so that neither is set again for nothing.
    private enum Shown: Equatable {
        case nothing
        case strip
        case still(width: CGFloat, alignment: Int)
    }

    private var line: Line?
    private var still: Still?
    private var motion: Motion?
    private var shown: Shown = .nothing
    private var page = 0
    private var lastPageChange = Date.distantPast
    /// Whether the line is actually travelling. It is not when it fits the
    /// item, when playback is paused, or in Static mode.
    private var moving = false
    private var idleApplied = false
    private var appliedLength: Double?
    /// Whether it was playing on the previous tick. The change marks the
    /// exact moment playback was paused.
    private var wasPlaying = false
    /// The reading the rule was last animated from, and the width it was
    /// animated across. A reading stays the same between polls, so this is
    /// what keeps the animation from being handed over again for nothing.
    private var installedProgress: NowPlayingModel.Progress?
    private var installedProgressWidth: CGFloat = 0
    private var settingsWatch: AnyCancellable?
    private var timer: Timer?

    /// The idle icon is built once. Rebuilding it from a system symbol on
    /// every tick was the main source of CPU load.
    private static let idleImage = NSImage(
        systemSymbolName: "play.fill",
        accessibilityDescription: "Nothing playing"
    )
    private var settingsWindow: NSWindow?
    private var card: NSPanel?
    private var cardHost: CardHostingView<NowPlayingCard>?
    private var cardMonitors: [Any] = []
    private var cardResize: Timer?

    init(player: NowPlayingModel, settings: DisplaySettings) {
        self.player = player
        self.settings = settings
        super.init()

        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(handleStatusClick)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.image = nil
        button.wantsLayer = true
        button.layer?.masksToBounds = true
        // Anchored at its corner, so `position` is simply where the line
        // starts; and no implicit animations, which would turn every one of
        // these settings into a quarter-second fade of its own.
        lineLayer.anchorPoint = .zero
        lineLayer.actions = [
            "position": NSNull(), "bounds": NSNull(),
            "contents": NSNull(), "hidden": NSNull()
        ]
        attach(lineFill, mask: lineLayer, to: button)
        progressLayer.anchorPoint = .zero
        progressLayer.actions = [
            "position": NSNull(), "bounds": NSNull(),
            "backgroundColor": NSNull(), "hidden": NSNull()
        ]
        progressLayer.backgroundColor = NSColor.black.cgColor
        progressLayer.isHidden = true
        progressFill.isHidden = true
        attach(progressFill, mask: progressLayer, to: button)

        rescheduleTimer()
        tick()

        // Settings is an observable object, so the display adapts the moment
        // a value changes rather than on the next tick. The notification
        // arrives BEFORE the new value is stored, so we read it one turn later.
        settingsWatch = settings.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.tick() }
        }
    }

    /// Motion is the render server's job now, so the timer only has to notice
    /// things changing: a new track, a setting, the bar going dark. Paging is
    /// the exception — a page does not move, it is replaced.
    private var tickInterval: TimeInterval {
        guard moving, settings.displayMode == 2 else { return 0.5 }
        return min(max(settings.pageInterval, 0.05), 1.0)
    }

    private func rescheduleTimer() {
        let interval = tickInterval
        if let timer, abs(timer.timeInterval - interval) < 0.001 { return }
        timer?.invalidate()
        let scheduled = Timer.scheduledTimer(timeInterval: interval, target: self,
                                             selector: #selector(tick), userInfo: nil, repeats: true)
        scheduled.tolerance = interval * 0.1
        timer = scheduled
    }

    @objc private func tick() {
        guard let button = statusItem.button else { return }

        guard player.hasTrack else {
            // Draw the idle state once and then do nothing.
            if !idleApplied {
                statusItem.length = NSStatusItem.squareLength
                appliedLength = nil
                line = nil
                still = nil
                motion = nil
                shown = .nothing
                moving = false
                lineLayer.removeAnimation(forKey: Self.motionKey)
                lineLayer.contents = nil
                hideProgress()
                button.title = ""
                button.attributedTitle = NSAttributedString(string: "")
                button.image = Self.idleImage
                button.imagePosition = .imageOnly
                idleApplied = true
                rescheduleTimer()
            }
            return
        }
        if idleApplied {
            button.image = nil
            button.imagePosition = .noImage
            idleApplied = false
        }

        if lineFill.superview !== button {
            button.wantsLayer = true
            button.layer?.masksToBounds = true
            attach(lineFill, mask: lineLayer, to: button)
            attach(progressFill, mask: progressLayer, to: button)
            shown = .nothing
            motion = nil
            installedProgress = nil
        }

        let scale = button.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        // Drawn in black: only the shape of the line matters to a mask.
        let appearance = NSAppearance(named: .aqua)!
        let font = settings.font()
        let text = player.displayText
        if line?.text != text || line?.font != font
            || line?.appearance != appearance.name || line?.scale != scale {
            line = Line(text: text, font: font, gap: Self.loopGap, scale: scale,
                        color: .black, appearance: appearance.name)
            still = nil
            motion = nil
            shown = .nothing
            page = 0
            lastPageChange = .distantPast
        }
        guard let line else { return }

        if appliedLength != settings.width {
            statusItem.length = CGFloat(settings.width)
            appliedLength = settings.width
        }
        // The width the line is actually drawn into: the button's own, once
        // the bar has laid it out. An item keeps a little padding of its own.
        let available = button.bounds.width > 1 ? button.bounds.width : CGFloat(settings.width)

        // The whole line is already on screen, so there is nothing for motion
        // to reveal. Scrolling a title that fits only made it harder to read,
        // whatever the mode is set to.
        let fits = line.width <= available

        let justPaused = wasPlaying && !player.isPlaying
        wasPlaying = player.isPlaying
        if justPaused {
            // Back to the start of the title: stopping mid-scroll would leave
            // a fragment of a word on screen.
            page = 0
            lastPageChange = .distantPast
        }

        moving = player.isPlaying && !fits && settings.displayMode != 0
        updateProgress(width: available, appearance: appearance)
        let y = ((button.bounds.height - line.height) / 2).rounded()

        switch settings.displayMode {
        case 1 where !fits:
            showStrip(line)
            let wanted = Motion(loop: line.loop,
                                speed: max(settings.scrollSpeed, 0.1) * Double(line.characterWidth),
                                direction: settings.scrollDirection,
                                running: moving)
            if motion != wanted {
                motion = wanted
                install(wanted, line: line, y: y)
            }
        case 2 where !fits:
            showStrip(line)
            stopMotion()
            let pages = max(Int(ceil(line.width / available)), 1)
            // Width and font size change from settings while the page index
            // only resets on a track change: on a wide bar the stale index ran
            // past the end of the string and crashed the app.
            if page >= pages { page = 0 }
            let now = Date()
            if moving, now.timeIntervalSince(lastPageChange) >= settings.pageInterval {
                page = (page + 1) % pages
                lastPageChange = now
            }
            lineLayer.position = CGPoint(x: -CGFloat(page) * available, y: y)
        default:
            stopMotion()
            showStill(line, width: available, alignment: settings.alignment)
            lineLayer.position = CGPoint(x: 0, y: y)
        }

        rescheduleTimer()
    }

    private func showStrip(_ line: Line) {
        guard shown != .strip else { return }
        lineLayer.contentsScale = line.scale
        lineLayer.bounds = CGRect(x: 0, y: 0, width: line.loop + line.width, height: line.height)
        lineLayer.contents = line.strip
        shown = .strip
    }

    private func showStill(_ line: Line, width: CGFloat, alignment: Int) {
        guard shown != .still(width: width, alignment: alignment) else { return }
        if still?.width != width || still?.alignment != alignment {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            paragraph.alignment = [.left, .center, .right][min(max(alignment, 0), 2)]
            let string = NSAttributedString(string: line.text, attributes: [
                .font: line.font,
                .foregroundColor: NSColor.black,
                .paragraphStyle: paragraph
            ])
            let height = ceil(string.size().height)
            let image = Self.raster(NSSize(width: width, height: line.height), scale: line.scale) {
                string.draw(in: NSRect(x: 0, y: (line.height - height) / 2, width: width, height: height))
            }
            still = Still(width: width, alignment: alignment, image: image)
        }
        lineLayer.contentsScale = line.scale
        lineLayer.bounds = CGRect(x: 0, y: 0, width: width, height: line.height)
        lineLayer.contents = still?.image
        shown = .still(width: width, alignment: alignment)
    }

    /// The rule under the line: how far into the track playback has come.
    ///
    /// Only the part played is drawn. The rest of the track was drawn behind
    /// it for a while, worn thin, and a faint rule the full width of the item
    /// underlines the title whether or not anything is playing — it reads as
    /// a border on the item rather than as a measure of the track. What is
    /// left says the same thing by its length alone.
    ///
    /// Animated rather than redrawn, for the reason the line above it is:
    /// every change to the content of a status item makes AppKit re-snapshot
    /// the whole item, so a rule advanced on a timer costs what the scrolling
    /// line used to cost. The render server is instead told once where the
    /// rule stands and when it should reach the end, and draws every frame of
    /// it without waking the app — which is also why the poll can stay at
    /// five seconds while the rule moves smoothly between polls.
    private func updateProgress(width: CGFloat, appearance: NSAppearance) {
        guard settings.showsProgress, let progress = player.progress else {
            hideProgress()
            return
        }
        progressLayer.isHidden = false
        progressFill.isHidden = false
        progressLayer.position = CGPoint(x: 0, y: progressY)
        if installedProgress != progress || installedProgressWidth != width {
            installedProgress = progress
            installedProgressWidth = width
            installProgress(progress, width: width)
        }
    }

    /// Where the rule sits, in the coordinates its layer is placed in.
    ///
    /// A status item button is flipped, and AppKit marks its backing layer's
    /// geometry to match, so a sublayer's origin is the top-left corner and
    /// not the bottom-left one. The line above it never noticed: it is
    /// centred, and a centred thing reads the same either way. The rule, an
    /// inset from the bottom, went to the top of the bar instead — above the
    /// title rather than under it.
    private var progressY: CGFloat {
        guard let button = statusItem.button else { return Self.progressInset }
        let flipped = button.layer?.isGeometryFlipped ?? button.isFlipped
        guard flipped else { return Self.progressInset }
        return button.bounds.height - Self.progressInset - Self.progressHeight
    }

    private func installProgress(_ progress: NowPlayingModel.Progress, width: CGFloat) {
        progressLayer.removeAnimation(forKey: Self.progressKey)
        let now = Date()
        let reached = (width * progress.fraction(at: now)).rounded()
        let remaining = progress.remaining(at: now)
        // A track paused, or within a moment of its end, is not going
        // anywhere: the rule stands where it stands.
        let running = progress.rate > 0 && remaining > 0.5
        // The end of the animation is the layer's own value, so when it
        // finishes there is nothing to put back and nothing to notice.
        progressLayer.bounds = CGRect(x: 0, y: 0, width: running ? width : reached,
                                      height: Self.progressHeight)
        guard running else { return }
        let animation = CABasicAnimation(keyPath: "bounds.size.width")
        animation.fromValue = reached
        animation.toValue = width
        animation.duration = remaining / progress.rate
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.isRemovedOnCompletion = false
        progressLayer.add(animation, forKey: Self.progressKey)
    }

    private func hideProgress() {
        guard !progressLayer.isHidden else { return }
        progressLayer.removeAnimation(forKey: Self.progressKey)
        progressLayer.isHidden = true
        progressFill.isHidden = true
        installedProgress = nil
    }

    private func stopMotion() {
        motion = nil
        // Unguarded: `motion` is also cleared when the track changes, and a
        // guard would then leave the previous animation running under a line
        // that is supposed to be standing still.
        lineLayer.removeAnimation(forKey: Self.motionKey)
    }

    /// Hands the loop to the render server: one animation, repeating for as
    /// long as the track lasts. At the end of a loop the second copy stands
    /// exactly where the first one started, so the restart is invisible.
    private func install(_ motion: Motion, line: Line, y: CGFloat) {
        lineLayer.removeAnimation(forKey: Self.motionKey)
        let start: CGFloat = motion.direction == 0 ? 0 : -line.loop
        let end: CGFloat = motion.direction == 0 ? -line.loop : 0
        lineLayer.position = CGPoint(x: start, y: y)
        guard motion.running, motion.speed > 0 else { return }
        let animation = CABasicAnimation(keyPath: "position.x")
        animation.fromValue = start
        animation.toValue = end
        animation.duration = Double(line.loop) / motion.speed
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.isRemovedOnCompletion = false
        lineLayer.add(animation, forKey: Self.motionKey)
    }

    private func attach(_ fill: BarTextFill, mask: CALayer, to button: NSView) {
        fill.frame = button.bounds
        fill.autoresizingMask = [.width, .height]
        button.addSubview(fill)
        fill.layer?.mask = mask
    }

    /// Draws into a bitmap `size` points across at `scale` pixels to the
    /// point, and hands back the pixels.
    private static func raster(_ size: NSSize, scale: CGFloat, _ body: () -> Void) -> CGImage? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((size.width * scale).rounded(.up)),
            pixelsHigh: Int((size.height * scale).rounded(.up)),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = size
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        body()
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    @objc private func handleStatusClick() {
        let secondary = NSApp.currentEvent?.type == .rightMouseUp
        if secondary != settings.clickOpensCard {
            toggleCard()
        } else {
            togglePlayback()
        }
    }

    private func togglePlayback() { player.togglePlayPause() }

    /// The card Control Center shows for Now Playing and nothing else, in a
    /// window of its own under the status item. Settings is the gear on the
    /// artwork; Quit is in Settings.
    ///
    /// It used to be the view of an NSMenu item. A menu's shape belongs to
    /// the system, though: its corners could not be rounded any further, and
    /// when the card folded the menu could only jump to the new height.
    private func toggleCard() {
        if card != nil { closeCard(); return }
        guard let button = statusItem.button, let barWindow = button.window else { return }

        player.openActive()
        let host = CardHostingView(rootView: NowPlayingCard(
            player: player,
            openSettings: { [weak self] in self?.closeCard(); self?.showSettings() },
            openSource: { [weak self] source in self?.closeCard(); NowPlayingModel.open(source) },
            resized: { [weak self] in onMain { self?.fitCard() } }
        ))
        // The card says nothing about its size to the window: the window is
        // sized from outside, in step with the card, and the card fills it.
        host.sizingOptions = []
        let size = NSSize(width: NowPlayingCard.width,
                          height: NowPlayingCard.height(players: player.players.count,
                                                        anyOpen: player.hasOpen))

        // See-through, like a menu. The glass the system's own menus and
        // Control Center are made of, rounded by itself; before macOS 26, the
        // menu blur, shaped by a mask alone. Corners and a border put on the
        // blur's layer instead had the system draw it as a flat fill.
        let frame = NSRect(origin: .zero, size: size)
        host.frame = frame
        host.autoresizingMask = [.width, .height]
        let backdrop: NSView
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView(frame: frame)
            glass.style = .regular
            glass.cornerRadius = Self.cardRadius
            glass.contentView = host
            backdrop = glass
        } else {
            let blur = NSVisualEffectView(frame: frame)
            blur.material = .menu
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.maskImage = Self.roundedMask(radius: Self.cardRadius)
            blur.addSubview(host)
            backdrop = blur
        }

        let panel = CardPanel(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        // Everything outside the rounded corners is cut away, so the window
        // has nothing there for its shadow to follow. Left square, it threw a
        // square shadow whose dark edge showed past the glass at the corners.
        let clip = NSView(frame: frame)
        clip.wantsLayer = true
        clip.layer?.cornerRadius = Self.cardRadius
        clip.layer?.cornerCurve = .continuous
        clip.layer?.masksToBounds = true
        backdrop.frame = clip.bounds
        backdrop.autoresizingMask = [.width, .height]
        clip.addSubview(backdrop)
        panel.contentView = clip
        panel.onCancel = { [weak self] in self?.closeCard() }

        // Under the left edge of the status item, a little below the bar,
        // and never past the side of the screen.
        let anchor = barWindow.convertToScreen(button.convert(button.bounds, to: nil))
        var origin = NSPoint(x: anchor.minX, y: anchor.minY - Self.cardGap - size.height)
        if let visible = (barWindow.screen ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        }
        panel.setFrameOrigin(origin)

        card = panel
        cardHost = host
        player.startWatching()

        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }

        // A click anywhere else puts it away, as it did a menu. Clicks on the
        // status item are left to the item, which closes it itself.
        cardMonitors = [
            NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.closeCard() }
            },
            NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                MainActor.assumeIsolated {
                    if let self, event.window !== self.card, event.window !== button.window {
                        self.closeCard()
                    }
                }
                return event
            }
        ].compactMap { $0 }
    }

    private func closeCard() {
        player.stopWatching()
        cardResize?.invalidate()
        cardResize = nil
        cardMonitors.forEach(NSEvent.removeMonitor)
        cardMonitors = []
        guard let panel = card else { return }
        card = nil
        cardHost = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    /// Opening a player out or folding it changes the card's height, and so
    /// does a player coming or going. The card animates its pieces
    /// itself; the window is walked to the new height frame by frame on the
    /// same curve and over the same time, with its top edge held still.
    private func fitCard() {
        guard let panel = card else { return }
        cardResize?.invalidate()
        let from = panel.frame.height
        let target = NowPlayingCard.height(players: player.players.count, anyOpen: player.hasOpen)
        guard abs(target - from) > 0.5 else { return }
        let top = panel.frame.maxY
        let start = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { timer in
            MainActor.assumeIsolated {
                let x = min((CACurrentMediaTime() - start) / NowPlayingCard.foldDuration, 1)
                let height = (from + (target - from) * easeInOut(x)).rounded()
                var frame = panel.frame
                frame.origin.y = top - height
                frame.size.height = height
                panel.setFrame(frame, display: true)
                panel.invalidateShadow()
                if x >= 1 { timer.invalidate() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        cardResize = timer
    }

    private static let cardRadius: CGFloat = 18
    private static let cardGap: CGFloat = 5

    /// A rounded rectangle that stretches from its middle, for `maskImage`.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    private func showSettings() {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Glass over the whole window, with the interface laid on it. Built
        // in AppKit rather than wrapped for SwiftUI — a window background is
        // the content view's job, and going through NSViewRepresentable
        // would only add a layer that has already given trouble elsewhere in
        // these apps.
        let content = NSHostingView(rootView: SettingsView(settings: settings))
        content.autoresizingMask = [.width, .height]
        let backdrop: NSView
        if #available(macOS 26, *) {
            // The system's own glass, the material Finder's sidebar and
            // Control Center are made of, so the window reads like theirs
            // rather than as a plain grey sheet. No corner radius of its own:
            // the window cuts it to the window's shape.
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.contentView = content
            backdrop = glass
        } else {
            let blur = NSVisualEffectView()
            blur.material = .sidebar
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.addSubview(content)
            backdrop = blur
        }

        let window = NSWindow(
            // As tall as the panel needs: a height fixed by hand went stale
            // every time a row was added, and the panel ran off both edges.
            contentRect: NSRect(origin: .zero, size: content.fittingSize),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // The title bar stays — it carries the close and minimise buttons —
        // but goes transparent with its title hidden, so the content runs the
        // full height of the window. Otherwise the bar sits as a separate
        // strip above the content and the rounded corners read as two
        // surfaces stacked rather than one.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // Without a bar to grab, the background has to be draggable.
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        // Without both of these the window paints its own opaque backing
        // first and the blur has nothing behind it to show.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = backdrop
        content.frame = backdrop.bounds
        window.center()
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// The track as Control Center shows it: the artwork, the title and who by,
/// the transport, and a bar that can be dragged to move through the track.
private struct NowPlayingCard: View {
    @ObservedObject var player: NowPlayingModel
    let openSettings: () -> Void
    /// Closes the card and brings the app with this bundle identifier forward.
    let openSource: (String) -> Void
    let resized: () -> Void

    static let artworkSide: CGFloat = 100
    static let compactArtworkSide: CGFloat = 44
    static let padding = EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)

    static let width: CGFloat = 328
    static let foldedHeight = compactArtworkSide + padding.top + padding.bottom
    static let openHeight = artworkSide + padding.top + padding.bottom
    /// A folded row for every player, one of them perhaps opened out. Known
    /// in advance rather than measured, so the window can set off for it at
    /// the same moment as the card.
    static func height(players: Int, anyOpen: Bool) -> CGFloat {
        CGFloat(max(players, 1)) * foldedHeight + (anyOpen ? openHeight - foldedHeight : 0)
    }
    /// How long folding takes. The card and its window both use it, on the
    /// same curve (`.easeInOut`, see `easeInOut(_:)`), so they move as one.
    static let foldDuration: TimeInterval = 0.45
    static var fold: Animation { .easeInOut(duration: foldDuration) }

    /// Every player, the system's pick first, each folded to one row when the
    /// card opens. Clicking a title opens that player out and folds the one
    /// that was open.
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(player.players.enumerated()), id: \.element.id) { index, item in
                PlayerBlock(model: player, item: item, open: item.id == player.openID,
                            first: index == 0, openSettings: openSettings, openSource: openSource)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onChange(of: player.players.count) { _ in resized() }
        .onChange(of: player.hasOpen) { _ in resized() }
    }
}

/// One player in the card, folded to a row or opened out.
///
/// One layout for both shapes, every piece always there, so folding moves
/// each one from where it was to where it goes and nothing fades. The cover
/// shrinks into its corner, the title slides down beside it, play and skip
/// travel to the end of the row, and the bottom edge, coming up, pushes the
/// bar out. The gear and the back button do not travel: they shrink away as
/// folding starts, and pop back in near its end. Opening runs it all
/// backwards.
///
/// Places are worked out here rather than left to stacks, because a piece
/// that changes stacks is a new piece to SwiftUI and can only be faded from
/// one to the other.
private struct PlayerBlock: View {
    @ObservedObject var model: NowPlayingModel
    let item: NowPlayingModel.Player
    let open: Bool
    /// The first has no hairline over it.
    let first: Bool
    let openSettings: () -> Void
    let openSource: (String) -> Void

    private var compact: Bool { !open }

    /// Whether this is the player the system sends commands to, and so the
    /// one the back button and the bar can reach. Play and forward reach the
    /// others too, through Control Center.
    private var controllable: Bool { item.id == model.controllableID }

    var body: some View {
        let layout = Layout(compact: compact)
        ZStack(alignment: .topLeading) {
            artwork(side: layout.side)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    // Only the one playing runs its title along.
                    MarqueeText(text: item.hasTrack ? item.title : "Not Playing",
                                font: .systemFont(ofSize: 14, weight: .semibold),
                                moves: item.isPlaying)
                    if item.hasTrack { PlayingIndicator(playing: item.isPlaying) }
                }
                subtitleText
            }
            .frame(width: layout.textWidth, alignment: .leading)
            .modifier(Folds { model.toggleOpen(item) })
            .offset(x: layout.textX, y: layout.textY)
            ScrubBar(progress: item.progress, tint: item.abilities?.tint) { model.seek(item, to: $0) }
                .disabled(!controllable || !item.canScrub)
                .frame(width: layout.scrubWidth)
                .offset(x: layout.textX, y: layout.scrubY)
            Group {
                // What the buttons are, and which of them work, is what the
                // player says it can do, as in Control Center.
                TransportButton(symbol: item.skips ? Self.skipSymbol(forward: false, item.skipInterval)
                                                   : "backward.fill",
                                size: 17, width: layout.button) {
                    model.goBack(item)
                }
                // Back and the bar reach only the player commands go to;
                // Control Center lists no such button for the others.
                .disabled(!controllable || !item.canGoBack)
                .modifier(PopsIn(shown: open, pulses: false))
                .offset(x: layout.previousX, y: layout.buttonY)
                TransportButton(symbol: item.isPlaying ? "pause.fill" : "play.fill", size: 24,
                                width: layout.button, scale: compact ? 20.0 / 24 : 1,
                                playing: item.isPlaying) {
                    model.togglePlayPause(item)
                }
                .disabled(!item.canPlayPause)
                .offset(x: layout.playX, y: layout.buttonY)
                TransportButton(symbol: item.skips ? Self.skipSymbol(forward: true, item.skipInterval)
                                                   : "forward.fill",
                                size: 17, width: layout.button, scale: compact ? 15.0 / 17 : 1) {
                    model.goForward(item)
                }
                .disabled(!item.canGoForward)
                .offset(x: layout.playX + layout.button, y: layout.buttonY)
            }
            .disabled(!item.hasTrack)
        }
        .frame(width: Layout.width, height: layout.side, alignment: .topLeading)
        .padding(NowPlayingCard.padding)
        // What lies past its edges — the bar and the back button, folded —
        // is cut off here, not left to show over the player below.
        .frame(width: NowPlayingCard.width,
               height: open ? NowPlayingCard.openHeight : NowPlayingCard.foldedHeight,
               alignment: .top)
        .clipped()
        // A hairline between it and the player above, inset like the
        // contents.
        .overlay(alignment: .top) {
            if !first {
                Rectangle()
                    .fill(Color.primary.opacity(0.1))
                    .frame(height: 0.5)
                    .padding(.horizontal, NowPlayingCard.padding.leading)
            }
        }
    }

    /// The places, inside the padding, measured from its top-left corner.
    private struct Layout {
        static let width = NowPlayingCard.width - NowPlayingCard.padding.leading
            - NowPlayingCard.padding.trailing
        static let gap: CGFloat = 12
        static let textHeight: CGFloat = 33     // title, a point, and the subtitle
        static let buttonHeight: CGFloat = 32
        static let scrubHeight: CGFloat = 27    // the bar and the times under it

        let compact: Bool
        var side: CGFloat { compact ? NowPlayingCard.compactArtworkSide : NowPlayingCard.artworkSide }
        var button: CGFloat { compact ? 34 : 52 }
        /// Far enough past the bottom edge to be out of sight.
        var away: CGFloat { 48 }

        var textX: CGFloat { side + Self.gap }
        var textY: CGFloat { compact ? (side - Self.textHeight) / 2 : 0 }
        var textWidth: CGFloat { (compact ? playX - Self.gap : Self.width) - textX }

        /// Open, the three buttons are centred under the title, and the bar
        /// sits at the bottom with even room above and below the buttons.
        /// Folded, play and skip close the row.
        var playX: CGFloat {
            compact ? Self.width - 2 * button : textX + (Self.width - textX - 3 * button) / 2 + button
        }
        var buttonY: CGFloat {
            compact ? (side - Self.buttonHeight) / 2
                    : Self.textHeight + (side - Self.textHeight - Self.buttonHeight - Self.scrubHeight) / 2
        }
        var previousX: CGFloat { playX - button }
        var scrubY: CGFloat { compact ? side + away / 2 : side - Self.scrubHeight }
        var scrubWidth: CGFloat { Self.width - textX }
    }

    /// The arrow with the interval in it — "gobackward.15" — when there is
    /// such a symbol, a plain arrow when there is not.
    private static func skipSymbol(forward: Bool, _ seconds: Double) -> String {
        let name = forward ? "goforward" : "gobackward"
        let whole = Int(seconds.rounded())
        return [5, 10, 15, 30, 45, 60, 75, 90].contains(whole) ? "\(name).\(whole)" : name
    }

    private func artwork(side: CGFloat) -> some View {
        let picture = model.artwork(for: item)
        let icon = item.source.flatMap(NowPlayingModel.icon(of:))
        // A video's picture is wide, and opened out it is shown whole, the
        // way Control Center shows it: as wide as the square was, less tall,
        // and centred on it. Folded, every picture fills a square.
        let shape = picture.map { $0.size.height / max($0.size.width, 1) } ?? 1
        let height = open && shape < 0.85 ? side * shape : side
        return ArtworkTile(image: picture, side: side, height: height, placeholder: icon)
            .overlay(alignment: .topLeading) {
                SettingsBadge(action: openSettings)
                    .modifier(PopsIn(shown: open))
                    .padding(5)
            }
            // The app it plays in, on the cover's corner, as Control Center
            // marks it. Not over the empty tile, which shows the icon already.
            .overlay(alignment: .bottomTrailing) {
                if picture != nil, let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: side * 0.22 + 8, height: side * 0.22 + 8)
                        .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                        .offset(x: 4, y: 4)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { item.source.map(openSource) }
            .help(item.name.isEmpty ? "" : "Open \(item.name)")
            .frame(width: side, height: side)
    }

    private var subtitleText: some View {
        Text(subtitle)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var subtitle: String {
        guard item.hasTrack else { return " " }
        let parts = [item.artist, item.album].filter { !$0.isEmpty }
        return parts.isEmpty ? (item.name.isEmpty ? " " : item.name) : parts.joined(separator: " — ")
    }
}

/// The ease-in-out curve of SwiftUI's `.easeInOut` and Core Animation's
/// `.easeInEaseOut`: a cubic Bézier through (0.42, 0) and (0.58, 1). For
/// things outside SwiftUI that have to keep pace with an animation in it.
private func easeInOut(_ x: Double) -> Double {
    let (x1, x2) = (0.42, 0.58)
    func curve(_ t: Double, _ a: Double, _ b: Double) -> Double {
        3 * (1 - t) * (1 - t) * t * a + 3 * (1 - t) * t * t * b + t * t * t
    }
    // Find the point on the curve at time x, then read off its progress.
    var t = x
    for _ in 0..<8 {
        let error = curve(t, x1, x2) - x
        let slope = 3 * (1 - t) * (1 - t) * x1 + 6 * (1 - t) * t * (x2 - x1) + 3 * t * t * (1 - x2)
        if abs(error) < 1e-6 || slope == 0 { break }
        t = min(max(t - error / slope, 0), 1)
    }
    return curve(t, 0, 1)
}

/// Takes the first click as a click. After Control Center has been worked
/// the card is no longer the key window, and without this the click meant
/// for a button only made it key again — every other press did nothing.
private final class CardHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The card's window. Borderless, so it says for itself that it may take
/// the keyboard — for Escape, which puts it away.
private final class CardPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// The way into Settings: a small gear over the corner of the artwork.
private struct SettingsBadge: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            // No disc under it: a shadow keeps it legible on a light cover.
            Image(systemName: "gearshape.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.white.opacity(hovering ? 1 : 0.9))
                .shadow(color: .black.opacity(0.55), radius: 2, y: 0.5)
                .frame(width: 22, height: 22)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Settings")
    }
}

/// For a piece the folded card has no room for: it shrinks away as folding
/// starts, and grows back as the card opens out.
///
/// One that `pulses` — the gear — grows in past its size and settles back
/// with a beat or two, once the card is most of the way open and also when
/// the card is first shown, so it is seen arriving. One that does not — the
/// back button — is simply there when the card is shown, like the buttons
/// beside it, and grows back with the card, on its curve, when it unfolds.
private struct PopsIn: ViewModifier {
    let shown: Bool
    let pulses: Bool
    @State private var scale: CGFloat

    init(shown: Bool, pulses: Bool = true) {
        self.shown = shown
        self.pulses = pulses
        _scale = State(initialValue: shown && !pulses ? 1 : 0)
    }

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .allowsHitTesting(shown)
            .onAppear { if shown && pulses { pulseIn(after: 0.12) } }
            .onChange(of: shown) { shown in
                if !shown {
                    withAnimation(.easeIn(duration: 0.15)) { scale = 0 }
                } else if pulses {
                    pulseIn(after: NowPlayingCard.foldDuration * 0.6)
                } else {
                    withAnimation(NowPlayingCard.fold) { scale = 1 }
                }
            }
    }

    private func pulseIn(after delay: TimeInterval) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.4).delay(delay)) { scale = 1 }
    }
}

private struct ArtworkTile: View {
    let image: NSImage?
    let side: CGFloat
    /// Less than `side` for a wide picture shown whole.
    var height: CGFloat? = nil
    /// The playing app's icon, drawn small in the middle of the tile while
    /// there is no picture.
    var placeholder: NSImage? = nil

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.primary.opacity(0.08)
                if let placeholder {
                    Image(nsImage: placeholder)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: min(side, height ?? side) * 0.4, height: min(side, height ?? side) * 0.4)
                }
            }
        }
        .frame(width: side, height: height ?? side)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.25), radius: 4, y: 1)
    }
}

/// Beside the title: bars that rise and fall while the player plays, and
/// stand still as dots while it is paused.
///
/// Core Animation moves them, in the window server, rather than SwiftUI
/// redrawing them every frame in this process: drawn by SwiftUI, they and
/// the scrolling titles kept the app near a third of a core busy for as long
/// as the card was open.
private struct PlayingIndicator: NSViewRepresentable {
    let playing: Bool

    func makeNSView(context: Context) -> BarsView { BarsView() }

    func updateNSView(_ view: BarsView, context: Context) { view.playing = playing }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: BarsView, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
}

private final class BarsView: NSView {
    private static let bars = 4
    private static let barWidth: CGFloat = 2
    private static let spacing: CGFloat = 1.5
    private static let height: CGFloat = 11
    /// Each bar on its own pace, so together they never move in step.
    private static let periods: [CFTimeInterval] = [0.62, 0.43, 0.75, 0.5]

    var playing = false {
        didSet { if playing != oldValue { animate() } }
    }

    private var barLayers: [CALayer] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for _ in 0..<Self.bars {
            let bar = CALayer()
            bar.anchorPoint = CGPoint(x: 0.5, y: 0)
            bar.cornerRadius = Self.barWidth / 2
            layer?.addSublayer(bar)
            barLayers.append(bar)
        }
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        animate()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: CGFloat(Self.bars) * Self.barWidth + CGFloat(Self.bars - 1) * Self.spacing,
               height: Self.height)
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let colour = NSColor.secondaryLabelColor.cgColor
        for bar in barLayers { bar.backgroundColor = colour }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in barLayers.enumerated() {
            let x = CGFloat(index) * (Self.barWidth + Self.spacing) + Self.barWidth / 2
            bar.position = CGPoint(x: x, y: 0)
            bar.bounds.size.width = Self.barWidth
        }
        CATransaction.commit()
    }

    private func animate() {
        for (index, bar) in barLayers.enumerated() {
            let resting = Self.barWidth
            let from = bar.presentation()?.bounds.size.height ?? resting
            bar.removeAllAnimations()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            bar.bounds.size.height = resting
            CATransaction.commit()
            if playing {
                let bounce = CABasicAnimation(keyPath: "bounds.size.height")
                bounce.fromValue = resting
                bounce.toValue = Self.height
                bounce.duration = Self.periods[index % Self.periods.count]
                bounce.autoreverses = true
                bounce.repeatCount = .infinity
                bounce.timeOffset = bounce.duration * Double(index) * 0.37
                bounce.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                bar.add(bounce, forKey: "bounce")
            } else if from > resting {
                // Settles to a dot rather than dropping to one.
                let settle = CABasicAnimation(keyPath: "bounds.size.height")
                settle.fromValue = from
                settle.toValue = resting
                settle.duration = 0.25
                settle.timingFunction = CAMediaTimingFunction(name: .easeOut)
                bar.add(settle, forKey: "settle")
            }
        }
    }
}

/// Clicking the title opens the player out, or folds it again.
private struct Folds: ViewModifier {
    let toggle: () -> Void

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(NowPlayingCard.fold) { toggle() } }
    }
}

private struct TransportButton: View {
    let symbol: String
    let size: CGFloat
    var width: CGFloat = 52
    /// Scales the glyph alone; unlike its point size, this can be animated.
    var scale: CGFloat = 1
    /// For the play button: drawn as a shape that turns from the triangle
    /// into the two bars and back, instead of one symbol swapped for another.
    var playing: Bool? = nil
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            // Styled on the glyph itself: a plain button in a menu draws its
            // label in the primary colour whatever it is given from outside.
            // Drawn opaque and faded as one: faded piece by piece, the play
            // glyph's fill and its rounding outline overlapped twice as dark.
            glyph
                .scaleEffect(scale)
                .foregroundStyle(Color.primary)
                .compositingGroup()
                .opacity(hovering && isEnabled ? 0.85 : 0.5)
                .frame(width: width, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.5)
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var glyph: some View {
        if let playing {
            // About the size the symbols are drawn at this point size.
            let height = size * 0.74
            let shape = PlayPauseShape(progress: playing ? 1 : 0)
            shape.fill()
                .frame(width: height * 0.84, height: height)
            .animation(.spring(response: 0.32, dampingFraction: 0.8), value: playing)
        } else {
            Image(systemName: symbol).font(.system(size: size, weight: .regular))
        }
    }
}

/// The play triangle at 0, the pause bars at 1, and every shape between.
/// (Its corners are rounded by `addRounded`, each by as much as its sides
/// allow, so a corner closing to a point stays a point.)
/// The triangle is cut down the middle into two pieces, each with four
/// corners, and each piece's corners travel to those of one bar: the left
/// half straightens into the left bar, the right tip widens into the right.
private struct PlayPauseShape: Shape {
    var progress: CGFloat

    /// A closed outline through the corners, each rounded by its radius or
    /// by as much as the two sides beside it leave room for. Corners that
    /// have met — the triangle's tip, made of two — count as one.
    static func addRounded(_ corners: [CGPoint], radii: [CGFloat], to path: inout Path) {
        var points: [CGPoint] = []
        var rounding: [CGFloat] = []
        for (point, radius) in zip(corners, radii)
            where points.last.map({ hypot($0.x - point.x, $0.y - point.y) > 0.01 }) ?? true {
            points.append(point)
            rounding.append(radius)
        }
        if points.count > 1, hypot(points[0].x - points.last!.x, points[0].y - points.last!.y) <= 0.01 {
            points.removeLast()
            rounding.removeLast()
        }
        guard points.count >= 3 else { return }
        func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
        let count = points.count
        let start = CGPoint(x: (points[count - 1].x + points[0].x) / 2, y: (points[count - 1].y + points[0].y) / 2)
        path.move(to: start)
        for index in 0..<count {
            let previous = points[(index + count - 1) % count]
            let corner = points[index]
            let next = points[(index + 1) % count]
            let room = min(distance(previous, corner), distance(corner, next)) / 2
            path.addArc(tangent1End: corner, tangent2End: next, radius: max(min(rounding[index], room), 0.001))
        }
        path.closeSubpath()
    }

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        // The triangle sits a little right of centre, as the symbol does,
        // so that it looks centred.
        let nudge = w * 0.06 * (1 - progress)
        func point(_ play: CGPoint, _ pause: CGPoint) -> CGPoint {
            CGPoint(x: rect.minX + play.x + (pause.x - play.x) * progress + nudge,
                    y: rect.minY + play.y + (pause.y - play.y) * progress)
        }
        let bar = w * 0.34
        let left = [
            point(CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 0)),
            point(CGPoint(x: w / 2, y: h / 4), CGPoint(x: bar, y: 0)),
            point(CGPoint(x: w / 2, y: h * 3 / 4), CGPoint(x: bar, y: h)),
            point(CGPoint(x: 0, y: h), CGPoint(x: 0, y: h))
        ]
        let right = [
            point(CGPoint(x: w / 2, y: h / 4), CGPoint(x: w - bar, y: 0)),
            point(CGPoint(x: w, y: h / 2), CGPoint(x: w, y: 0)),
            point(CGPoint(x: w, y: h / 2), CGPoint(x: w, y: h)),
            point(CGPoint(x: w / 2, y: h * 3 / 4), CGPoint(x: w - bar, y: h))
        ]
        // Both pieces in one path, filled once: with no outline laid over
        // it there is nothing to overlap, and no seam where the halves of
        // the triangle meet. The corners are rounded in the outline itself.
        var path = Path()
        // The corners where the two halves meet inside the triangle are
        // rounded only as the halves part into bars; rounded from the start,
        // they cut a notch into the middle of the triangle.
        let round = min(w, h) * 0.07
        let inner = round * progress
        Self.addRounded(left, radii: [round, inner, inner, round], to: &path)
        Self.addRounded(right, radii: [inner, round, round, inner], to: &path)
        return path
    }
}

/// The played part of the track over the rest of it, with the time gone and
/// the time left beneath. Dragging it moves the player.
private struct ScrubBar: View {
    let progress: NowPlayingModel.Progress?
    /// The app's own colour where it has one, else the system accent — the
    /// blue Control Center draws the played part in.
    var tint: NSColor? = nil
    let seek: (Double) -> Void
    /// Where the finger is while dragging; the bar follows it rather than
    /// the player until the player has been told.
    @State private var dragging: Double?

    var body: some View {
        // Redrawn twice a second while the menu is open, and not at all
        // otherwise: the view only exists while the menu does.
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let duration = progress?.duration ?? 0
            let elapsed = dragging.map { $0 * duration } ?? progress?.elapsed(at: context.date) ?? 0
            let fraction = duration > 0 ? elapsed / duration : 0
            VStack(spacing: 4) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.15))
                        Capsule().fill(tint.map(Color.init) ?? Color.accentColor)
                            .frame(width: max(geometry.size.width * fraction, 0))
                    }
                    .frame(height: dragging == nil ? 4 : 6)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard duration > 0 else { return }
                            dragging = min(max(value.location.x / geometry.size.width, 0), 1)
                        }
                        .onEnded { _ in
                            if let dragging, duration > 0 { seek(dragging * duration) }
                            // Hold the dragged place until the player reports
                            // the new one, or the bar jumps back and forth.
                            onMain(after: 0.8) { dragging = nil }
                        })
                }
                .frame(height: 10)
                HStack {
                    Text(progress == nil ? "--:--" : Self.clock(elapsed))
                    Spacer()
                    Text(progress == nil ? "--:--" : "−" + Self.clock(max(duration - elapsed, 0)))
                }
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .disabled(progress == nil)
        }
    }

    /// Minutes and seconds, with hours in front once there are any — the
    /// way Control Center counts a mix an hour and a half long.
    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        let (hours, minutes, secs) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0
            ? String(format: "%02d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }
}

/// A single line that scrolls when it does not fit, the way Control Center
/// moves a long title: a pause at the start, one pass, and round again.
///
/// The text is drawn once into a picture and Core Animation slides it, in
/// the window server; drawn by SwiftUI every frame, as it was, scrolling
/// titles cost the app a large share of a core while the card was open.
private struct MarqueeText: NSViewRepresentable {
    let text: String
    let font: NSFont
    /// When false a title too long to fit stands still, cut short.
    var moves = true

    func makeNSView(context: Context) -> MarqueeView { MarqueeView() }

    func updateNSView(_ view: MarqueeView, context: Context) {
        view.configure(text: text, font: font, moves: moves)
    }

    /// As wide as it is offered, one line high: left to itself it took all
    /// the height it was offered too, and opened out the title sank to the
    /// bottom of the card, over the bar.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MarqueeView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.naturalWidth, height: nsView.intrinsicContentSize.height)
    }
}

private final class MarqueeView: NSView {
    private static let gap: CGFloat = 32
    private static let speed: CGFloat = 30   // points per second
    private static let pause: CFTimeInterval = 2

    private var text = ""
    private var font = NSFont.systemFont(ofSize: 13)
    private var moves = true

    private let strip = CALayer()
    private let first = CALayer()
    private let second = CALayer()
    private let fade = CAGradientLayer()
    /// What the running scroll was set up for, so that SwiftUI asking again
    /// with the same text does not start it over from the beginning.
    private var running: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(strip)
        strip.addSublayer(first)
        strip.addSublayer(second)
        strip.anchorPoint = .zero
        for piece in [first, second] {
            piece.anchorPoint = .zero
            piece.contentsGravity = .bottomLeft
        }
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var lineHeight: CGFloat { ceil(font.ascender - font.descender + font.leading) + 1 }
    private var textWidth: CGFloat { ceil((text as NSString).size(withAttributes: [.font: font]).width) }
    var naturalWidth: CGFloat { textWidth }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: lineHeight)
    }

    func configure(text: String, font: NSFont, moves: Bool) {
        let redraw = text != self.text || font != self.font
        self.text = text
        self.font = font
        self.moves = moves
        if redraw {
            invalidateIntrinsicContentSize()
            render()
        }
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        render()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        render()
    }

    /// The title as a picture, in the label colour of the current
    /// appearance.
    private func render() {
        let size = NSSize(width: max(textWidth, 1), height: lineHeight)
        let appearance = effectiveAppearance
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let line = text
        let image = NSImage(size: size, flipped: true) { rect in
            appearance.performAsCurrentDrawingAppearance {
                (line as NSString).draw(in: rect, withAttributes: attributes)
            }
            return true
        }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let picture = image.layerContents(forContentsScale: scale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for piece in [first, second] {
            piece.contents = picture
            piece.contentsScale = scale
        }
        CATransaction.commit()
        running = nil
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let overflows = textWidth > width
        let scrolls = overflows && moves && width > 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        first.frame = CGRect(x: 0, y: 0, width: textWidth, height: lineHeight)
        second.frame = CGRect(x: textWidth + Self.gap, y: 0, width: textWidth, height: lineHeight)
        second.isHidden = !scrolls
        // A soft edge wherever the title runs on past it.
        if overflows {
            fade.frame = bounds
            fade.colors = [scrolls ? NSColor.clear.cgColor : NSColor.black.cgColor,
                           NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
            fade.locations = [0, 0.06, 0.94, 1]
            layer?.mask = fade
        } else {
            layer?.mask = nil
        }
        CATransaction.commit()

        let key = scrolls ? "\(text)|\(textWidth)" : nil
        guard key != running else { return }
        running = key
        strip.removeAnimation(forKey: "scroll")
        guard scrolls else { return }
        // Waits at the start, passes once, and round again; the second copy
        // makes the end meet the beginning.
        let travel = textWidth + Self.gap
        let pass = CFTimeInterval(travel / Self.speed)
        let scroll = CAKeyframeAnimation(keyPath: "transform.translation.x")
        scroll.values = [0, 0, -travel]
        scroll.keyTimes = [0, NSNumber(value: Self.pause / (Self.pause + pass)), 1]
        scroll.duration = Self.pause + pass
        scroll.repeatCount = .infinity
        strip.add(scroll, forKey: "scroll")
    }
}

/// The settings panel: a stack of grouped cards over the window's blur, the
/// shape System Settings has used since Ventura. It replaced a plain `Form`,
/// whose boxed sections and full-width controls read as a decade-old
/// preferences sheet next to the rest of the app.
///
/// The panel does not scroll. Every row is a fixed height, so the window is
/// sized to hold all of them at once and the whole of it stays in view.
private struct SettingsView: View {
    @ObservedObject var settings: DisplaySettings

    static let width: CGFloat = 400
    /// Every control ends on the same trailing edge and, being this wide,
    /// starts on the same leading one: segmented controls, pop-up menus and
    /// sliders with their readout alike.
    static let controlWidth: CGFloat = 190
    /// The window's margin, on all four sides.
    static let margin: CGFloat = 20

    /// Scrolling and paging each use a different half of the Motion card.
    /// Rather than hide the rows that do not apply — which would make the
    /// card jump about as the mode changes — they are dimmed and disabled.
    private var scrolls: Bool { settings.displayMode == 1 }
    private var pages: Bool { settings.displayMode == 2 }

    var body: some View {
        VStack(spacing: 0) {
            // Drawn here rather than left to the window: the title bar is
            // transparent, so its own title would float above the content
            // instead of sitting inside it. The top padding puts the
            // heading's middle on the traffic lights' line, 14 points down.
            Text("Settings")
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.top, 6)
                .padding(.bottom, 16)

            VStack(alignment: .leading, spacing: 16) {
                SettingsCard("Display") {
                    SettingsRow("Mode") {
                        Picker("", selection: $settings.displayMode) {
                            Text("Static").tag(0)
                            Text("Scroll").tag(1)
                            Text("Pages").tag(2)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: Self.controlWidth)
                    }
                    SettingsDivider()
                    SliderRow(title: "Width", value: $settings.width,
                              range: 100...360, format: "%.0f pt")
                    SettingsDivider()
                    SettingsRow("Alignment") {
                        Picker("", selection: $settings.alignment) {
                            Text("Left").tag(0)
                            Text("Center").tag(1)
                            Text("Right").tag(2)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: Self.controlWidth)
                    }
                }

                SettingsCard("Information") {
                    SettingsRow("Show artist") {
                        Toggle("", isOn: $settings.showsArtist).labelsHidden().toggleStyle(.switch)
                    }
                    SettingsDivider()
                    SettingsRow("Show album") {
                        Toggle("", isOn: $settings.showsAlbum).labelsHidden().toggleStyle(.switch)
                    }
                    SettingsDivider()
                    SettingsRow("Show progress") {
                        Toggle("", isOn: $settings.showsProgress).labelsHidden().toggleStyle(.switch)
                    }
                }

                SettingsCard("Type") {
                    SettingsRow("Typeface") {
                        Picker("", selection: $settings.fontName) {
                            ForEach(DisplaySettings.typefaces, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: Self.controlWidth)
                    }
                    SettingsDivider()
                    SliderRow(title: "Size", value: $settings.fontSize,
                              range: 9...18, format: "%.0f pt")
                }

                SettingsCard("Motion") {
                    SettingsRow("Direction") {
                        Picker("", selection: $settings.scrollDirection) {
                            Text("Left").tag(0)
                            Text("Right").tag(1)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: Self.controlWidth)
                    }
                    .modifier(Applies(when: scrolls))
                    SettingsDivider()
                    SliderRow(title: "Scroll speed", value: $settings.scrollSpeed,
                              range: 0.5...10, format: "%.1f ch/s")
                        .modifier(Applies(when: scrolls))
                    SettingsDivider()
                    SliderRow(title: "Page interval", value: $settings.pageInterval,
                              range: 1...10, format: "%.1f s")
                        .modifier(Applies(when: pages))
                }

                SettingsCard("Menu Bar", footnote: settings.clickOpensCard
                             ? "A two-finger click plays or pauses."
                             : "A two-finger click opens the card.") {
                    SettingsRow("Click") {
                        Picker("", selection: $settings.clickOpensCard) {
                            Text("Play / Pause").tag(false)
                            Text("Open Card").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: Self.controlWidth)
                    }
                }

            }
            .padding(.horizontal, Self.margin)

            // The buttons belong to the window rather than to the last card:
            // they sit on its bottom margin, a margin away from the cards.
            Spacer(minLength: Self.margin)

            HStack {
                // The menu has no rows any more, so the app is quit from here.
                Button("Quit Now Playing Menu") { NSApp.terminate(nil) }
                    .controlSize(.regular)
                    .fixedSize()
                Spacer()
                Button("Reset to Defaults") { settings.reset() }
                    .controlSize(.regular)
                    // Its own width, never the squeezed one: the title is
                    // what decides how wide the button is.
                    .fixedSize()
            }
            .padding(.horizontal, Self.margin)
            .padding(.bottom, Self.margin)
        }
        .frame(width: Self.width)
        // The title bar is see-through and the heading is placed on its line
        // by hand, so the bar's inset is not wanted on top of that.
        .ignoresSafeArea()
        // No background of its own: the blur layer beneath the hosting view
        // is what paints this window, and an opaque fill here would hide it.
        // Nor is a scheme forced, unlike the panels in the other two apps —
        // this is a plain system surface and follows the system's light and
        // dark.
    }

}

/// A titled group of rows on one rounded surface.
private struct SettingsCard<Content: View>: View {
    private let title: String
    private let footnote: String?
    private let content: Content

    init(_ title: String, footnote: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footnote = footnote
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(spacing: 0) { content }
                // Translucent rather than filled: the card sits on the
                // window's blur and should let it through.
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.07))
                )
            // Under the card, in line with its title, the way System
            // Settings explains a row.
            if let footnote {
                Text(footnote)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
        }
    }
}

/// One row: a label at the leading edge, its control at the trailing one.
private struct SettingsRow<Control: View>: View {
    private let title: String
    private let control: Control

    init(_ title: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 13))
            Spacer(minLength: 8)
            control
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
    }
}

/// The hairline between rows, inset from the leading edge the way the system
/// insets its own so it reads as a break in one surface, not a border.
private struct SettingsDivider: View {
    var body: some View {
        Divider().opacity(0.45).padding(.leading, 12)
    }
}

/// Dims and disables a row that the current display mode does not use.
private struct Applies: ViewModifier {
    let when: Bool

    func body(content: Content) -> some View {
        content
            .disabled(!when)
            .opacity(when ? 1 : 0.4)
    }
}

private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String

    var body: some View {
        SettingsRow(title) {
            HStack(spacing: 10) {
                Slider(value: $value, in: range).frame(width: 132)
                // Fixed width and lining figures: without them the row
                // twitched sideways as the digits changed.
                Text(String(format: format, value))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
            }
        }
    }
}

/// A view the colour of the menu bar's text, and nothing else. The line and
/// the rule are its masks. Being a view, it is repainted by AppKit whenever
/// the bar's appearance changes, together with the bar's own icons.
private final class BarTextFill: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    // Clicks belong to the button underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.labelColor.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
