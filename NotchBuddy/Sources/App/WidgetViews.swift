import SwiftUI
import Combine
import EventKit


// MARK: - Shared formatting

enum WidgetFormat {
    static func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    static func clockWithSeconds(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }

    static func clockInZone(_ zone: TimeZone, _ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = zone
        return f.string(from: d)
    }

    static func fullDate(_ d: Date) -> String {
        d.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }

    static func countdown(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded()))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                     : String(format: "%02d:%02d", m, sec)
    }

    static func stopwatch(_ t: TimeInterval) -> String {
        let tt = max(0, t)
        let m = Int(tt) / 60, s = Int(tt) % 60, tenth = Int((tt - floor(tt)) * 10)
        return String(format: "%02d:%02d.%d", m, s, tenth)
    }

    static func dayOfMonth(_ d: Date = Date()) -> String {
        d.formatted(.dateTime.day())
    }

    static func monthTitle(_ d: Date) -> String {
        d.formatted(.dateTime.month(.wide).year())
    }
}

// MARK: - World clock cities

struct WorldCity: Identifiable {
    let name: String
    let timeZone: TimeZone
    var id: String { name }

    static let all: [WorldCity] = [
        WorldCity(name: "New York", timeZone: TimeZone(identifier: "America/New_York")!),
        WorldCity(name: "London",   timeZone: TimeZone(identifier: "Europe/London")!),
        WorldCity(name: "Dubai",    timeZone: TimeZone(identifier: "Asia/Dubai")!),
        WorldCity(name: "Tokyo",    timeZone: TimeZone(identifier: "Asia/Tokyo")!),
        WorldCity(name: "Sydney",   timeZone: TimeZone(identifier: "Australia/Sydney")!),
    ]
}

// MARK: - Timer (countdown)

@MainActor
final class TimerModel: ObservableObject {
    static let shared = TimerModel()

    @Published var duration: TimeInterval = 5 * 60
    @Published private(set) var remaining: TimeInterval = 5 * 60
    @Published private(set) var isRunning = false
    @Published private(set) var endDate: Date?

    private var ticker: Timer?

    private init() {}

    var isActive: Bool { isRunning || remaining < duration }

    func setDuration(_ seconds: TimeInterval) {
        stopTicker()
        duration = max(1, seconds)
        remaining = duration
        endDate = nil
        isRunning = false
    }

    func start() {
        guard !isRunning, remaining > 0 else { return }
        endDate = Date().addingTimeInterval(remaining)
        isRunning = true
        startTicker()
    }

    func pause() {
        guard isRunning else { return }
        remaining = max(0, (endDate?.timeIntervalSinceNow) ?? remaining)
        endDate = nil
        isRunning = false
        stopTicker()
    }

    func reset() {
        stopTicker()
        remaining = duration
        endDate = nil
        isRunning = false
    }

    func currentRemaining(at now: Date = Date()) -> TimeInterval {
        guard isRunning, let end = endDate else { return remaining }
        return max(0, end.timeIntervalSince(now))
    }

    private func startTicker() {
        stopTicker()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.tick() }
        }
    }

    private func tick() {
        guard isRunning else { return }
        let r = currentRemaining()
        if r <= 0 {
            remaining = 0
            endDate = nil
            isRunning = false
            stopTicker()
            SoundEngine.shared.play("finish")
        } else {
            remaining = r
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }
}

// MARK: - Stopwatch

@MainActor
final class StopwatchModel: ObservableObject {
    static let shared = StopwatchModel()

    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var isRunning = false
    @Published private(set) var laps: [TimeInterval] = []

    private var startDate: Date?
    private var ticker: Timer?

    private init() {}

    var currentElapsed: TimeInterval {
        guard isRunning, let start = startDate else { return elapsed }
        return elapsed + Date().timeIntervalSince(start)
    }

    func start() {
        guard !isRunning else { return }
        startDate = Date()
        isRunning = true
        startTicker()
    }

    func pause() {
        guard isRunning else { return }
        elapsed = currentElapsed
        startDate = nil
        isRunning = false
        stopTicker()
    }

    func reset() {
        stopTicker()
        elapsed = 0
        startDate = nil
        isRunning = false
        laps = []
    }

    func lap() {
        guard isRunning else { return }
        laps.insert(currentElapsed, at: 0)
        if laps.count > 4 { laps.removeLast() }
    }

    private func startTicker() {
        stopTicker()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.elapsed = self.currentElapsed }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }
}

// MARK: - Widget pill (right-card grid)

struct WidgetPill: View {
    let task: AgentTask
    @ObservedObject var state: AppState
    @Binding var swapping: Bool
    let onTap: () -> Void

    @ObservedObject private var timerModel = TimerModel.shared
    @ObservedObject private var stopwatchModel = StopwatchModel.shared
    @State private var isHovered = false

    private var symbol: String {
        switch task.id {
        case "widget_clock":      return "clock"
        case "widget_worldclock": return "globe"
        case "widget_timer":      return "timer"
        case "widget_stopwatch":  return "stopwatch"
        case "widget_calendar":   return "calendar"
        default:                  return "square.grid.2x2"
        }
    }

    var body: some View {
        Button(action: onTap) {
            ZStack {
                Capsule()
                    .fill(isHovered ? Color(hex: task.color).opacity(0.18) : Color(hex: "#0E0F11"))
                Capsule()
                    .stroke(Color(hex: task.color).opacity(isHovered ? 0.55 : 0.14), lineWidth: 1)
                HStack(spacing: 5) {
                    Image(systemName: symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color(hex: task.color))
                        .frame(width: 13)
                    Text(task.name)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(isHovered
                                         ? Color(hex: task.color).lighter(by: 0.3)
                                         : Color(hex: "#6B7079"))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 2)
                    valueView
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundColor(isHovered
                                         ? Color(hex: task.color).lighter(by: 0.3)
                                         : Color(hex: "#8E939C"))
                }
                .padding(.leading, 9)
                .padding(.trailing, 8)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .shadow(color: Color(hex: task.color).opacity(isHovered ? 0.35 : 0), radius: 10, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.04 : 1.0)
        .brightness(isHovered ? 0.06 : 0)
        .onHover { newHover in
            guard !swapping else { return }
            withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) { isHovered = newHover }
        }
    }

    @ViewBuilder private var valueView: some View {
        switch task.id {
        case "widget_clock":
            TimelineView(.periodic(from: .now, by: 1)) { tl in
                Text(WidgetFormat.clock(tl.date))
            }
        case "widget_worldclock":
            TimelineView(.periodic(from: .now, by: 1)) { tl in
                Text(WidgetFormat.clockInZone(WorldCity.all[0].timeZone, tl.date))
            }
        case "widget_timer":
            Text(timerModel.isActive
                 ? WidgetFormat.countdown(timerModel.currentRemaining())
                 : WidgetFormat.countdown(timerModel.duration))
        case "widget_stopwatch":
            Text(stopwatchModel.isRunning || stopwatchModel.elapsed > 0
                 ? WidgetFormat.stopwatch(stopwatchModel.currentElapsed)
                 : "00:00.0")
        case "widget_calendar":
            Text(WidgetFormat.dayOfMonth())
        default:
            Text(task.name)
        }
    }
}

// MARK: - Widget card (focused, left card)

struct WidgetCardView: View {
    let task: AgentTask

    var body: some View {
        switch task.id {
        case "widget_clock":      ClockCardView(task: task)
        case "widget_worldclock": WorldClockCardView(task: task)
        case "widget_timer":      TimerCardView(task: task)
        case "widget_stopwatch":  StopwatchCardView(task: task)
        case "widget_calendar":   CalendarCardView(task: task)
        case "widget_nowplaying": NowPlayingCardView(task: task)
        case "widget_battery":    MacHealthCardView(task: task)
        default:                  EmptyView()
        }
    }
}

struct WidgetCardHeader: View {
    let task: AgentTask
    var overrideTitle: String? = nil
    var overrideColor: String? = nil
    var overrideSubtitle: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color(hex: overrideColor ?? task.color))
                .frame(width: 7, height: 7)
            Text(overrideTitle ?? task.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color(hex: "#F5F6F8"))
            Text(overrideSubtitle ?? "Widget")
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#8E939C"))
            Spacer(minLength: 2)
        }
        .padding(.top, 6)
    }
}

struct WidgetControlButton: View {
    let title: String
    let color: String
    let icon: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(isHovered ? Color(hex: color).lighter(by: 0.3) : Color(hex: "#F5F6F8"))
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(isHovered ? Color(hex: color).opacity(0.22) : Color.white.opacity(0.08))
            .clipShape(Capsule())
            .overlay(
                Capsule().stroke(Color(hex: color).opacity(isHovered ? 0.55 : 0.16), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.04 : 1.0)
        .onHover { h in
            withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) { isHovered = h }
        }
    }
}

// MARK: - Clock

struct ClockCardView: View {
    let task: AgentTask

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { tl in
            VStack(alignment: .leading, spacing: 4) {
                WidgetCardHeader(task: task)
                Text(WidgetFormat.clockWithSeconds(tl.date))
                    .font(.system(size: 40, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(Color(hex: "#F5F6F8"))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 8)
                Text(WidgetFormat.fullDate(tl.date))
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: "#8E939C"))
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(.leading, 108)
            .padding(.trailing, 16)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - World clocks

struct WorldClockCardView: View {
    let task: AgentTask

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { tl in
            VStack(alignment: .leading, spacing: 6) {
                WidgetCardHeader(task: task)
                worldRow(name: "Your city",
                         time: WidgetFormat.clock(tl.date),
                         zone: TimeZone.current, tl: tl.date)
                ForEach(WorldCity.all) { city in
                    worldRow(name: city.name,
                             time: WidgetFormat.clockInZone(city.timeZone, tl.date),
                             zone: city.timeZone, tl: tl.date)
                }
            }
            .padding(.leading, 108)
            .padding(.trailing, 16)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func worldRow(name: String, time: String, zone: TimeZone, tl: Date) -> some View {
        HStack(spacing: 6) {
            Text(name)
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#8E939C"))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Text(time)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundColor(Color(hex: "#F5F6F8"))
            Text(abbreviation(for: zone, at: tl))
                .font(.system(size: 10))
                .foregroundColor(Color(hex: "#6B7079"))
                .frame(width: 24, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }

    private func abbreviation(for zone: TimeZone, at date: Date) -> String {
        let a = zone.abbreviation(for: date) ?? "—"
        return String(a.prefix(3))
    }
}

// MARK: - Timer (countdown) card

struct TimerCardView: View {
    let task: AgentTask
    @ObservedObject private var model = TimerModel.shared

    private static let presets: [TimeInterval] = [60, 180, 300, 600, 1500]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { tl in
            let remaining = model.currentRemaining(at: tl.date)
            let progress = model.duration > 0
                ? min(1, max(0, 1 - remaining / model.duration))
                : 0

            VStack(alignment: .leading, spacing: 6) {
                WidgetCardHeader(task: task)
                Text(WidgetFormat.countdown(remaining))
                    .font(.system(size: 38, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(model.isRunning ? Color(hex: "#F5F6F8") : Color(hex: "#D5D7DB"))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 4)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.08))
                        Capsule()
                            .fill(Color(hex: task.color))
                            .frame(width: max(0, geo.size.width * progress))
                    }
                }
                .frame(height: 4)
                .padding(.horizontal, 24)

                HStack(spacing: 5) {
                    ForEach(Self.presets, id: \.self) { p in
                        let selected = model.duration == p
                            && !model.isActive
                            && model.remaining == p
                        Button {
                            model.setDuration(p)
                            SoundEngine.shared.play("blip")
                        } label: {
                            Text(Self.presetLabel(p))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(selected
                                                 ? Color(hex: "#F5F6F8")
                                                 : Color(hex: "#8E939C"))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(selected
                                            ? Color(hex: task.color).opacity(0.35)
                                            : Color.white.opacity(0.07))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)

                HStack(spacing: 10) {
                    if model.isRunning {
                        WidgetControlButton(title: "Pause", color: task.color,
                                            icon: "pause.fill") {
                            model.pause()
                            SoundEngine.shared.play("blip")
                        }
                    } else {
                        WidgetControlButton(title: "Start", color: task.color,
                                            icon: "play.fill") {
                            model.start()
                            SoundEngine.shared.play("blip")
                        }
                    }
                    WidgetControlButton(title: "Reset", color: task.color,
                                        icon: "arrow.counterclockwise") {
                        model.reset()
                        SoundEngine.shared.play("blip")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 2)
            }
            .padding(.leading, AppState.shared.mochiOnDesktop ? 16 : 108)
            .padding(.trailing, 16)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private static func presetLabel(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        return m < 60 ? "\(m)m" : "\(m / 60)h"
    }
}

// MARK: - Stopwatch card

struct StopwatchCardView: View {
    let task: AgentTask
    @ObservedObject private var model = StopwatchModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WidgetCardHeader(task: task)
            Text(WidgetFormat.stopwatch(model.currentElapsed))
                .font(.system(size: 38, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(model.isRunning ? Color(hex: "#F5F6F8") : Color(hex: "#D5D7DB"))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 4)

            HStack(spacing: 8) {
                if model.isRunning {
                    WidgetControlButton(title: "Pause", color: task.color,
                                        icon: "pause.fill") { model.pause() }
                } else {
                    WidgetControlButton(title: "Start", color: task.color,
                                        icon: "play.fill") { model.start() }
                }
                WidgetControlButton(title: "Lap", color: task.color,
                                    icon: "flag.fill") {
                    model.lap()
                    SoundEngine.shared.play("blip")
                }
                WidgetControlButton(title: "Reset", color: task.color,
                                    icon: "arrow.counterclockwise") { model.reset() }
            }
            .frame(maxWidth: .infinity, alignment: .center)

            if !model.laps.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.laps.enumerated()), id: \.offset) { idx, lap in
                        HStack(spacing: 6) {
                            Text("#\(model.laps.count - idx)")
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundColor(Color(hex: "#6B7079"))
                            Spacer()
                            Text(WidgetFormat.stopwatch(lap))
                                .font(.system(size: 11, weight: .medium).monospacedDigit())
                                .foregroundColor(Color(hex: "#F5F6F8"))
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(.leading, AppState.shared.mochiOnDesktop ? 16 : 108)
        .padding(.trailing, 16)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Calendar card

// MARK: - Calendar Event Model & Persistence

public struct CalendarEventItem: Identifiable, Codable, Sendable {
    public var id = UUID()
    public var title: String
    public var date: Date
    public var timeString: String
    public var notes: String?
    public var urlString: String?

    public init(id: UUID = UUID(), title: String, date: Date, timeString: String = "", notes: String? = nil, urlString: String? = nil) {
        self.id = id
        self.title = title
        self.date = date
        self.timeString = timeString
        self.notes = notes
        self.urlString = urlString
    }
}

@MainActor
public class CalendarEventManager: ObservableObject {
    public static let shared = CalendarEventManager()

    @Published public var events: [CalendarEventItem] = [] {
        didSet { save() }
    }

    private let storageKey = "Chrono_CalendarEvents_v1"
    private let eventStore = EKEventStore()

    public init() {
        load()
    }

    public func events(for date: Date) -> [CalendarEventItem] {
        let cal = Calendar.current
        return events.filter { cal.isDate($0.date, inSameDayAs: date) }
    }

    public func hasEvents(for date: Date) -> Bool {
        let cal = Calendar.current
        return events.contains { cal.isDate($0.date, inSameDayAs: date) }
    }

    public func addEvent(title: String, date: Date, time: String = "") {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        events.append(CalendarEventItem(title: trimmed, date: date, timeString: time))
        syncToSystemCalendar(title: trimmed, date: date, timeString: time)
    }

    public func removeEvent(id: UUID) {
        events.removeAll { $0.id == id }
    }

    // MARK: - Sync to macOS System Calendar
    public func syncToSystemCalendar(title: String, date: Date, timeString: String = "") {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                let granted: Bool
                if #available(macOS 14.0, *) {
                    granted = try await self.eventStore.requestFullAccessToEvents()
                } else {
                    granted = try await self.eventStore.requestAccess(to: .event)
                }

                guard granted else { return }

                let ekEvent = EKEvent(eventStore: self.eventStore)
                ekEvent.title = title

                let cal = Calendar.current
                var comps = cal.dateComponents([.year, .month, .day], from: date)

                if let (hour, minute) = self.parseTimeString(timeString) {
                    comps.hour = hour
                    comps.minute = minute
                    comps.second = 0
                    let start = cal.date(from: comps) ?? date
                    ekEvent.startDate = start
                    ekEvent.endDate = start.addingTimeInterval(3600)
                    ekEvent.isAllDay = false
                } else {
                    comps.hour = 9
                    comps.minute = 0
                    comps.second = 0
                    let start = cal.date(from: comps) ?? date
                    ekEvent.startDate = start
                    ekEvent.endDate = start.addingTimeInterval(3600)
                    ekEvent.isAllDay = timeString.trimmingCharacters(in: .whitespaces).isEmpty
                }

                ekEvent.calendar = self.eventStore.defaultCalendarForNewEvents
                try self.eventStore.save(ekEvent, span: .thisEvent, commit: true)
            } catch {
                print("Failed to save to macOS Calendar: \(error)")
            }
        }
    }

    private func parseTimeString(_ str: String) -> (Int, Int)? {
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }

        let formats = ["h:mm a", "hh:mm a", "h a", "ha", "HH:mm", "H:mm", "h:mma", "hh:mma"]
        for fmt in formats {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = fmt
            if let d = df.date(from: trimmed) {
                let comps = Calendar.current.dateComponents([.hour, .minute], from: d)
                if let h = comps.hour, let m = comps.minute {
                    return (h, m)
                }
            }
        }
        return nil
    }

    private func save() {
        if let data = try? JSONEncoder().encode(events) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([CalendarEventItem].self, from: data) {
            self.events = decoded
        }
    }
}

// MARK: - Calendar Event Popover

struct CalendarEventPopoverView: View {
    let date: Date
    let taskColor: String
    @ObservedObject var eventManager = CalendarEventManager.shared
    @Binding var isPresented: Bool

    @State private var newTitle: String = ""
    @State private var newTime: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(date.formatted(.dateTime.weekday(.wide).month().day()))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Color(hex: "#F5F6F8"))
                Spacer()
                Button {
                    if let url = URL(string: "calshow:\(date.timeIntervalSinceReferenceDate)") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "#8E939C"))
                }
                .buttonStyle(.plain)
                .help("Open in Apple Calendar")
            }

            Divider()

            let dayEvents = eventManager.events(for: date)
            if !dayEvents.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(dayEvents) { item in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color(hex: taskColor))
                                .frame(width: 6, height: 6)
                            Text(item.title)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(Color(hex: "#F5F6F8"))
                                .lineLimit(1)
                            if !item.timeString.isEmpty {
                                Text(item.timeString)
                                    .font(.system(size: 10))
                                    .foregroundColor(Color(hex: "#8E939C"))
                            }
                            Spacer()
                            Button {
                                eventManager.removeEvent(id: item.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundColor(Color(hex: "#8E939C"))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 100)
            } else {
                Text("No events for this day")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#8E939C"))
            }

            Divider()

            VStack(spacing: 6) {
                TextField("Add event title...", text: $newTitle)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))

                HStack {
                    TextField("Time (e.g. 2:00 PM)", text: $newTime)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))

                    Button("Add") {
                        eventManager.addEvent(title: newTitle, date: date, time: newTime)
                        newTitle = ""
                        newTime = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(12)
        .frame(width: 250)
        .background(Color(hex: "#1A1D24"))
    }
}

struct CalendarCardView: View {
    let task: AgentTask
    @State private var monthOffset = 0
    @ObservedObject private var eventManager = CalendarEventManager.shared
    @State private var selectedDateForEvent: Date? = nil

    private var displayedMonth: Date {
        Calendar.current.date(byAdding: .month, value: monthOffset, to: Date()) ?? Date()
    }

    private var weekdayLetters: [String] {
        let cal = Calendar.current
        let syms = cal.veryShortStandaloneWeekdaySymbols
        let first = cal.firstWeekday - 1
        return (0..<7).map { syms[(first + $0) % 7] }
    }

    var body: some View {
        let cal = Calendar.current
        let monthDate = displayedMonth
        let comps = cal.dateComponents([.year, .month], from: monthDate)
        let firstOfMonth = cal.date(from: comps) ?? monthDate
        let daysInMonth = cal.range(of: .day, in: .month, for: firstOfMonth)?.count ?? 30
        let firstWeekday = cal.component(.weekday, from: firstOfMonth) - cal.firstWeekday
        let leading = ((firstWeekday % 7) + 7) % 7
        let today = cal.component(.day, from: Date())
        let isCurrentMonth = monthOffset == 0

        VStack(alignment: .leading, spacing: 2) {
            WidgetCardHeader(task: task)

            HStack(spacing: 6) {
                Button { withAnimation { monthOffset -= 1 } } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(Color(hex: "#8E939C"))
                }
                .buttonStyle(.plain)
                Text(WidgetFormat.monthTitle(monthDate))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(hex: "#F5F6F8"))
                Button { withAnimation { monthOffset += 1 } } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(Color(hex: "#8E939C"))
                }
                .buttonStyle(.plain)
                Spacer()
                if monthOffset != 0 {
                    Button("Today") { withAnimation { monthOffset = 0 } }
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(Color(hex: task.color).opacity(0.85))
                        .buttonStyle(.plain)
                }
            }
            .padding(.top, 1)

            HStack(spacing: 2) {
                ForEach(weekdayLetters, id: \.self) { letter in
                    Text(letter)
                        .font(.system(size: 8))
                        .foregroundColor(Color(hex: "#6B7079"))
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 1) {
                ForEach(0..<(leading + daysInMonth), id: \.self) { idx in
                    let day = idx - leading + 1
                    if day < 1 {
                        Color.clear
                            .frame(height: 17)
                    } else {
                        let isToday = isCurrentMonth && day == today
                        let dayDate: Date = {
                            var dc = comps
                            dc.day = day
                            return cal.date(from: dc) ?? monthDate
                        }()
                        let hasEvents = eventManager.hasEvents(for: dayDate)

                        Button {
                            selectedDateForEvent = dayDate
                        } label: {
                            VStack(spacing: 0.5) {
                                Text("\(day)")
                                    .font(.system(size: 9.5, weight: isToday ? .bold : .regular).monospacedDigit())
                                    .foregroundColor(isToday
                                                     ? Color.black
                                                     : (idx % 7 == 0 || idx % 7 == 6
                                                        ? Color(hex: "#8E939C")
                                                        : Color(hex: "#F5F6F8")))
                                    .frame(width: 17, height: 14)
                                    .background(isToday ? Color(hex: task.color) : Color.clear)
                                    .clipShape(Circle())

                                // Dot indicator for dates with events
                                Circle()
                                    .fill(hasEvents ? Color(hex: task.color) : Color.clear)
                                    .frame(width: 2.5, height: 2.5)
                            }
                            .frame(height: 17)
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: Binding(
                            get: { selectedDateForEvent != nil && cal.isDate(selectedDateForEvent!, inSameDayAs: dayDate) },
                            set: { if !$0 { selectedDateForEvent = nil } }
                        ), arrowEdge: .bottom) {
                            CalendarEventPopoverView(
                                date: dayDate,
                                taskColor: task.color,
                                isPresented: Binding(
                                    get: { selectedDateForEvent != nil },
                                    set: { if !$0 { selectedDateForEvent = nil } }
                                )
                            )
                        }
                    }
                }
            }
            .padding(.top, 1)
        }
        .padding(.leading, 106)
        .padding(.trailing, 14)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Rotating Vinyl CD Record View

struct RotatingVinylRecordView: View {
    let isPlaying: Bool
    let thumbnailUrl: String?
    let playerColor: String
    let playerIcon: String
    var discSize: CGFloat = 48

    var body: some View {
        TimelineView(.animation(paused: !isPlaying)) { timeline in
            let angle = isPlaying
                ? (timeline.date.timeIntervalSinceReferenceDate * 45).truncatingRemainder(dividingBy: 360)
                : 0.0

            ZStack {
                // Outer Vinyl Black Disc
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(hex: "#222226"),
                                Color(hex: "#111114"),
                                Color(hex: "#050507"),
                                Color(hex: "#010102")
                            ],
                            center: .center,
                            startRadius: discSize * 0.15,
                            endRadius: discSize * 0.5
                        )
                    )
                    .frame(width: discSize, height: discSize)
                    .shadow(color: Color.black.opacity(0.6), radius: 4, x: 0, y: 1.5)

                // Vinyl sound grooves (concentric micro-rings)
                Circle()
                    .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.8)
                    .frame(width: discSize * 0.88, height: discSize * 0.88)
                Circle()
                    .strokeBorder(Color.white.opacity(0.04), lineWidth: 0.7)
                    .frame(width: discSize * 0.76, height: discSize * 0.76)
                Circle()
                    .strokeBorder(Color.white.opacity(0.05), lineWidth: 0.8)
                    .frame(width: discSize * 0.64, height: discSize * 0.64)
                Circle()
                    .strokeBorder(Color.white.opacity(0.03), lineWidth: 0.6)
                    .frame(width: discSize * 0.52, height: discSize * 0.52)

                // Glossy specular reflection sheen (two opposing light flares)
                Circle()
                    .fill(
                        AngularGradient(
                            colors: [
                                Color.white.opacity(0.18),
                                Color.clear,
                                Color.white.opacity(0.14),
                                Color.clear,
                                Color.white.opacity(0.18),
                                Color.clear
                            ],
                            center: .center
                        )
                    )
                    .frame(width: discSize, height: discSize)
                    .blendMode(.screen)

                // Center label circle (like the red center on a vinyl LP)
                let labelSize = discSize * 0.44
                ZStack {
                    if let urlStr = thumbnailUrl, let url = URL(string: urlStr) {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: labelSize, height: labelSize)
                                    .clipShape(Circle())
                            default:
                                fallbackCenterLabel(size: labelSize)
                            }
                        }
                        .frame(width: labelSize, height: labelSize)
                        .clipShape(Circle())
                    } else {
                        fallbackCenterLabel(size: labelSize)
                    }

                    // Inner border ring around the center label
                    Circle()
                        .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
                        .frame(width: labelSize, height: labelSize)

                    // Center Spindle Hole with metallic rim
                    Circle()
                        .fill(Color(hex: "#050507"))
                        .frame(width: discSize * 0.09, height: discSize * 0.09)
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.4), lineWidth: 0.8)
                        )
                }
                .frame(width: labelSize, height: labelSize)
            }
            .rotationEffect(.degrees(angle))
            .animation(.linear(duration: 0.05), value: angle)
        }
        .frame(width: discSize, height: discSize)
    }

    private func fallbackCenterLabel(size: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(hex: playerColor),
                            Color(hex: playerColor).opacity(0.85)
                        ],
                        center: .center,
                        startRadius: 1,
                        endRadius: size / 2
                    )
                )
            Image(systemName: playerIcon)
                .font(.system(size: size * 0.38, weight: .bold))
                .foregroundColor(.white)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Now Playing Card View (Widget)

struct NowPlayingCardView: View {
    let task: AgentTask
    @ObservedObject private var manager = NowPlayingManager.shared
    @ObservedObject private var appState = AppState.shared

    var body: some View {
        let isMochiFloating = appState.mochiOnDesktop

        VStack(alignment: .leading, spacing: 3) {
            WidgetCardHeader(
                task: task,
                overrideTitle: manager.isPlaying ? "Now Playing" : "Paused",
                overrideColor: manager.isPlaying ? manager.playerColor : "#6B7079",
                overrideSubtitle: manager.player.isEmpty ? "Media Player" : manager.player
            )

            HStack(alignment: .center, spacing: 8) {
                // 1. Spinning Vinyl Record / CD with Thumbnail in Center
                RotatingVinylRecordView(
                    isPlaying: manager.isPlaying,
                    thumbnailUrl: manager.thumbnailUrl,
                    playerColor: manager.playerColor,
                    playerIcon: manager.playerIcon,
                    discSize: isMochiFloating ? 48 : 38
                )

                // 2. Track / Video Title, Artist, and Source Badge
                VStack(alignment: .leading, spacing: 1.5) {
                    Text(manager.title.isEmpty ? "Ready to Play" : manager.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(Color(hex: "#F5F6F8"))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if !manager.artist.isEmpty && manager.artist != manager.player {
                        Text(manager.artist)
                            .font(.system(size: 9.5))
                            .foregroundColor(Color(hex: "#8E939C"))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    HStack(spacing: 4) {
                        if !manager.player.isEmpty {
                            HStack(spacing: 3) {
                                if manager.player == "YouTube" {
                                    Image(systemName: "play.rectangle.fill")
                                        .font(.system(size: 6.5))
                                } else if manager.player == "Spotify" {
                                    Image(systemName: "waveform")
                                        .font(.system(size: 6.5))
                                } else {
                                    Image(systemName: "music.note")
                                        .font(.system(size: 6.5))
                                }

                                Text(manager.player)
                                    .font(.system(size: 8, weight: .semibold))
                                    .lineLimit(1)
                            }
                            .foregroundColor(Color(hex: manager.playerColor))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1.5)
                            .background(Color(hex: manager.playerColor).opacity(0.16))
                            .cornerRadius(3)
                            .fixedSize()
                        }

                        if manager.isPlaying {
                            AudioEqualizerBars(isPlaying: true, tintColor: Color(hex: manager.playerColor))
                                .fixedSize()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // 3. Playback Controls (Prev, Play/Pause, Next)
                HStack(spacing: 5) {
                    Button {
                        manager.previousTrack()
                        SoundEngine.shared.play("blip")
                    } label: {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 9))
                            .foregroundColor(Color(hex: "#8E939C"))
                            .frame(width: 22, height: 22)
                            .background(Color.white.opacity(0.06))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Previous / Replay")

                    // Primary Play / Pause Button
                    Button {
                        manager.togglePlayPause()
                        SoundEngine.shared.play(manager.isPlaying ? "tick" : "pop")
                    } label: {
                        ZStack {
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [Color(hex: manager.playerColor), Color(hex: manager.playerColor).opacity(0.85)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .frame(width: 26, height: 26)
                                .shadow(color: Color(hex: manager.playerColor).opacity(0.4), radius: 4, x: 0, y: 1)

                            Image(systemName: manager.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 10.5, weight: .bold))
                                .foregroundColor(manager.player == "YouTube" ? .white : .black)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(manager.isPlaying ? "Pause" : "Play")

                    Button {
                        manager.nextTrack()
                        SoundEngine.shared.play("blip")
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 9))
                            .foregroundColor(Color(hex: "#8E939C"))
                            .frame(width: 22, height: 22)
                            .background(Color.white.opacity(0.06))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Next / Skip")
                }
                .fixedSize()
            }
            .padding(.top, 1)
        }
        .padding(.leading, isMochiFloating ? 14 : 106)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
        .frame(width: 322, alignment: .topLeading)
        .clipped()
    }
}

// MARK: - Animated Equalizer Bars

struct AudioEqualizerBars: View {
    let isPlaying: Bool
    var tintColor: Color = Color(hex: "#10B981")

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.12)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    let phase = Double(i) * 1.3
                    let heightFactor = isPlaying ? abs(sin(t * 5.0 + phase)) : 0.2
                    let barH = CGFloat(3.0 + heightFactor * 8.0)

                    RoundedRectangle(cornerRadius: 1)
                        .fill(tintColor)
                        .frame(width: 2.5, height: barH)
                }
            }
            .frame(width: 14, height: 12, alignment: .bottom)
        }
    }
}

// MARK: - Mac Health Card View (Widget)

struct MacHealthCardView: View {
    let task: AgentTask
    @ObservedObject private var health = MacHealthManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WidgetCardHeader(task: task)

            HStack(spacing: 14) {
                // Battery Gauge Box
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Image(systemName: health.batterySymbol)
                            .font(.system(size: 14))
                            .foregroundColor(health.isLowBattery ? Color(hex: "#EF4444") : Color(hex: "#06B6D4"))
                        Text("\(health.batteryPercentage)%")
                            .font(.system(size: 15, weight: .bold).monospacedDigit())
                            .foregroundColor(Color(hex: "#F5F6F8"))
                    }

                    Text(health.isCharging ? "Charging" : (health.isACPower ? "Power Adapter" : "On Battery"))
                        .font(.system(size: 9.5))
                        .foregroundColor(Color(hex: "#8E939C"))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(hex: "#1A1D24"))
                .cornerRadius(8)

                // Thermal State Box
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 12))
                            .foregroundColor(thermalColor(health.thermalState))
                        Text(health.thermalDescription)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Color(hex: "#F5F6F8"))
                    }

                    Text("Thermal State")
                        .font(.system(size: 9.5))
                        .foregroundColor(Color(hex: "#8E939C"))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(hex: "#1A1D24"))
                .cornerRadius(8)

                Spacer()
            }
            .padding(.top, 2)

            // Upcoming Meeting heads-up banner if present
            if let meeting = health.upcomingMeeting {
                HStack(spacing: 6) {
                    Image(systemName: "video.fill")
                        .font(.system(size: 9.5))
                        .foregroundColor(Color(hex: "#E879F9"))

                    Text(meeting.title)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color(hex: "#F5F6F8"))
                        .lineLimit(1)

                    Text(meeting.countdownLabel)
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundColor(Color(hex: "#E879F9"))

                    Spacer()

                    if meeting.callURL != nil {
                        Button {
                            health.joinMeeting()
                        } label: {
                            Text("Join")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(.black)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color(hex: "#E879F9"))
                                .cornerRadius(4)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(hex: "#262933"))
                .cornerRadius(6)
            }
        }
        .padding(.leading, AppState.shared.mochiOnDesktop ? 16 : 106)
        .padding(.trailing, 14)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func thermalColor(_ state: ProcessInfo.ThermalState) -> Color {
        switch state {
        case .nominal:  return Color(hex: "#10B981")
        case .fair:     return Color(hex: "#F59E0B")
        case .serious:  return Color(hex: "#F97316")
        case .critical: return Color(hex: "#EF4444")
        @unknown default: return Color(hex: "#8E939C")
        }
    }
}