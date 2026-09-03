import SwiftUI
import AppKit
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

    var displayText: String {
        guard isPlaying else { return "Nothing playing" }
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

    /// Каждый опрос запускает отдельный процесс osascript — это недёшево.
    /// Пока ничего не играет, спрашивать часто незачем.
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
        title = newTitle.isEmpty ? "Nothing playing" : newTitle
        artist = info["artist"] as? String ?? ""
        album = info["album"] as? String ?? ""
        artwork = nil
        schedulePolling()
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
        alignment = defaults.object(forKey: "alignment") as? Int ?? 0
        scrollDirection = defaults.object(forKey: "scrollDirection") as? Int ?? 0
        scrollSpeed = defaults.object(forKey: "scrollSpeed") as? Double ?? 3
        pageInterval = defaults.object(forKey: "pageInterval") as? Double ?? 2
    }

    func reset() {
        displayMode = 0; width = 167; fontName = "System"; fontSize = 13
        showsArtist = true; showsAlbum = false; alignment = 0
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
            // Читаем до ожидания завершения: иначе полный буфер трубы
            // остановит дочерний процесс, и мы застрянем оба.
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let errorData = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                report("сценарий завершился с кодом \(process.terminationStatus)", errorData)
                return [:]
            }
            guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                report("не удалось разобрать ответ сценария", data)
                return [:]
            }
            return parsed
        } catch {
            report("сценарий не запустился: \(error.localizedDescription)", nil)
            return [:]
        }
    }

    /// Об ошибках сообщаем вслух. Молчаливый возврат пустого словаря делал
    /// сломанный сценарий неотличимым от «ничего не играет», и поломку
    /// невозможно было заметить.
    private static var lastReport = ""
    private static func report(_ message: String, _ detail: Data?) {
        let text = String(data: detail ?? Data(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let full = text.isEmpty ? message : "\(message): \(text)"
        guard full != lastReport else { return }   // не сорим повтором каждые пять секунд
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
    private var lastText = ""
    private var offset = 0
    private var page = 0
    private var lastMotion = Date.distantPast
    private var timer: Timer?

    // Что уже отрисовано. Раньше эти свойства задавались заново на каждом
    // проходе — семь раз в секунду, вечно, даже когда ничего не менялось.
    private var idleApplied = false
    private var appliedTitle = ""
    private var appliedFont: NSFont?
    private var appliedAlignment: NSTextAlignment?

    /// Значок простоя строится один раз. Его пересоздание из системного
    /// символа на каждом проходе и было основным расходом процессора.
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
        button.lineBreakMode = .byTruncatingTail
        button.font = settings.font()

        timer = Timer.scheduledTimer(timeInterval: 0.15, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        tick()
    }

    @objc private func tick() {
        guard let button = statusItem.button else { return }

        // Шрифт и выравнивание задаются только в настройках, поэтому трогаем
        // их при изменении, а не на каждом проходе.
        let alignment: NSTextAlignment = [.left, .center, .right][min(max(settings.alignment, 0), 2)]
        if appliedAlignment != alignment {
            button.alignment = alignment
            appliedAlignment = alignment
        }
        let font = settings.font()
        if appliedFont != font {
            button.font = font
            appliedFont = font
            appliedTitle = ""            // оформление изменилось — перерисовать
        }

        guard player.isPlaying else {
            // Простой рисуем один раз и дальше ничего не делаем.
            if !idleApplied {
                statusItem.length = NSStatusItem.squareLength
                lastText = ""
                appliedTitle = ""
                button.title = ""
                button.attributedTitle = NSAttributedString(string: "")
                button.image = Self.idleImage
                button.imagePosition = .imageOnly
                idleApplied = true
            }
            return
        }
        idleApplied = false

        statusItem.length = CGFloat(settings.width)
        button.image = nil
        button.imagePosition = .noImage
        let text = player.displayText
        if text != lastText { lastText = text; offset = 0; page = 0; lastMotion = .distantPast }

        let visibleCharacters = max(8, Int(settings.width / max(settings.fontSize * 0.58, 1)))
        let characters = Array(text)
        let shownText: String
        switch settings.displayMode {
        case 1: // Scroll
            let interval = 1 / max(settings.scrollSpeed, 0.5)
            if Date().timeIntervalSince(lastMotion) >= interval {
                let delta = settings.scrollDirection == 0 ? 1 : -1
                offset = (offset + delta + max(characters.count, 1)) % max(characters.count, 1)
                lastMotion = Date()
            }
            let looped = characters + Array("     ") + characters
            let start = min(offset, max(looped.count - 1, 0))
            shownText = String(looped[start..<min(start + visibleCharacters, looped.count)])
        case 2: // Pages
            let pageCount = max(Int(ceil(Double(characters.count) / Double(visibleCharacters))), 1)
            // Ширина и размер шрифта меняются в настройках, а номер страницы
            // сбрасывался только при смене трека: на широкой полосе старый
            // номер выходил за длину строки и обрушивал приложение.
            if page >= pageCount { page = 0 }
            if Date().timeIntervalSince(lastMotion) >= settings.pageInterval {
                page = (page + 1) % pageCount
                lastMotion = Date()
            }
            let start = min(page * visibleCharacters, max(characters.count - 1, 0))
            shownText = String(characters[start..<min(start + visibleCharacters, characters.count)])
        default:
            shownText = text
        }

        if shownText != appliedTitle {
            button.attributedTitle = NSAttributedString(string: shownText, attributes: [.font: font])
            appliedTitle = shownText
        }
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

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: player.displayText, action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Refresh", action: #selector(refresh), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q").target = self
        guard let button = statusItem.button else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
    }

    @objc private func refresh() { player.refresh() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func showSettings() {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let content = NSHostingView(rootView: SettingsView(settings: settings))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.center()
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct SettingsView: View {
    @ObservedObject var settings: DisplaySettings

    var body: some View {
        Form {
            Section("Display") {
                Picker("Mode", selection: $settings.displayMode) {
                    Text("Static").tag(0)
                    Text("Scroll").tag(1)
                    Text("Pages").tag(2)
                }
                .pickerStyle(.segmented)

                SliderRow(title: "Width", value: $settings.width, range: 100...360, format: "%.0f pt")
                Picker("Alignment", selection: $settings.alignment) {
                    Text("Left").tag(0); Text("Center").tag(1); Text("Right").tag(2)
                }
                .pickerStyle(.segmented)
            }

            Section("Information") {
                Toggle("Show artist", isOn: $settings.showsArtist)
                Toggle("Show album", isOn: $settings.showsAlbum)
            }

            Section("Font") {
                Picker("Typeface", selection: $settings.fontName) {
                    Text("System").tag("System")
                    Text("Condensed").tag("Condensed")
                    Text("Monospaced").tag("Monospaced")
                    Text("Rounded").tag("Rounded")
                }
                SliderRow(title: "Size", value: $settings.fontSize, range: 9...18, format: "%.0f pt")
            }

            Section("Motion") {
                Picker("Direction", selection: $settings.scrollDirection) {
                    Text("Left").tag(0); Text("Right").tag(1)
                }
                .pickerStyle(.segmented)
                SliderRow(title: "Scroll speed", value: $settings.scrollSpeed, range: 0.5...10, format: "%.1f chars/s")
                SliderRow(title: "Page interval", value: $settings.pageInterval, range: 1...10, format: "%.1f s")
            }

            HStack {
                Spacer()
                Button("Reset to Defaults") { settings.reset() }
            }
        }
        .padding(20)
        .frame(width: 430, height: 520)
    }
}

private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String

    var body: some View {
        HStack {
            Text(title)
            Slider(value: $value, in: range)
            Text(String(format: format, value)).frame(width: 76, alignment: .trailing)
        }
    }
}
