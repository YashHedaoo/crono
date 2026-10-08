import SwiftUI
import Combine

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
        default:                  EmptyView()
        }
    }
}

struct WidgetCardHeader: View {
    let task: AgentTask

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color(hex: task.color))
                .frame(width: 7, height: 7)
            Text(task.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color(hex: "#F5F6F8"))
            Text("Widget")
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
            .padding(.leading, 108)
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
        .padding(.leading, 108)
        .padding(.trailing, 16)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Calendar card

struct CalendarCardView: View {
    let task: AgentTask
    @State private var monthOffset = 0

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

        VStack(alignment: .leading, spacing: 4) {
            WidgetCardHeader(task: task)

            HStack(spacing: 8) {
                Button { withAnimation { monthOffset -= 1 } } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color(hex: "#8E939C"))
                }
                .buttonStyle(.plain)
                Text(WidgetFormat.monthTitle(monthDate))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(hex: "#F5F6F8"))
                Button { withAnimation { monthOffset += 1 } } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color(hex: "#8E939C"))
                }
                .buttonStyle(.plain)
                Spacer()
                if monthOffset != 0 {
                    Button("Today") { withAnimation { monthOffset = 0 } }
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color(hex: task.color).opacity(0.85))
                        .buttonStyle(.plain)
                }
            }
            .padding(.top, 2)

            HStack(spacing: 3) {
                ForEach(weekdayLetters, id: \.self) { letter in
                    Text(letter)
                        .font(.system(size: 9))
                        .foregroundColor(Color(hex: "#6B7079"))
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 7), spacing: 3) {
                ForEach(0..<(leading + daysInMonth), id: \.self) { idx in
                    let day = idx - leading + 1
                    if day < 1 {
                        Color.clear
                            .frame(height: 18)
                    } else {
                        let isToday = isCurrentMonth && day == today
                        Text("\(day)")
                            .font(.system(size: 10, weight: isToday ? .bold : .regular).monospacedDigit())
                            .foregroundColor(isToday
                                             ? Color.black
                                             : (idx % 7 == 0 || idx % 7 == 6
                                                ? Color(hex: "#8E939C")
                                                : Color(hex: "#F5F6F8")))
                            .frame(width: 18, height: 18)
                            .background(isToday ? Color(hex: task.color) : Color.clear)
                            .clipShape(Circle())
                    }
                }
            }
            .padding(.top, 2)
        }
        .padding(.leading, 108)
        .padding(.trailing, 16)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}