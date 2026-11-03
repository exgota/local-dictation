import AppKit

/// Secure input keeps the menu available even when setup also needs attention.
@MainActor enum StatusItemIcon {
    case normal, error, blocked

    init(needsSetup: Bool, secureInputBlocked: Bool) {
        self = secureInputBlocked ? .blocked : (needsSetup ? .error : .normal)
    }

    var opensSetup: Bool { self == .error }

    var image: NSImage? {
        switch self {
        case .normal: Self.waveform
        case .error: Self.setupWarning
        case .blocked: Self.lockBadge
        }
    }

    private static let waveform = symbol("waveform", size: 14)
    private static let setupWarning: NSImage? = {
        let image = NSImage(systemSymbolName: "waveform.badge.exclamationmark", accessibilityDescription: "Local Dictation")
        image?.isTemplate = true
        return image
    }()

    private static let lockBadge: NSImage? = {
        guard let wave = waveform, let lock = symbol("lock.fill", size: 8, weight: .bold) else { return nil }
        let size = NSSize(width: wave.size.width + 3, height: wave.size.height + 1)
        let badge = NSImage(size: size, flipped: false) { _ in
            wave.draw(in: NSRect(x: 0, y: 1, width: wave.size.width, height: wave.size.height))
            let lockRect = NSRect(x: size.width - lock.size.width, y: 0, width: lock.size.width, height: lock.size.height)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(roundedRect: lockRect.insetBy(dx: -1.5, dy: -1.5), xRadius: 3, yRadius: 3).fill()
            NSGraphicsContext.restoreGraphicsState()
            lock.draw(in: lockRect)
            return true
        }
        badge.isTemplate = true
        badge.accessibilityDescription = "Local Dictation, shortcuts blocked"
        return badge
    }()

    private static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSImage? {
        guard let configured = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight)) else { return nil }
        let image = NSImage(size: configured.size, flipped: false) { rect in
            configured.draw(in: rect)
            NSColor.white.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Local Dictation"
        return image
    }
}
