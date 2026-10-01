import SwiftUI
import AppKit
import Combine
import MediaRemoteBridge

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
                self.artwork = data.flatMap(NSImage.init(data:))
            }
        }
    }

    // MARK: Commands

    func togglePlayPause() {
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

    /// Brings the playing app forward — the way clicking the artwork in
    /// Control Center does.
    func openSource() {
        guard let source else { return }
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
    /// Whether the card in the menu is folded to one row. Not a setting in
    /// the window: it is toggled by clicking the title, and remembered.
    @Published var compactCard: Bool { didSet { save("compactCard", compactCard) } }
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
        compactCard = defaults.object(forKey: "compactCard") as? Bool ?? false
        clickOpensCard = defaults.object(forKey: "clickOpensCard") as? Bool ?? false
    }

    func reset() {
        displayMode = 0; width = 167; fontName = "System"; fontSize = 13
        showsArtist = true; showsAlbum = false; showsProgress = true; alignment = 0
        scrollDirection = 0; scrollSpeed = 3; pageInterval = 2
        clickOpensCard = false
    }

    func font() -> NSFont {
        switch fontName {
        case "Condensed": return NSFont(name: "HelveticaNeue-CondensedBold", size: fontSize) ?? .systemFont(ofSize: fontSize)
        case "Monospaced": return NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        case "Rounded": return NSFont.systemFont(ofSize: fontSize, weight: .regular)
        default: return NSFont.menuBarFont(ofSize: fontSize)
        }
    }

    private func save(_ key: String, _ value: Any) { defaults.set(value, forKey: key) }
}

private enum SystemNowPlaying {
    static func fetch() -> [String: Any] {
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

/// The artwork of the current item. The app may not ask mediaremoted for it
/// (see ArtworkHelper.m), so the system's own perl asks instead, loading the
/// helper library and calling into it.
private enum SystemArtwork {
    static func fetch() -> Data? {
        guard let library = helperURL() else { return nil }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", """
            use DynaLoader;
            my $h = DynaLoader::dl_load_file($ARGV[0]) or die DynaLoader::dl_error();
            my $f = DynaLoader::dl_find_symbol($h, "NPMWriteArtwork") or die "no symbol";
            DynaLoader::dl_install_xsub("main::artwork", $f);
            artwork();
            """, library.path]
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
            showMenu()
        } else {
            togglePlayback()
        }
    }

    private func togglePlayback() { player.togglePlayPause() }

    /// The menu is the card Control Center shows for Now Playing and nothing
    /// else. Settings is the gear on the artwork; Quit is in Settings.
    private func showMenu() {
        let menu = NSMenu()
        // The card carries no action; without this AppKit would grey it out.
        menu.autoenablesItems = false
        // The menu is popped up from the status button and would otherwise
        // inherit the button's appearance — which is the menu bar's, a
        // vibrant one that follows the desktop picture rather than the system
        // setting. That is right for the line drawn in the bar and wrong for
        // a menu: it left the menu light while the rest of macOS was dark.
        // A menu belongs to the app, so it takes the app's appearance.
        menu.appearance = NSApp.effectiveAppearance

        // The gear only closes the menu; the window opens once the menu has
        // gone, since a window brought forward during tracking sits behind it.
        // So does the artwork, before bringing the player forward.
        var wantsSettings = false
        var wantsSource = false
        let header = NSMenuItem()
        var card: NSHostingView<NowPlayingCard>!
        card = NSHostingView(rootView: NowPlayingCard(
            player: player, settings: settings,
            openSettings: { wantsSettings = true; menu.cancelTracking() },
            openSource: { wantsSource = true; menu.cancelTracking() },
            // Folding the card changes its height, and a menu takes the size
            // of an item's view from its frame, not from what the view would
            // like. Asked for once the card has laid itself out again.
            resized: {
                onMain {
                    card.setFrameSize(card.fittingSize)
                    menu.itemChanged(header)
                }
            }
        ))
        card.frame = NSRect(origin: .zero, size: card.fittingSize)
        header.view = card
        menu.addItem(header)

        guard let button = statusItem.button else { return }
        // The poll timer runs in the default mode and a menu keeps the run
        // loop in its tracking mode, so while the card is open it would show
        // the track as it was when the menu opened. It is polled on its own
        // meanwhile, and a little oftener: someone is looking at it.
        player.refresh()
        let poll = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.player.refresh() }
        }
        RunLoop.main.add(poll, forMode: .common)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
        poll.invalidate()
        if wantsSettings { showSettings() }
        if wantsSource { player.openSource() }
    }

    private func showSettings() {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Glass: a blur layer blending with whatever is behind the window,
        // with the interface laid over it. Built in AppKit rather than
        // wrapped for SwiftUI — a window background is the content view's
        // job, and going through NSViewRepresentable would only add a layer
        // that has already given trouble elsewhere in these apps.
        let backdrop = NSVisualEffectView()
        backdrop.material = .sidebar
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active

        let content = NSHostingView(rootView: SettingsView(settings: settings))
        content.autoresizingMask = [.width, .height]
        backdrop.addSubview(content)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: SettingsView.windowSize),
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
    @ObservedObject var settings: DisplaySettings
    let openSettings: () -> Void
    let openSource: () -> Void
    let resized: () -> Void

    private static let artworkSide: CGFloat = 100
    private static let compactArtworkSide: CGFloat = 44

    var body: some View {
        Group {
            if settings.compactCard { compact } else { full }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 320)
        .onChange(of: settings.compactCard) { _ in resized() }
    }

    private var full: some View {
        HStack(alignment: .center, spacing: 14) {
            artwork(side: Self.artworkSide)
                .overlay(alignment: .topLeading) {
                    SettingsBadge(action: openSettings).padding(5)
                }
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    MarqueeText(text: player.hasTrack ? player.title : "Not Playing",
                                font: .systemFont(ofSize: 14, weight: .semibold))
                    subtitleText.padding(.top, 1)
                }
                .modifier(Folds(settings: settings))
                Spacer(minLength: 4)
                transport
                Spacer(minLength: 4)
                ScrubBar(player: player)
            }
            .frame(height: Self.artworkSide)
        }
    }

    /// One row, the way Control Center shows the track before it is opened:
    /// a small cover, the title and artist cut short, play and skip.
    private var compact: some View {
        HStack(alignment: .center, spacing: 12) {
            artwork(side: Self.compactArtworkSide)
            VStack(alignment: .leading, spacing: 1) {
                Text(player.hasTrack ? player.title : "Not Playing")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                subtitleText
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(Folds(settings: settings))
            HStack(spacing: 0) {
                TransportButton(symbol: player.isPlaying ? "pause.fill" : "play.fill", size: 20,
                                width: 34) { player.togglePlayPause() }
                TransportButton(symbol: "forward.fill", size: 15, width: 34) { player.nextTrack() }
            }
            .disabled(!player.hasTrack)
        }
    }

    private func artwork(side: CGFloat) -> some View {
        ArtworkTile(image: player.artwork, side: side)
            .contentShape(Rectangle())
            .onTapGesture { if player.source != nil { openSource() } }
            .help(player.sourceName.map { "Open \($0)" } ?? "")
    }

    private var subtitleText: some View {
        Text(subtitle)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var subtitle: String {
        guard player.hasTrack else { return " " }
        let parts = [player.artist, player.album].filter { !$0.isEmpty }
        return parts.isEmpty ? " " : parts.joined(separator: " — ")
    }

    private var transport: some View {
        HStack(spacing: 0) {
            TransportButton(symbol: "backward.fill", size: 17) { player.previousTrack() }
            TransportButton(symbol: player.isPlaying ? "pause.fill" : "play.fill", size: 24) {
                player.togglePlayPause()
            }
            TransportButton(symbol: "forward.fill", size: 17) { player.nextTrack() }
        }
        .frame(maxWidth: .infinity)
        .disabled(!player.hasTrack)
    }
}

/// The way into Settings: a small gear on a dark disc over the corner of the
/// artwork, legible on a light cover and a dark one alike.
private struct SettingsBadge: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(hovering ? 1 : 0.85))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.black.opacity(hovering ? 0.6 : 0.42)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Settings")
    }
}

private struct ArtworkTile: View {
    let image: NSImage?
    let side: CGFloat

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.primary.opacity(0.08)
                Image(systemName: "music.note")
                    .font(.system(size: side * 0.34, weight: .regular))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.25), radius: 4, y: 1)
    }
}

/// Clicking the title folds the card to one row, or opens it out again.
private struct Folds: ViewModifier {
    @ObservedObject var settings: DisplaySettings

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture { settings.compactCard.toggle() }
    }
}

private struct TransportButton: View {
    let symbol: String
    let size: CGFloat
    var width: CGFloat = 52
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            // Styled on the image itself: a plain button in a menu draws its
            // label in the primary colour whatever it is given from outside.
            Image(systemName: symbol)
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(Color.primary.opacity(hovering && isEnabled ? 0.85 : 0.5))
                .frame(width: width, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.5)
        .onHover { hovering = $0 }
    }
}

/// The played part of the track over the rest of it, with the time gone and
/// the time left beneath. Dragging it moves the player.
private struct ScrubBar: View {
    @ObservedObject var player: NowPlayingModel
    /// Where the finger is while dragging; the bar follows it rather than
    /// the player until the player has been told.
    @State private var dragging: Double?

    var body: some View {
        // Redrawn twice a second while the menu is open, and not at all
        // otherwise: the view only exists while the menu does.
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let progress = player.progress
            let duration = progress?.duration ?? 0
            let elapsed = dragging.map { $0 * duration } ?? progress?.elapsed(at: context.date) ?? 0
            let fraction = duration > 0 ? elapsed / duration : 0
            VStack(spacing: 4) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.15))
                        Capsule().fill(Color.primary.opacity(0.55))
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
                            if let dragging, duration > 0 { player.seek(to: dragging * duration) }
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
private struct MarqueeText: View {
    let text: String
    let font: NSFont

    private static let gap: CGFloat = 32
    private static let speed: CGFloat = 30   // points per second
    private static let pause: Double = 2
    @State private var start = Date()

    private var width: CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    var body: some View {
        GeometryReader { geometry in
            let overflows = width > geometry.size.width
            TimelineView(.animation(paused: !overflows)) { context in
                let offset = overflows ? offset(at: context.date) : 0
                HStack(spacing: Self.gap) {
                    label
                    if overflows { label }
                }
                .fixedSize()
                .offset(x: offset)
                .frame(width: geometry.size.width, alignment: .leading)
                .clipped()
                .mask(fade(leading: offset < 0, trailing: overflows))
            }
        }
        .frame(height: ceil(font.ascender - font.descender + font.leading) + 1)
        .onChange(of: text) { _ in start = Date() }
    }

    private var label: some View {
        Text(text).font(Font(font)).lineLimit(1)
    }

    private func offset(at date: Date) -> CGFloat {
        let travel = width + Self.gap
        let cycle = Self.pause + Double(travel / Self.speed)
        let phase = date.timeIntervalSince(start).truncatingRemainder(dividingBy: cycle)
        return phase < Self.pause ? 0 : -CGFloat(phase - Self.pause) * Self.speed
    }

    /// A soft edge wherever the title runs on past it: at the end while it
    /// waits, at both ends while it moves.
    private func fade(leading: Bool, trailing: Bool) -> some View {
        LinearGradient(stops: [
            .init(color: leading ? .clear : .black, location: 0),
            .init(color: .black, location: 0.06),
            .init(color: .black, location: 0.94),
            .init(color: trailing ? .clear : .black, location: 1)
        ], startPoint: .leading, endPoint: .trailing)
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

    static let windowSize = CGSize(width: 420, height: 760)

    /// Scrolling and paging each use a different half of the Motion card.
    /// Rather than hide the rows that do not apply — which would make the
    /// card jump about as the mode changes — they are dimmed and disabled.
    private var scrolls: Bool { settings.displayMode == 1 }
    private var pages: Bool { settings.displayMode == 2 }

    var body: some View {
        VStack(spacing: 0) {
            // Drawn here rather than left to the window: the title bar is
            // transparent, so its own title would float above the content
            // instead of sitting inside it. The top padding clears the
            // traffic lights and puts the heading on their line.
            Text("Settings")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .frame(maxWidth: .infinity)
                .padding(.top, 13)
                .padding(.bottom, 12)

            VStack(alignment: .leading, spacing: 14) {
                SettingsCard("Display") {
                    SettingsRow("Mode", icon: "textformat.abc", tint: .blue) {
                        Picker("", selection: $settings.displayMode) {
                            Text("Static").tag(0)
                            Text("Scroll").tag(1)
                            Text("Pages").tag(2)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 190)
                    }
                    SettingsDivider()
                    SliderRow(title: "Width", icon: "arrow.left.and.right", tint: .cyan, value: $settings.width,
                              range: 100...360, format: "%.0f pt")
                    SettingsDivider()
                    SettingsRow("Alignment", icon: "text.alignleft", tint: .indigo) {
                        Picker("", selection: $settings.alignment) {
                            Text("Left").tag(0)
                            Text("Center").tag(1)
                            Text("Right").tag(2)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 190)
                    }
                }

                SettingsCard("Information") {
                    SettingsRow("Show artist", icon: "person.fill", tint: .pink) {
                        Toggle("", isOn: $settings.showsArtist).labelsHidden().toggleStyle(.switch)
                    }
                    SettingsDivider()
                    SettingsRow("Show album", icon: "square.stack.fill", tint: .orange) {
                        Toggle("", isOn: $settings.showsAlbum).labelsHidden().toggleStyle(.switch)
                    }
                    SettingsDivider()
                    SettingsRow("Show progress", icon: "chart.bar.fill", tint: .green) {
                        Toggle("", isOn: $settings.showsProgress).labelsHidden().toggleStyle(.switch)
                    }
                }

                SettingsCard("Type") {
                    SettingsRow("Typeface", icon: "textformat", tint: .purple) {
                        Picker("", selection: $settings.fontName) {
                            Text("System").tag("System")
                            Text("Condensed").tag("Condensed")
                            Text("Monospaced").tag("Monospaced")
                            Text("Rounded").tag("Rounded")
                        }
                        .labelsHidden()
                        .frame(width: 150)
                    }
                    SettingsDivider()
                    SliderRow(title: "Size", icon: "textformat.size", tint: .purple, value: $settings.fontSize,
                              range: 9...18, format: "%.0f pt")
                }

                SettingsCard("Motion") {
                    SettingsRow("Direction", icon: "arrow.left.arrow.right", tint: .teal) {
                        Picker("", selection: $settings.scrollDirection) {
                            Text("Left").tag(0)
                            Text("Right").tag(1)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 190)
                    }
                    .modifier(Applies(when: scrolls))
                    SettingsDivider()
                    SliderRow(title: "Scroll speed", icon: "hare.fill", tint: .teal, value: $settings.scrollSpeed,
                              range: 0.5...10, format: "%.1f ch/s")
                        .modifier(Applies(when: scrolls))
                    SettingsDivider()
                    SliderRow(title: "Page interval", icon: "timer", tint: .mint, value: $settings.pageInterval,
                              range: 1...10, format: "%.1f s")
                        .modifier(Applies(when: pages))
                }

                SettingsCard("Click") {
                    SettingsRow("Click", icon: "cursorarrow.click", tint: .red) {
                        Picker("", selection: $settings.clickOpensCard) {
                            Text("Play / Pause").tag(false)
                            Text("Open card").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 190)
                    }
                    SettingsDivider()
                    HStack {
                        Text(settings.clickOpensCard
                             ? "Two-finger click plays or pauses."
                             : "Two-finger click opens the card.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                }

            }
            .padding(.horizontal, 20)

            // The button belongs to the window rather than to the last card,
            // so it sits on the bottom edge instead of trailing the Motion
            // rows. Trailing the cards it also ran a few points past the
            // bottom of the window and lost its lower edge.
            Spacer(minLength: 20)

            HStack {
                // The menu has no rows any more, so the app is quit from here.
                Button("Quit Now Playing Menu") { NSApp.terminate(nil) }
                    .controlSize(.regular)
                    .fixedSize()
                Spacer()
                Button("Reset to Defaults") { settings.reset() }
                    .controlSize(.regular)
                    .buttonStyle(.borderedProminent)
                    // Its own width, never the squeezed one: the title is
                    // what decides how wide the button is.
                    .fixedSize()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
        }
        .frame(width: Self.windowSize.width, height: Self.windowSize.height)
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
    private let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
            VStack(spacing: 0) { content }
                // Translucent rather than filled: the card sits on the
                // window's blur and should let it through.
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.regularMaterial)
                        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
        }
    }
}

/// One row: a label at the leading edge, its control at the trailing one.
private struct SettingsRow<Control: View>: View {
    private let title: String
    private let icon: String
    private let tint: Color
    private let control: Control

    init(_ title: String, icon: String, tint: Color, @ViewBuilder control: () -> Control) {
        self.title = title
        self.icon = icon
        self.tint = tint
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 10) {
            // A filled squircle with a white glyph, the way System Settings
            // marks its rows.
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(LinearGradient(colors: [tint.opacity(0.85), tint],
                                             startPoint: .top, endPoint: .bottom))
                )
                .shadow(color: tint.opacity(0.3), radius: 1.5, y: 1)
            Text(title).font(.system(size: 13))
            Spacer(minLength: 8)
            control
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
    }
}

/// The hairline between rows, inset from the leading edge the way the system
/// insets its own so it reads as a break in one surface, not a border.
private struct SettingsDivider: View {
    var body: some View {
        Divider().opacity(0.45).padding(.leading, 42)
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
    let icon: String
    let tint: Color
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String

    var body: some View {
        SettingsRow(title, icon: icon, tint: tint) {
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
