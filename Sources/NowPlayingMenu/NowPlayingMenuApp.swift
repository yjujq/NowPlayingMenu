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
            DispatchQueue.main.async {
                self?.apply(info)
            }
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
        artwork = nil
        progress = Self.progress(from: info, playbackRate: playbackRate, hasTrack: hasTrack)
        schedulePolling()
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
    }

    func reset() {
        displayMode = 0; width = 167; fontName = "System"; fontSize = 13
        showsArtist = true; showsAlbum = false; showsProgress = true; alignment = 0
        scrollDirection = 0; scrollSpeed = 3; pageInterval = 2
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

@MainActor
private final class MarqueeStatusItem: NSObject {
    private let player: NowPlayingModel
    private let settings: DisplaySettings
    // A fixed width prevents the menu bar from shifting as track metadata changes.
    private let statusItem = NSStatusBar.system.statusItem(withLength: 167)

    /// The clear space between the end of the line and the copy of it that
    /// follows, so a loop does not read as one run-on sentence.
    private static let loopGap: CGFloat = 28
    /// How long the line takes to cross from light to dark and back.
    private static let themeFade: CFTimeInterval = 0.6
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
    private let lineLayer = CALayer()
    private let progressLayer = CALayer()

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
    private var progressAppearance: NSAppearance.Name?
    private var settingsWatch: AnyCancellable?
    /// The bar turning light or dark is answered at once, not on the next
    /// tick: half a second late, the fade would start from a blink.
    private var appearanceWatch: NSKeyValueObservation?
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
        button.layer?.addSublayer(lineLayer)
        progressLayer.anchorPoint = .zero
        progressLayer.actions = [
            "position": NSNull(), "bounds": NSNull(),
            "backgroundColor": NSNull(), "hidden": NSNull()
        ]
        progressLayer.isHidden = true
        button.layer?.addSublayer(progressLayer)

        rescheduleTimer()
        tick()

        // Settings is an observable object, so the display adapts the moment
        // a value changes rather than on the next tick. The notification
        // arrives BEFORE the new value is stored, so we read it one turn later.
        appearanceWatch = button.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.tick() }
        }

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

        if lineLayer.superlayer !== button.layer {
            button.wantsLayer = true
            button.layer?.masksToBounds = true
            button.layer?.addSublayer(lineLayer)
            button.layer?.addSublayer(progressLayer)
            shown = .nothing
            motion = nil
            installedProgress = nil
        }

        let scale = button.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let appearance = button.effectiveAppearance
        let font = settings.font()
        let text = player.displayText
        let sameLine = line?.text == text && line?.font == font && line?.scale == scale
        if !sameLine || line?.appearance != appearance.name {
            let themeOnly = sameLine && line != nil
            line = Line(text: text, font: font, gap: Self.loopGap, scale: scale,
                        color: Self.textColor(for: appearance), appearance: appearance.name)
            still = nil
            shown = .nothing
            if themeOnly {
                // The bar went light or dark — a change of space, of desktop
                // picture, of the system theme. The line is the same line in
                // another colour: it keeps its place in the loop and fades
                // across, the way the bar itself does, instead of blinking.
                let fade = CATransition()
                fade.type = .fade
                fade.duration = Self.themeFade
                lineLayer.add(fade, forKey: "theme")
            } else {
                motion = nil
                page = 0
                lastPageChange = .distantPast
            }
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
                .foregroundColor: Self.textColor(for: NSAppearance(named: line.appearance) ?? .currentDrawing()),
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
        if progressAppearance != appearance.name {
            // The line's own colour, so the rule belongs to the title above it
            // and not to the menu bar: it has to hold whatever the desktop
            // picture puts behind the bar, the way the title does.
            let color = Self.textColor(for: appearance).cgColor
            if progressAppearance != nil, !progressLayer.isHidden {
                let fade = CABasicAnimation(keyPath: "backgroundColor")
                fade.fromValue = progressLayer.backgroundColor
                fade.toValue = color
                fade.duration = Self.themeFade
                progressLayer.add(fade, forKey: "theme")
            }
            progressLayer.backgroundColor = color
            progressAppearance = appearance.name
        }
        progressLayer.isHidden = false
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

    /// The colour the menu bar draws its text in, resolved for the bar's own
    /// appearance.
    private static func textColor(for appearance: NSAppearance) -> NSColor {
        var color = NSColor.labelColor
        appearance.performAsCurrentDrawingAppearance {
            color = NSColor.labelColor.usingColorSpace(.sRGB) ?? .labelColor
        }
        return color
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
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            togglePlayback()
        }
    }

    private func togglePlayback() {
        if !MRBTogglePlayPause() {
            // Fallback for systems that don't expose the direct command symbol.
            postMediaKey(16, isKeyDown: true)
            postMediaKey(16, isKeyDown: false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.player.refresh()
        }
    }

    private func postMediaKey(_ key: Int, isKeyDown: Bool) {
        let state = isKeyDown ? 0xA : 0xB
        let flags = state << 8
        let data1 = (key << 16) | flags
        let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags)),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1
        )
        event?.cgEvent?.post(tap: .cghidEventTap)
    }

    /// The menu is left to AppKit to draw.
    ///
    /// It was drawn by the app for a while — a custom view for the header and
    /// one for every row — and a hand-drawn row does not follow the system:
    /// its insets, its highlight and its vibrancy are whatever was hardcoded
    /// here, and they drift from the menus beside it with every release of
    /// macOS. Standard items carrying symbols and shortcuts give the same
    /// shape and stay right.
    private func showMenu() {
        let menu = NSMenu()
        // The header carries no action; without this AppKit would grey it out.
        menu.autoenablesItems = false
        // The menu is popped up from the status button and would otherwise
        // inherit the button's appearance — which is the menu bar's, a
        // vibrant one that follows the desktop picture rather than the system
        // setting. That is right for the line drawn in the bar and wrong for
        // a menu: it left the menu light while the rest of macOS was dark.
        // A menu belongs to the app, so it takes the app's appearance.
        menu.appearance = NSApp.effectiveAppearance

        let header = NSMenuItem()
        header.attributedTitle = headerTitle()
        header.image = Self.menuSymbol(
            player.hasTrack ? (player.isPlaying ? "waveform" : "pause.fill") : "music.note"
        )
        menu.addItem(header)
        menu.addItem(.separator())

        addItem(to: menu, "Settings…", symbol: "slider.horizontal.3", key: ",",
                action: #selector(showSettings))
        addItem(to: menu, "Refresh", symbol: "arrow.clockwise", key: "r",
                action: #selector(refresh))
        // Quit belongs apart from the two commands that act on the display,
        // the way it sits apart in the system menus.
        menu.addItem(.separator())
        addItem(to: menu, "Quit", symbol: "power", key: "q", action: #selector(quit))

        guard let button = statusItem.button else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
    }

    private func addItem(to menu: NSMenu, _ title: String, symbol: String,
                         key: String, action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.image = Self.menuSymbol(symbol)
        menu.addItem(item)
    }

    /// The track at the top of the menu, on two lines: what is playing, and
    /// who by. A plain disabled line of text read as an error message rather
    /// than as the thing the app is about.
    private func headerTitle() -> NSAttributedString {
        let title = NSMutableAttributedString(
            string: player.hasTrack ? player.title : "Nothing playing",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize, weight: .semibold),
                .foregroundColor: NSColor.labelColor
            ]
        )
        guard let subtitle = menuSubtitle() else { return title }
        title.append(NSAttributedString(string: "\n" + subtitle, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor
        ]))
        return title
    }

    /// The second line of the header. It shows what the status item is not
    /// already showing: with the artist hidden in Settings the menu is the
    /// one place left to read it.
    private func menuSubtitle() -> String? {
        guard player.hasTrack else { return nil }
        let parts = [player.artist, player.album].filter { !$0.isEmpty }
        if !parts.isEmpty { return parts.joined(separator: settings.separator) }
        return player.isPlaying ? "Playing" : "Paused"
    }

    private static func menuSymbol(_ name: String) -> NSImage? {
        // A template, so the menu tints it for its own appearance and inverts
        // it on the highlighted row.
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
        image?.isTemplate = true
        return image
    }

    @objc private func refresh() { player.refresh() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func showSettings() {
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

/// The settings panel: a stack of grouped cards over the window's blur, the
/// shape System Settings has used since Ventura. It replaced a plain `Form`,
/// whose boxed sections and full-width controls read as a decade-old
/// preferences sheet next to the rest of the app.
///
/// The panel does not scroll. Every row is a fixed height, so the window is
/// sized to hold all of them at once and the whole of it stays in view.
private struct SettingsView: View {
    @ObservedObject var settings: DisplaySettings

    static let windowSize = CGSize(width: 400, height: 641)

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
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.top, 13)
                .padding(.bottom, 12)

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
                        .frame(width: 190)
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
                        .frame(width: 190)
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
                            Text("System").tag("System")
                            Text("Condensed").tag("Condensed")
                            Text("Monospaced").tag("Monospaced")
                            Text("Rounded").tag("Rounded")
                        }
                        .labelsHidden()
                        .frame(width: 150)
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
                        .frame(width: 190)
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

            }
            .padding(.horizontal, 20)

            // The button belongs to the window rather than to the last card,
            // so it sits on the bottom edge instead of trailing the Motion
            // rows. Trailing the cards it also ran a few points past the
            // bottom of the window and lost its lower edge.
            Spacer(minLength: 20)

            HStack {
                Spacer()
                Button("Reset to Defaults") { settings.reset() }
                    .controlSize(.regular)
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
