#if DEBUG || MOON_DIAGNOSTICS
import AppKit
import SwiftUI
import TextProcessing
import TranscriptHistory

/// Renders the production views without constructing recording, permission, model, or command services.
@MainActor enum InterfaceDiagnostics {
    static func render(directory: URL) throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixtureDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        let settings = DictationSettings(fileURL: fixtureDirectory.appendingPathComponent("settings.json"))
        settings.configuration.profiles.defaultProfile = .chat
        settings.configuration.vocabularyCorrectionsEnabled = true
        settings.configuration.keepsHistory = true
        settings.configuration.cueVolume = 0.55
        let pipeline = TranscriptPipeline(settings: settings)
        try capture(SettingsView(settings: settings), name: "settings", directory: directory)
        try capture(SettingsView(settings: settings, notices: .init(accessibilityOff: true)), name: "settings_accessibility", directory: directory)
        try capture(SettingsView(settings: settings, notices: .init(microphoneOff: true)), name: "settings_microphone", directory: directory)
        try capture(SettingsView(settings: settings, notices: .init(model: .notInstalled)), name: "settings_model_missing", directory: directory)
        try capture(SettingsView(settings: settings, notices: .init(model: .failed("Unavailable"))), name: "settings_model_failed", directory: directory)
        try capture(SettingsView(settings: settings, notices: .init(model: .installing(.downloading, fraction: 0.42))), name: "settings_downloading", directory: directory)
        try capture(SettingsView(settings: settings, notices: .init(accessibilityOff: true, microphoneOff: true, model: .installing(.downloading, fraction: 0.42))), name: "settings_all_notices", directory: directory)
        try capture(SettingsView(settings: settings, notices: .init(model: .installing(.validating, fraction: 0.92))), name: "settings_validating", directory: directory)
        try capture(SettingsView(settings: settings, notices: .init(model: .installing(.compiling, fraction: 0.97))), name: "settings_compiling", directory: directory)
        let vocabularyURL = fixtureDirectory.appendingPathComponent("vocabulary.json")
        try VocabularyCorrections(corrections: [
            .init(canonical: "Claude Code", mishearings: ["cloud code", "clawed code"]),
            .init(canonical: "Supabase", mishearings: ["super base"]),
            .init(canonical: "Codex", mishearings: ["codec"]),
            .init(canonical: "Wispr Flow", mishearings: ["whisper flow"]),
        ]).save(to: vocabularyURL)
        try capture(CorrectionsSheet(fileURL: vocabularyURL), name: "corrections", directory: directory)
        settings.configuration.profiles.overrides["com.google.Chrome"] = .verbatim
        settings.configuration.profiles.overrides["com.apple.Notes"] = .chat
        try capture(AppExceptionsSheet(settings: settings), name: "exceptions", directory: directory)
        try capture(AddCorrectionSheet(save: { _, _ in }, heard: "super base"), name: "add_correction", directory: directory)
        try capture(DictationKeyCaptureSheet(suspendShortcuts: { _ in }, finish: { _ in }), name: "key_capture", directory: directory)
        let entries = sampleEntries
        try capture(HistoryView(pipeline: pipeline, entries: entries, loadsArchive: false, selection: 1).frame(width: 660, height: 470), name: "history", title: "History", directory: directory)
        try capture(HistoryView(pipeline: pipeline, entries: entries, loadsArchive: false).frame(width: 660, height: 470), name: "history_no_selection", title: "History", directory: directory)
        try capture(HistoryView(pipeline: pipeline, loadsArchive: false).frame(width: 660, height: 470), name: "history_empty", title: "History", directory: directory)
        try renderMenu(directory: directory)
        for (name, icon) in [("plain", StatusItemIcon.normal), ("lock", StatusItemIcon.blocked)] {
            let view = NSImageView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
            view.image = icon.image
            view.imageScaling = .scaleNone
            view.contentTintColor = .labelColor
            try capture(view, name: "status_icon_" + name, directory: directory)
        }
        print("Rendered production interface views without starting application services.")
    }

    static func renderMenu(directory: URL) throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let states: [(String, StatusMenu.State)] = [
            ("menu", .init(canPaste: true, keepsHistory: true, opensAtLogin: true)),
            ("menu_empty", .init()),
            ("menu_recording", .init(recording: true, canPaste: true)),
            ("menu_update_available", .init(canPaste: true, keepsHistory: true, opensAtLogin: true, hasPendingUpdate: true)),
        ]
        for (name, state) in states {
            let menu = NSMenu()
            StatusMenu.populate(menu, state: state, target: nil)
            try capture(MenuDiagnosticView(menu: menu), name: name, directory: directory)
        }
        try "Production NSMenu model with AppKit text and separators, dark at 2x. Tracking and compositor vibrancy need a desktop check.\n"
            .write(to: directory.appendingPathComponent("render.txt"), atomically: true, encoding: .utf8)
    }

    static func renderMoveAlert(directory: URL) throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let alert = ApplicationRelocation.makeMoveAlert()
        // The unbundled diagnostics executable borrows the icon of the most recent build.
        if FileManager.default.fileExists(atPath: "dist/Local Dictation.app") {
            alert.icon = NSWorkspace.shared.icon(forFile: "dist/Local Dictation.app")
        }
        alert.window.appearance = NSAppearance(named: .darkAqua)
        alert.layout()
        alert.window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        guard let frame = alert.window.contentView?.superview else { throw CocoaError(.fileWriteUnknown) }
        try capture(frame, name: "move-to-applications", directory: directory)
        try "The production NSAlert frame view, dark at 2x. The alert was not shown and no application was moved or relaunched.\n"
            .write(to: directory.appendingPathComponent("render.txt"), atomically: true, encoding: .utf8)
    }

    private static func capture<Content: View>(_ view: Content, name: String, title: String = "Local Dictation Settings", directory: URL) throws {
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.title = title
        window.appearance = NSAppearance(named: .darkAqua)
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        guard let frame = window.contentView?.superview else { throw CocoaError(.fileWriteUnknown) }
        try capture(frame, name: name, directory: directory)
    }

    private static func capture(_ view: NSView, name: String, directory: URL) throws {
        view.appearance = NSAppearance(named: .darkAqua)
        view.layoutSubtreeIfNeeded()
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(view.bounds.width * 2), pixelsHigh: Int(view.bounds.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { throw CocoaError(.fileWriteUnknown) }
        bitmap.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: directory.appendingPathComponent(name + ".png"))
        print("\(name): \(bitmap.pixelsWide) × \(bitmap.pixelsHigh)")
    }

    private static var sampleEntries: [TranscriptHistoryEntry] {
        let samples = [
            ("2026-11-02T21:41:00-05:00", "T3 Code", "Can you move the standup to Thursday at ten, and send the notes from Monday to everyone who missed it? Also check whether the room is free, and if it isn’t, book the small one on the third floor and put the link in the invite so people can join remotely."),
            ("2026-11-02T21:12:00-05:00", "Google Chrome", "Thanks, that works for me. Let’s lock it in for next week."),
            ("2026-11-02T18:03:00-05:00", "Messages", "On my way, be there in ten."),
            ("2026-11-01T16:20:00-05:00", "Claude", "Rewrite the onboarding copy so it reads in plain words."),
            ("2026-11-01T11:02:00-05:00", "Slack", "Pushed the fix, can you take a look when you get a sec?"),
        ]
        return samples.enumerated().map { index, sample in
            TranscriptHistoryEntry(identifier: Int64(index + 1), timestamp: ISO8601DateFormatter().date(from: sample.0)!, durationSeconds: 10,
                                   rawText: sample.2, finalText: sample.2, applicationName: sample.1)
        }
    }
}

/// The real menu model, using AppKit text and separators offscreen. Tracking and vibrancy require a desktop session.
@MainActor private final class MenuDiagnosticView: NSView {
    private let sourceMenu: NSMenu
    override var isFlipped: Bool { true }
    init(menu: NSMenu) {
        self.sourceMenu = menu
        let height = menu.items.reduce(CGFloat(12)) { $0 + ($1.isSeparatorItem ? 12 : 24) }
        super.init(frame: NSRect(x: 0, y: 0, width: 268, height: height))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        var top: CGFloat = 6
        for item in sourceMenu.items {
            let height: CGFloat = item.isSeparatorItem ? 12 : 24
            let frame = NSRect(x: 8, y: top, width: 252, height: height)
            if item.isSeparatorItem {
                let cell = NSMenuItemCell(textCell: "")
                cell.menuItem = item
                cell.drawSeparatorItem(withFrame: frame, in: self)
            } else {
                let color = item.isEnabled ? NSColor.labelColor : NSColor.disabledControlTextColor
                let title = NSMutableAttributedString(attributedString: item.attributedTitle ?? NSAttributedString(string: item.title))
                title.addAttributes([.font: NSFont.menuFont(ofSize: 13), .foregroundColor: color], range: NSRange(location: 0, length: title.length))
                title.draw(in: NSRect(x: 24, y: top + 4, width: 226, height: 19))
                if item.state == .on {
                    NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
                        .withSymbolConfiguration(.init(paletteColors: [.labelColor]))?.draw(in: NSRect(x: 8, y: top + 6, width: 12, height: 12))
                }
                if !item.keyEquivalent.isEmpty {
                    let modifiers = item.keyEquivalentModifierMask
                    let legend = (modifiers.contains(.control) ? "⌃" : "") + (modifiers.contains(.option) ? "⌥" : "")
                        + (modifiers.contains(.shift) ? "⇧" : "") + (modifiers.contains(.command) ? "⌘" : "")
                        + item.keyEquivalent.uppercased()
                    let paragraph = NSMutableParagraphStyle()
                    paragraph.alignment = .right
                    NSAttributedString(string: legend, attributes: [.font: NSFont.menuFont(ofSize: 13), .foregroundColor: color, .paragraphStyle: paragraph])
                        .draw(in: NSRect(x: 206, y: top + 4, width: 42, height: 19))
                }
            }
            top += height
        }
    }
}
#endif
