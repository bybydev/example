import Foundation
import Observation

// Issue #56 adds unlimited listening alongside paid voices and themes.
nonisolated enum ReadAloudProFeature: String, Sendable {
    case advancedVoices
    case premiumThemes

    var title: String {
        switch self {
        case .advancedVoices: "All Voices"
        case .premiumThemes: "Premium Themes"
        }
    }
}

nonisolated enum ReadAloudAccessError: Error, LocalizedError, Equatable, Sendable {
    case requiresPro(ReadAloudProFeature)

    var errorDescription: String? {
        switch self {
        case .requiresPro(let feature):
            "\(feature.title) requires ReadAloud Pro."
        }
    }
}

nonisolated enum ReadAloudAccessPolicy {
    static let weeklyListeningSeconds: TimeInterval = 3 * 60 * 60
    static let freeVoiceIDs: Set<String> = ["af_heart"]

    static func canUseVoice(_ voiceID: String, hasPro: Bool) -> Bool {
        SpeechVoice.all.contains(where: { $0.id == voiceID })
            && (hasPro || freeVoiceIDs.contains(voiceID))
    }

    static func requirePro(_ feature: ReadAloudProFeature, hasPro: Bool) throws {
        guard hasPro else {
            throw ReadAloudAccessError.requiresPro(feature)
        }
    }

    static func effectiveVoiceID(_ requestedVoiceID: String, hasPro: Bool) -> String {
        canUseVoice(requestedVoiceID, hasPro: hasPro)
            ? requestedVoiceID
            : ReadAloudNarrationCatalog.freeDefaultVoiceID
    }
}

/// Device-wide usage belongs outside .readaloud packages: removing a book or
/// rebuilding its audio must never replenish the week's allowance.
@Observable
@MainActor
final class ReadAloudListeningAllowance {
    private nonisolated struct Ledger: Codable {
        var weekStart: Date
        var usedSeconds: TimeInterval
    }

    @ObservationIgnored private let defaults: UserDefaults
    private static let ledgerKey = "readaloud.listening-allowance.v1"
    @ObservationIgnored private var lastSave = Date.distantPast
    private var ledger: Ledger

    init(defaults: UserDefaults = .standard, now: Date = .now) {
        self.defaults = defaults
        let start = Self.weekStart(containing: now)
        if let data = defaults.data(forKey: Self.ledgerKey) {
            if let saved = try? JSONDecoder().decode(Ledger.self, from: data),
               saved.usedSeconds.isFinite, saved.usedSeconds >= 0,
               saved.weekStart.timeIntervalSince1970.isFinite,
               saved.weekStart == Self.weekStart(containing: saved.weekStart) {
                ledger = saved
            } else {
                // A damaged ledger must not silently replenish paid usage.
                ledger = Ledger(weekStart: start,
                                usedSeconds: ReadAloudAccessPolicy.weeklyListeningSeconds)
            }
        } else {
            ledger = Ledger(weekStart: start, usedSeconds: 0)
        }
        refresh(now: now)
    }

    nonisolated static func weekStart(containing date: Date) -> Date {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.dateInterval(of: .weekOfYear, for: date)!.start
    }

    func resetDate(at now: Date = .now) -> Date {
        max(ledger.weekStart, Self.weekStart(containing: now))
            .addingTimeInterval(7 * 24 * 60 * 60)
    }

    func usedSeconds(at now: Date = .now) -> TimeInterval {
        Self.weekStart(containing: now) > ledger.weekStart ? 0 : ledger.usedSeconds
    }

    func isExhausted(at now: Date = .now) -> Bool {
        usedSeconds(at: now) >= ReadAloudAccessPolicy.weeklyListeningSeconds
    }

    func refresh(now: Date = .now) {
        let start = Self.weekStart(containing: now)
        // Moving the clock backwards must not open a fresh allowance.
        guard start > ledger.weekStart else { return }
        ledger = Ledger(weekStart: start, usedSeconds: 0)
        persist(now: now)
    }

    func record(seconds: TimeInterval, isPro: Bool, now: Date = .now) {
        guard seconds.isFinite, seconds > 0 else { return }
        refresh(now: now)
        guard !isPro else { return }
        // At rollover only the part rendered in the new week belongs to it.
        let currentWeekSeconds = now < ledger.weekStart ? seconds
            : min(seconds, now.timeIntervalSince(ledger.weekStart))
        ledger.usedSeconds = min(ReadAloudAccessPolicy.weeklyListeningSeconds,
                                 ledger.usedSeconds + currentWeekSeconds)
        if now.timeIntervalSince(lastSave) >= 5 || isExhausted(at: now) {
            persist(now: now)
        }
    }

    func persist(now: Date = .now) {
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        defaults.set(data, forKey: Self.ledgerKey)
        lastSave = now
    }

    func usageDescription(at now: Date = .now) -> String {
        let minutes = Int(usedSeconds(at: now) / 60)
        let used = minutes < 60 ? "\(minutes) min"
            : "\(minutes / 60) hr \(minutes % 60) min"
        let hours = Int(ReadAloudAccessPolicy.weeklyListeningSeconds / 3600)
        return "\(used) of \(hours) hours used this week"
    }
}

