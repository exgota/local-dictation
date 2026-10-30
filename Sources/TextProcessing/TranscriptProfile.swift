import Foundation

/// Individually toggleable processing steps. Every step is opt-in.
public struct ProcessingOptions: Codable, Equatable, Sendable {
    public var vocabularyCorrections: Bool
    public var spokenPunctuation: Bool
    public var scratchThat: Bool
    public var fillerRemoval: Bool
    public var capitalizeFirst: Bool
    public var terminalPunctuation: Bool

    public init(
        vocabularyCorrections: Bool = false,
        spokenPunctuation: Bool = false,
        scratchThat: Bool = false,
        fillerRemoval: Bool = false,
        capitalizeFirst: Bool = false,
        terminalPunctuation: Bool = false
    ) {
        self.vocabularyCorrections = vocabularyCorrections
        self.spokenPunctuation = spokenPunctuation
        self.scratchThat = scratchThat
        self.fillerRemoval = fillerRemoval
        self.capitalizeFirst = capitalizeFirst
        self.terminalPunctuation = terminalPunctuation
    }
}

/// How dictated text is treated in a given kind of application.
public enum TranscriptProfile: String, Codable, CaseIterable, Sendable {
    /// Verbatim text; only vocabulary corrections, when enabled.
    case verbatim
    /// Conversational text: scratch that, spoken punctuation, filler removal, capitalization and terminal punctuation,
    /// plus vocabulary corrections when enabled. May submit with Return (see `submitsWithReturn`).
    case chat
    /// Verbatim text for terminals and editors; never submits with Return.
    case code
    /// Produces no text (password managers).
    case suppressed

    public var displayName: String {
        switch self {
        case .verbatim: return "Default"
        case .chat: return "Chat"
        case .code: return "Code/Terminal"
        case .suppressed: return "Suppressed"
        }
    }

    /// False only for `.suppressed`.
    public var producesText: Bool { self != .suppressed }

    /// The processing steps this profile enables by default.
    public func defaultOptions(vocabularyCorrectionsEnabled: Bool = true) -> ProcessingOptions {
        switch self {
        case .verbatim, .code:
            return ProcessingOptions(vocabularyCorrections: vocabularyCorrectionsEnabled)
        case .chat:
            return ProcessingOptions(
                vocabularyCorrections: vocabularyCorrectionsEnabled, spokenPunctuation: true, scratchThat: true,
                fillerRemoval: true, capitalizeFirst: true, terminalPunctuation: true)
        case .suppressed:
            return ProcessingOptions()
        }
    }

    /// Whether to press Return after inserting. Returns `userPreference` for `.chat` and false for every other
    /// profile, so `.code` never submits.
    public func submitsWithReturn(userPreference: Bool) -> Bool {
        self == .chat && userPreference
    }
}

/// Chooses a profile from the frontmost application's bundle identifier.
public struct ProfileResolver: Codable, Equatable, Sendable {
    /// Explicit per-application profiles; these win over built-in defaults.
    public var overrides: [String: TranscriptProfile]
    /// Profile for applications that are neither overridden nor built in.
    public var defaultProfile: TranscriptProfile

    public init(overrides: [String: TranscriptProfile] = [:], defaultProfile: TranscriptProfile = .verbatim) {
        self.overrides = overrides
        self.defaultProfile = defaultProfile
    }

    private enum CodingKeys: String, CodingKey { case overrides, defaultProfile }

    /// Lenient, for a hand-edited file. An unknown profile name drops only that override, and a missing or unknown
    /// default falls back to verbatim, instead of the whole block failing. If `overrides` is not an object whose values
    /// are all strings, or `defaultProfile` is not a string, that key counts as missing.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawOverrides = (try? container.decodeIfPresent([String: String].self, forKey: .overrides)) ?? nil
        overrides = (rawOverrides ?? [:]).compactMapValues(TranscriptProfile.init(rawValue:))
        let rawDefault = (try? container.decodeIfPresent(String.self, forKey: .defaultProfile)) ?? nil
        defaultProfile = rawDefault.flatMap(TranscriptProfile.init(rawValue:)) ?? .verbatim
    }

    public static let builtInProfiles: [String: TranscriptProfile] = {
        var profiles: [String: TranscriptProfile] = [:]
        let suppressed = [
            "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop", "com.apple.Passwords",
            "com.dashlane.Dashlane", "com.lastpass.LastPass", "org.keepassxc.keepassxc",
        ]
        let code = [
            "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
            "com.microsoft.VSCode", "com.apple.dt.Xcode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed",
        ]
        let chat = [
            "com.tinyspeck.slackmacgap", "com.hnc.Discord", "ru.keepcoder.Telegram", "net.whatsapp.WhatsApp",
            "com.apple.MobileSMS",
        ]
        for identifier in suppressed { profiles[identifier] = .suppressed }
        for identifier in code { profiles[identifier] = .code }
        for identifier in chat { profiles[identifier] = .chat }
        return profiles
    }()

    /// Resolves the profile for `bundleIdentifier` (compared ignoring case): overrides, built-ins, then the default.
    /// Returns the default profile when `bundleIdentifier` is nil.
    public func profile(forBundleIdentifier bundleIdentifier: String?) -> TranscriptProfile {
        guard let bundleIdentifier else { return defaultProfile }
        return Self.lookup(bundleIdentifier, in: overrides) ?? Self.lookup(bundleIdentifier, in: Self.builtInProfiles)
            ?? defaultProfile
    }

    private static func lookup(_ identifier: String, in profiles: [String: TranscriptProfile]) -> TranscriptProfile? {
        if let exact = profiles[identifier] { return exact }
        return profiles.first { $0.key.caseInsensitiveCompare(identifier) == .orderedSame }?.value
    }
}
