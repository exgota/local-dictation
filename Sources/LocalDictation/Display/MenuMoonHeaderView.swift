import AppKit
import MoonRendering

@MainActor final class MenuMoonHeaderView: NSView {
    private let heading = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let coin = NSImageView(frame: NSRect(x: 9, y: 7, width: 30, height: 30))

    init(title: String, subtitle: String, phase: MenuMoonPhase) {
        super.init(frame: NSRect(x: 0, y: 0, width: 252, height: 43))
        coin.imageScaling = .scaleNone
        coin.setAccessibilityElement(false)
        heading.frame = NSRect(x: 48, y: 23, width: 195, height: 17)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        detail.frame = NSRect(x: 48, y: 8, width: 195, height: 15)
        detail.font = .systemFont(ofSize: 11.5)
        detail.textColor = .secondaryLabelColor
        heading.lineBreakMode = .byTruncatingTail
        detail.lineBreakMode = .byTruncatingTail
        addSubview(coin)
        addSubview(heading)
        addSubview(detail)
        update(title: title, subtitle: subtitle, phase: phase)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func update(title: String, subtitle: String, phase: MenuMoonPhase) {
        if let image = try? phase.bitmap().image() {
            coin.image = NSImage(cgImage: image, size: NSSize(width: 30, height: 30))
        }
        heading.stringValue = title
        detail.stringValue = subtitle
        detail.isHidden = subtitle.isEmpty
        // One line of state gets a shorter header, so the coin and title sit centered above the separator.
        setFrameSize(NSSize(width: frame.width, height: subtitle.isEmpty ? 32 : 43))
        coin.frame.origin.y = subtitle.isEmpty ? -3 : 7
        heading.frame.origin.y = subtitle.isEmpty ? 6 : 23
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(subtitle.isEmpty ? title : title + ". " + subtitle)
        toolTip = subtitle.isEmpty ? title : title + ". " + subtitle
    }
}
