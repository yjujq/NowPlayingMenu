import AppKit
import ApplicationServices

/// Разовая проверка: отдаёт ли Пункт управления название трека через
/// Accessibility. Если да — сведения можно получать без запуска osascript.
///
/// Включается ключом: defaults write com.yjujq.nowplayingmenu probeControlCentre -bool true
enum ControlCentreProbe {
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "probeControlCentre")
    }

    private static func log(_ text: String) {
        FileHandle.standardError.write(Data(("ПРОВЕРКА: " + text + "\n").utf8))
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    static func run() {
        let options = ["AXTrustedCheckOptionPrompt": true]
        guard AXIsProcessTrustedWithOptions(options as CFDictionary) else {
            log("доступ к Accessibility не выдан — разрешите его и перезапустите")
            return
        }

        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.controlcenter"
        }) else {
            log("процесс Пункта управления не найден")
            return
        }

        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 1.0)

        guard let barRef = attribute(element, "AXMenuBar") else {
            log("строка меню недоступна")
            return
        }
        let bar = barRef as! AXUIElement
        guard let items = attribute(bar, kAXChildrenAttribute as String) as? [AXUIElement] else {
            log("элементы строки меню недоступны")
            return
        }

        log("элементов в строке меню: \(items.count)")
        for (index, item) in items.enumerated() {
            var parts: [String] = []
            for key in [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute,
                        kAXValueAttribute, kAXIdentifierAttribute] as [String] {
                if let text = attribute(item, key) as? String, !text.isEmpty {
                    parts.append("\(key)=\(text)")
                }
            }
            log("  [\(index)] " + (parts.isEmpty ? "без текстовых свойств" : parts.joined(separator: " | ")))
        }
    }
}
