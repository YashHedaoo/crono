import Foundation
import SwiftUI
import IOKit.ps
import AppKit

// MARK: - Upcoming Meeting Model

struct UpcomingMeeting: Sendable, Equatable {
    let title: String
    let startDate: Date
    let callURL: URL?

    var minutesRemaining: Int {
        let diff = startDate.timeIntervalSince(Date())
        return max(0, Int(ceil(diff / 60.0)))
    }

    var countdownLabel: String {
        let mins = minutesRemaining
        if mins <= 0 {
            return "Now"
        } else {
            return "in \(mins)m"
        }
    }
}

// MARK: - MacHealthManager

@MainActor
final class MacHealthManager: ObservableObject {
    static let shared = MacHealthManager()

    @Published var batteryPercentage: Int = 100
    @Published var isCharging: Bool = false
    @Published var isACPower: Bool = true
    @Published var thermalState: ProcessInfo.ThermalState = .nominal
    @Published var upcomingMeeting: UpcomingMeeting? = nil

    private var timer: Timer?

    var isLowBattery: Bool {
        batteryPercentage <= 20 && !isCharging
    }

    var batterySymbol: String {
        if isCharging {
            return "battery.100.bolt"
        }
        switch batteryPercentage {
        case 75...100: return "battery.100"
        case 50..<75:  return "battery.75"
        case 25..<50:  return "battery.50"
        case 10..<25:  return "battery.25"
        default:       return "battery.0"
        }
    }

    var thermalDescription: String {
        switch thermalState {
        case .nominal:  return "Cool"
        case .fair:     return "Warm"
        case .serious:  return "Hot"
        case .critical: return "Throttling"
        @unknown default: return "Normal"
        }
    }

    private init() {
        refreshBattery()
        refreshThermal()
        refreshUpcomingMeeting()
        startMonitoring()
    }

    func startMonitoring() {
        NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshThermal()
            }
        }

        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshBattery()
                self?.refreshUpcomingMeeting()
            }
        }
    }

    func refreshBattery() {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return
        }

        for ps in sources {
            guard let desc = IOPSGetPowerSourceDescription(snapshot, ps)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }

            if let current = desc[kIOPSCurrentCapacityKey] as? Int,
               let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 {
                self.batteryPercentage = Int((Double(current) / Double(max)) * 100.0)
            }
            if let state = desc[kIOPSPowerSourceStateKey] as? String {
                self.isACPower = (state == kIOPSACPowerValue)
            }
            if let charging = desc[kIOPSIsChargingKey] as? Bool {
                self.isCharging = charging
            }
        }
    }

    func refreshThermal() {
        self.thermalState = ProcessInfo.processInfo.thermalState
    }

    func refreshUpcomingMeeting() {
        let events = CalendarEventManager.shared.events
        let now = Date()
        let upcomingThreshold = now.addingTimeInterval(15 * 60) // within next 15 mins

        let candidate = events
            .filter { $0.date >= now.addingTimeInterval(-5 * 60) && $0.date <= upcomingThreshold }
            .sorted { $0.date < $1.date }
            .first

        if let candidate {
            let callURL = extractMeetingLink(notes: candidate.notes ?? "")
            self.upcomingMeeting = UpcomingMeeting(
                title: candidate.title,
                startDate: candidate.date,
                callURL: callURL
            )
        } else {
            self.upcomingMeeting = nil
        }
    }

    private func extractMeetingLink(notes: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let matches = detector?.matches(in: notes, range: NSRange(notes.startIndex..., in: notes)) ?? []

        for match in matches {
            guard let url = match.url else { continue }
            let host = url.host?.lowercased() ?? ""
            if host.contains("zoom.us") ||
               host.contains("meet.google.com") ||
               host.contains("teams.microsoft.com") ||
               host.contains("webex.com") {
                return url
            }
        }
        return nil
    }

    func joinMeeting() {
        guard let url = upcomingMeeting?.callURL else { return }
        NSWorkspace.shared.open(url)
    }
}
