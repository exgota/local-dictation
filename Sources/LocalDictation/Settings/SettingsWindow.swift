import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The spacing scale and sizes that the settings views share.
enum SettingsLayout {
    static let windowPadding: CGFloat = 20
    static let sectionSpacing: CGFloat = 24
    static let rowSpacing: CGFloat = 12
    static let labelControlGap: CGFloat = 8
    static let captionGap: CGFloat = 4
    static let standardWidth: CGFloat = 480
    static let textWidth: CGFloat = 520
    static let historyWidth: CGFloat = 560
    static let minimumRowHeight: CGFloat = 24
}

enum SettingsTab: String, CaseIterable {
    case general, hotkey, audio, text, history, about

    var title: String {
        switch self {
        case .general: return "General"
        case .hotkey: return "Hotkey"
        case .audio: return "Audio"
        case .text: return "Text"
        case .history: return "History"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .hotkey: return "keyboard"
        case .audio: return "mic"
        case .text: return "text.alignleft"
        case .history: return "clock.arrow.circlepath"
        case .about: return "info.circle"
        }
    }
}

/// Everything the settings views read and change.
@MainActor struct SettingsContext {
    let settings: DictationSettings
    let permissions: PermissionMonitor
    let model: ModelController
    let controller: DictationController
}

/// A standard macOS preferences window: toolbar tabs, each sized to its content, resizing as tabs change.
@MainActor final class SettingsWindowController: NSWindowController {
    private let tabController = NSTabViewController()

    init(context: SettingsContext) {
        tabController.tabStyle = .toolbar
        tabController.transitionOptions = [.allowUserInteraction]
        for tab in SettingsTab.allCases {
            let hosting = NSHostingController(rootView: AnyView(Self.view(for: tab, context: context)))
            hosting.sizingOptions = [.preferredContentSize]
            hosting.title = tab.title
            let item = NSTabViewItem(viewController: hosting)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            item.identifier = tab.rawValue
            tabController.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabController)
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.title = SettingsTab.general.title
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ tab: SettingsTab? = nil) {
        if let tab, let index = SettingsTab.allCases.firstIndex(of: tab) { tabController.selectedTabViewItemIndex = index }
        if window?.isVisible != true, let window {
            let screen = NSScreen.screenWithMouse()
            let frame = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: frame.midX - window.frame.width / 2, y: frame.maxY - window.frame.height - 120))
        }
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private static func view(for tab: SettingsTab, context: SettingsContext) -> any View {
        switch tab {
        case .general: return GeneralSettingsView(context: context)
        case .hotkey: return HotkeySettingsView(context: context)
        case .audio: return AudioSettingsView(context: context)
        case .text: return TextSettingsView(context: context)
        case .history: return HistorySettingsView(context: context)
        case .about: return AboutSettingsView(context: context)
        }
    }
}

// MARK: Layout components

/// A settings page: banners, then one grid so labels and controls line up across all sections.
struct SettingsPage<Content: View>: View {
    let width: CGFloat
    var context: SettingsContext? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
            if let context { CommonBannersView(context: context) }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: SettingsLayout.labelControlGap, verticalSpacing: SettingsLayout.rowSpacing) {
                content
            }
        }
        .padding(SettingsLayout.windowPadding)
        .frame(width: width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Observes the sources of the banners shared by the settings pages.
private struct CommonBannersView: View {
    let context: SettingsContext
    @ObservedObject private var settings: DictationSettings
    @ObservedObject private var permissions: PermissionMonitor
    @ObservedObject private var secureInput: SecureInputMonitor

    init(context: SettingsContext) {
        self.context = context
        settings = context.settings
        permissions = context.permissions
        secureInput = context.controller.secureInput
    }

    var body: some View {
        ForEach(commonBanners(context)) { InlineBanner(content: $0) }
    }
}

/// A section title spanning both columns. Every section after the first adds 12 pt to the 12 pt row spacing, for 24.
struct SectionHeader: View {
    let title: String
    var isFirst = false

    var body: some View {
        GridRow {
            Text(title).font(.headline).gridCellColumns(2)
        }
        .padding(.top, isFirst ? 0 : SettingsLayout.sectionSpacing - SettingsLayout.rowSpacing)
    }
}

/// A row: a left-aligned label column and a left-aligned control column, with an optional caption under the control.
struct SettingsRow<Control: View>: View {
    let label: String
    var caption: String?
    @ViewBuilder let control: Control

    var body: some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label).gridColumnAlignment(.leading)
            VStack(alignment: .leading, spacing: SettingsLayout.captionGap) {
                control.frame(minHeight: SettingsLayout.minimumRowHeight)
                if let caption {
                    Text(caption).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .gridColumnAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A symbol and a word: the status of a permission or component.
struct StatusIndicator: View {
    let isOK: Bool
    let okText: String
    let problemText: String

    var body: some View {
        HStack(spacing: SettingsLayout.labelControlGap) {
            Image(systemName: isOK ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(isOK ? Color.accentColor : Color.secondary)
            Text(isOK ? okText : problemText)
        }
    }
}

/// An inline banner at the top of a page for a condition that needs the user, instead of an alert.
struct InlineBanner: View {
    struct Content: Identifiable {
        let id: String
        let message: String
        var actionTitle: String?
        var action: (() -> Void)?
    }

    let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: SettingsLayout.labelControlGap) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.accentColor)
            Text(content.message).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let title = content.actionTitle, let action = content.action {
                Button(title, action: action).controlSize(.large)
            }
        }
        .padding(SettingsLayout.rowSpacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Banners shared by every page except About: permissions, installation, settings file and secure input.
@MainActor func commonBanners(_ context: SettingsContext) -> [InlineBanner.Content] {
    var banners: [InlineBanner.Content] = []
    if !context.permissions.allGranted {
        banners.append(InlineBanner.Content(
            id: "permissions", message: "Dictation needs Microphone and Accessibility access.", actionTitle: "Open setup",
            action: { context.controller.onRequiresAttention() }))
    }
    for (index, warning) in InstallationCheck.current().warnings.enumerated() {
        banners.append(InlineBanner.Content(id: "installation-\(index)", message: warning))
    }
    if let error = context.settings.lastFileError {
        banners.append(InlineBanner.Content(id: "settings-file", message: error))
    }
    if let holder = context.controller.secureInput.holder {
        banners.append(InlineBanner.Content(
            id: "secure-input", message: "Hotkeys paused: \(holder.applicationName) is holding secure input."))
    }
    return banners
}

/// Opens a file in the user's default text editor. JSON files otherwise open in whatever claims `.json`, often a browser.
enum TextEditorLauncher {
    @MainActor static func open(_ url: URL) {
        let editor = NSWorkspace.shared.urlForApplication(toOpen: .plainText)
            ?? URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
    }
}
