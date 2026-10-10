import AppKit
import SwiftUI
import Combine

// MARK: - Desktop bot view state

/// Observable bridge so DesktopMochiController can update view-level state without
/// coupling to SwiftUI @State.
@MainActor
final class DesktopBotViewState: ObservableObject {
    /// Drop to 10 fps when sleeping (saves energy).
    @Published var isSleeping: Bool = false
    /// Pause entirely (screen sleep / lock).
    @Published var paused: Bool = false
    /// Bot center in the same coord space as AppState.mousePosition (DesktopSpace, y-down).
    /// Updated every poll frame; Canvas reads it inside TimelineView — @Published not needed.
    var lookOrigin: CGPoint = .zero
}

// MARK: - Desktop bot view

/// Full Mochi character rendered inside the desktop floating panel.
struct DesktopBotView: View {
    @ObservedObject var appState: AppState
    /// Engine owned by DesktopMochiController; controller calls methods on it directly.
    let engine: BotEngine
    @ObservedObject var viewState: DesktopBotViewState

    var body: some View {
        TimelineView(.animation(
            minimumInterval: viewState.isSleeping ? 1.0 / 10.0 : 1.0 / 30.0,
            paused: viewState.paused
        )) { timeline in
            Canvas { ctx, size in
                let now = timeline.date.timeIntervalSinceReferenceDate
                let dt  = min(0.05, now - engine.lastTime)

                // Cinema Mode (Movie / Fullscreen Video) vs Music Dance
                let isMediaPlaying = appState.musicPlaying || NowPlayingManager.shared.isPlaying
                let isMovie = NowPlayingManager.shared.isWatchingMovie || appState.isWatchingMovie
                engine.setWatchingMovie(isMovie)

                // Eye tracking based on panel position (attentive screen gaze when watching movie)
                if engine.isWatchingMovie {
                    let mouseDistX = (appState.mousePosition.x - viewState.lookOrigin.x)
                    let mouseDistY = (appState.mousePosition.y - viewState.lookOrigin.y)
                    let mouseSpeed = hypot(mouseDistX, mouseDistY)
                    let screenGazeX = CGFloat(sin(now * 0.4) * 0.10)
                    let screenGazeY: CGFloat = 0.35
                    if mouseSpeed > 450 {
                        engine.lookX = tanh(mouseDistX / 280) * 0.4 + screenGazeX * 0.6
                        engine.lookY = -tanh(mouseDistY / 220) * 0.2 + screenGazeY * 0.8
                    } else {
                        engine.lookX = screenGazeX
                        engine.lookY = screenGazeY
                    }
                } else {
                    engine.lookX = tanh((appState.mousePosition.x - viewState.lookOrigin.x) / 260)
                    engine.lookY = -tanh((appState.mousePosition.y - viewState.lookOrigin.y) / 200)
                }

                // Desktop Mochi is always the "main" Mochi — always dressed
                engine.setOutfit(appState.resolvedOutfit, animated: true)

                // Dance when music plays (suppressed during cinema movie mode)
                let dancing: Bool = {
                    #if !APPSTORE
                    guard isMediaPlaying && !isMovie else { return false }
                    let allowed: Set<BotState> = [.idle, .working, .thinking, .searching, .finished]
                    return allowed.contains(appState.effectiveState)
                    #else
                    return false
                    #endif
                }()
                engine.setDancing(dancing)
                engine.update(dt: dt)

                var c = ctx
                engine.applyDance(&c, size: size)

                // Rigid roll when outfit is present (matches BotCanvasView)
                if engine.outfit != .none && engine.outfitPresence > 0.05 && abs(engine.roll) > 0.001 {
                    let center = engine.bodyCenter(size: size)
                    var rigidCtx = c
                    rigidCtx.translateBy(x: center.x, y: center.y)
                    rigidCtx.rotate(by: .radians(engine.roll))
                    rigidCtx.translateBy(x: -center.x, y: -center.y)
                    engine.drawHandsBehind(context: rigidCtx, size: size)
                    engine.drawOutfitBehind(context: rigidCtx, size: size)
                    engine.draw(context: rigidCtx, size: size)
                    engine.drawOutfitFront(context: rigidCtx, size: size)
                } else {
                    engine.drawHandsBehind(context: c, size: size)
                    engine.drawOutfitBehind(context: c, size: size)
                    engine.draw(context: c, size: size)
                    engine.drawOutfitFront(context: c, size: size)
                }
                engine.drawHandsAndExtras(context: c, size: size)
            }
        }
        .onChange(of: appState.effectiveState) { _, newState in
            engine.setState(newState)
        }
        .onReceive(NotificationCenter.default.publisher(for: .triggerLaugh)) { _ in
            engine.laugh()
        }
        .onAppear {
            engine.setState(appState.effectiveState, force: true)
            engine.setOutfit(appState.resolvedOutfit, animated: false)
        }
    }
}

// MARK: - Desktop Mochi controller

/// Manages the "Mochi on the desktop" floating panel.
///
/// Life cycle:
/// - **Install from drag**: `IslandWindowController.finishDrag` calls `install(ghostPanel:at:)`.
/// - **Launch restore**: `AppDelegate` observes `.greetComplete` → `launchFlyIfNeeded()`.
/// - **Alert**: `pendingApproval`/`pendingQuestion` goes non-nil → surprised emote →
///   `retractForAlert()` (panel gone, flag stays true) → both nil → `launchFlyIfNeeded()`.
/// - **User flies home**: double-click → `flyHome()` → full teardown.
/// Borderless panel that can become key to receive keyboard input (for text fields and shortcuts)
final class DesktopAlertPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class DesktopMochiController {
    static let shared = DesktopMochiController()
    private init() {
        observeScreenSleep()
        observeScreenLock()
        observeAlerts()   // permanent — lives for the lifetime of the singleton
    }

    var canPresentInPlaceAlert: Bool {
        panel != nil && (phase == .onDesktop || phase == .flyingOut)
    }

    private var panel: NSPanel?
    private var engine: BotEngine?
    private var viewState: DesktopBotViewState?
    private var frameTimer: Timer?

    // Concept 2 side-dock alert panel
    private var alertPanel: NSPanel?
    private var alertKeyDownMonitor: Any?
    private var alertIsRightSide: Bool = true

    // Alert state machine
    private var phase: DesktopPhase = .home

    // Desktop drag repositioning
    private var isDragging = false
    private var dragMouseStart: NSPoint = .zero
    private var dragOriginAtStart: NSPoint = .zero

    // Deferred single-click slap
    private var pendingSlapWorkItem: DispatchWorkItem?

    // Sleep detection
    private var lastActivityTime: Date = .now
    private var lastMouseLocation: NSPoint = .zero
    private var isSleeping = false

    // Screen sleep / lock
    private var screenSleeping = false

    // Lifecycle subscriptions (cleared on retractForAlert + fullTearDown)
    private var cancellables: Set<AnyCancellable> = []
    // Alert subscription — permanent, only released with the singleton
    private var alertSubscription: AnyCancellable?

    // Event monitors
    private var mouseDownMonitor:    Any?
    private var mouseDraggedMonitor: Any?
    private var mouseUpMonitor:      Any?
    private var globalMouseUpMonitor: Any?
    private var rightClickMonitor:   Any?

    // UserDefaults keys
    private static let posXKey    = "desktopMochiX"
    private static let posYKey    = "desktopMochiY"
    private static let enabledKey = "mochiOnDesktop"

    static let panelSize: CGFloat = DesktopMochiLogic.panelSize

    // MARK: - Keyboard shortcut toggle (⌃⌥D)

    /// Fly Mochi to the desktop if not there, or bring him back if he is.
    func flyOutOrHome() {
        if phase == .home {
            UserDefaults.standard.set(true, forKey: DesktopMochiController.enabledKey)
            launchFlyIfNeeded()
        } else if phase == .onDesktop {
            flyHome()
        }
    }

    // MARK: - Install (from drag-drop)

    /// Promote `ghostPanel` (the drag ghost) or create a fresh panel as the desktop Mochi,
    /// centered on `screenPoint`. Called by `IslandWindowController.finishDrag`.
    func install(ghostPanel: NSPanel?, at screenPoint: NSPoint) {
        guard panel == nil, phase == .home else { ghostPanel?.close(); return }
        let s = DesktopMochiController.panelSize

        let p: NSPanel
        if let ghost = ghostPanel {
            p = ghost
        } else {
            p = makeBlankPanel()
            p.setFrame(NSRect(x: screenPoint.x - s/2, y: screenPoint.y - s/2, width: s, height: s),
                       display: false)
        }

        // Build engine + hosting view (autoresizingMask lets it grow with the panel animation)
        let eng = BotEngine()
        eng.setState(AppState.shared.effectiveState, force: true)
        eng.setOutfit(AppState.shared.resolvedOutfit, animated: false)
        self.engine = eng
        self.isSleeping = false
        self.lastActivityTime = .now
        self.lastMouseLocation = NSEvent.mouseLocation

        let vs = DesktopBotViewState()
        vs.lookOrigin = lookOriginFor(panel: p)
        vs.paused = screenSleeping
        self.viewState = vs

        let hosting = NSHostingView(rootView:
            DesktopBotView(appState: AppState.shared, engine: eng, viewState: vs))
        hosting.frame = CGRect(origin: .zero, size: p.frame.size)
        hosting.autoresizingMask = [.width, .height]
        p.contentView = hosting

        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.ignoresMouseEvents = true
        if !p.isVisible { p.orderFront(nil) }

        // Squash emote + sound on landing
        eng.triggerEmote(.happy, duration: 0.6, silent: true)
        SoundEngine.shared.play("pop")

        // Animate from current (ghost) size to 120 × 120, centered on drop point
        let targetOrigin = clampToVisibleFrame(NSPoint(x: screenPoint.x - s/2, y: screenPoint.y - s/2))
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.17, 0.67, 0.38, 1.3)
            p.animator().setFrame(NSRect(origin: targetOrigin, size: CGSize(width: s, height: s)),
                                  display: true)
        }, completionHandler: {
            Task { @MainActor in
                self.panel = p
                self.phase = .onDesktop
                AppState.shared.mochiOnDesktop = true
                UserDefaults.standard.set(true, forKey: DesktopMochiController.enabledKey)
                self.persistPosition()
                self.startPolling()
                self.addEventMonitors()
                self.observeLifecycle()
                let alertNow = AppState.shared.pendingApproval != nil || AppState.shared.pendingQuestion != nil
                if alertNow {
                    self.wakeUpIfNeeded()
                    self.engine?.triggerEmote(.surprised)
                    self.showAlertPanel()
                }
            }
        })
    }

    // MARK: - Launch fly (app-start restore or alert return)

    /// Fly a new panel from the notch to the saved desktop position.
    /// Called by AppDelegate after `.greetComplete`, and by the alert-return path.
    func launchFlyIfNeeded() {
        guard UserDefaults.standard.bool(forKey: DesktopMochiController.enabledKey) else { return }
        guard phase == .home else { return }
        guard panel == nil else { return }

        phase = .flyingOut
        let s = DesktopMochiController.panelSize
        let screen = IslandWindowController.islandScreen()
        let startOrigin = NSPoint(x: screen.frame.midX - s/2, y: screen.frame.maxY - s)
        let target = loadSavedPosition()

        let p = makeBlankPanel()
        p.setFrame(NSRect(origin: startOrigin, size: CGSize(width: s, height: s)), display: false)
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.ignoresMouseEvents = true

        let eng = BotEngine()
        eng.setState(AppState.shared.effectiveState, force: true)
        eng.setOutfit(AppState.shared.resolvedOutfit, animated: false)
        self.engine = eng
        self.isSleeping = false
        self.lastActivityTime = .now
        self.lastMouseLocation = NSEvent.mouseLocation

        let vs = DesktopBotViewState()
        vs.lookOrigin = lookOriginFor(panel: p)
        vs.paused = screenSleeping
        self.viewState = vs

        let hosting = NSHostingView(rootView:
            DesktopBotView(appState: AppState.shared, engine: eng, viewState: vs))
        hosting.frame = CGRect(x: 0, y: 0, width: s, height: s)
        hosting.autoresizingMask = [.width, .height]
        p.contentView = hosting
        p.alphaValue = 0
        p.orderFront(nil)

        AppState.shared.mochiOnDesktop = true

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.45
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            p.animator().alphaValue = 1
            p.animator().setFrame(NSRect(origin: target, size: CGSize(width: s, height: s)), display: true)
        }, completionHandler: {
            Task { @MainActor in
                self.panel = p
                self.phase = .onDesktop
                UserDefaults.standard.set(true, forKey: DesktopMochiController.enabledKey)
                self.persistPosition()
                self.startPolling()
                self.addEventMonitors()
                self.observeLifecycle()
                let alertNow = AppState.shared.pendingApproval != nil || AppState.shared.pendingQuestion != nil
                if alertNow {
                    self.wakeUpIfNeeded()
                    self.engine?.triggerEmote(.surprised)
                    self.showAlertPanel()
                }
            }
        })
    }

    // MARK: - Fly home (user-initiated: double-click)

    /// Animate panel to notch then fully tear down.
    func flyHome() {
        guard let p = panel else { return }
        closeAlertPanel(animated: false)
        phase = .home
        pendingSlapWorkItem?.cancel()
        stopPolling()
        removeEventMonitors()
        cancellables.removeAll()
        isSleeping = false
        let s = DesktopMochiController.panelSize
        let screen = IslandWindowController.islandScreen()
        let targetOrigin = NSPoint(x: screen.frame.midX - s/2, y: screen.frame.maxY - s)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.45
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            p.animator().setFrame(NSRect(origin: targetOrigin, size: CGSize(width: s, height: s)),
                                  display: true)
        }, completionHandler: {
            Task { @MainActor in
                SoundEngine.shared.play("peek")
                self.fullTearDown()
            }
        })
    }

    // MARK: - Retract for alert (panel flies home; comes back after alert resolves)

    /// Close panel and show notch Mochi for the alert. UserDefaults flag stays true so
    /// `launchFlyIfNeeded` restores Mochi once the alert is dismissed.
    private func retractForAlert() {
        guard let p = panel else { return }
        stopPolling()
        removeEventMonitors()
        cancellables.removeAll()
        pendingSlapWorkItem?.cancel()
        isSleeping = false

        let s = DesktopMochiController.panelSize
        let screen = IslandWindowController.islandScreen()
        let targetOrigin = NSPoint(x: screen.frame.midX - s/2, y: screen.frame.maxY - s)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.45
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            p.animator().setFrame(NSRect(origin: targetOrigin, size: CGSize(width: s, height: s)),
                                  display: true)
        }, completionHandler: {
            Task { @MainActor in
                p.close()
                self.panel = nil
                self.engine = nil
                self.viewState = nil
                self.isDragging = false
                AppState.shared.mochiOnDesktop = false
                // UserDefaults flag stays TRUE so launchFlyIfNeeded works
                if self.phase == .alertResolvedDuringRetract {
                    self.phase = .home
                    self.launchFlyIfNeeded()
                } else {
                    self.phase = .atNotchForAlert
                }
            }
        })
    }

    // MARK: - Uninstall (immediate, no animation)

    func uninstall() {
        stopPolling()
        removeEventMonitors()
        fullTearDown()
    }

    private func fullTearDown() {
        closeAlertPanel(animated: false)
        phase = .home
        cancellables.removeAll()
        pendingSlapWorkItem?.cancel()
        panel?.close()
        panel = nil
        engine = nil
        viewState = nil
        isDragging = false
        isSleeping = false
        AppState.shared.mochiOnDesktop = false
        UserDefaults.standard.set(false, forKey: DesktopMochiController.enabledKey)
    }

    // MARK: - Panel factory

    private func makeBlankPanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.ignoresMouseEvents = true
        return p
    }

    // MARK: - Lifecycle observation (active while panel is live on desktop)

    private func observeLifecycle() {
        cancellables.removeAll()

        // effectiveState → .finished: joy jump (only when on desktop, not retracting)
        Publishers.CombineLatest(AppState.shared.$stateOverride, AppState.shared.$tasks)
            .map { _, _ in AppState.shared.effectiveState }
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newState in
                guard let self, self.phase == .onDesktop else { return }
                if newState == .finished {
                    self.engine?.triggerEmote(.happy, duration: 1.2, silent: true)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Alert observation (permanent — installed once at init)

    private func observeAlerts() {
        alertSubscription = Publishers.CombineLatest(
            AppState.shared.$pendingApproval,
            AppState.shared.$pendingQuestion
        )
        .map { (a: ApprovalInfo?, q: AskQuestion?) -> Bool in
            a != nil || q != nil
        }
        .removeDuplicates()
        .receive(on: DispatchQueue.main)
        .sink { [weak self] (alertActive: Bool) in
            guard let self else { return }

            if alertActive {
                guard self.panel != nil && (self.phase == .onDesktop || self.phase == .flyingOut) else { return }
                self.wakeUpIfNeeded()
                self.engine?.triggerEmote(.surprised)
                self.showAlertPanel()
            } else {
                if self.alertPanel != nil {
                    self.closeAlertPanel(animated: true)
                    self.engine?.triggerEmote(.happy, duration: 0.8, silent: true)
                }
            }
        }
    }

    // MARK: - 60 Hz polling (only while panel is live)

    private func startPolling() {
        frameTimer?.invalidate()
        frameTimer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.pollFrame() }
        }
        RunLoop.main.add(frameTimer!, forMode: .common)
    }

    private func stopPolling() {
        frameTimer?.invalidate()
        frameTimer = nil
    }

    private func pollFrame() {
        guard let p = panel else { return }
        let mouse = NSEvent.mouseLocation
        let pf    = p.frame
        let local = CGPoint(x: mouse.x - pf.minX, y: mouse.y - pf.minY)
        let s     = DesktopMochiController.panelSize

        // Toggle click-through
        let overBody   = DesktopMochiLogic.isOverBody(localPoint: local, panelSize: s)
        let needsMouse = overBody || isDragging
        if p.ignoresMouseEvents == needsMouse {
            p.ignoresMouseEvents = !needsMouse
        }

        // Update eye-tracking origin every frame
        viewState?.lookOrigin = lookOriginFor(panel: p)

        // Track cursor movement across the screen
        if lastMouseLocation == .zero {
            lastMouseLocation = mouse
        }
        let mouseDelta = hypot(mouse.x - lastMouseLocation.x, mouse.y - lastMouseLocation.y)
        if mouseDelta > 2.0 {
            lastActivityTime = .now
            lastMouseLocation = mouse
        }

        // Check system-wide hardware idle time (catches typing, keyboard shortcuts, trackpad gestures)
        let systemIdle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if systemIdle < 0.5 {
            lastActivityTime = .now
        }

        let agentActive = AppState.shared.effectiveState != .idle &&
                          AppState.shared.effectiveState != .sleeping
        if agentActive {
            lastActivityTime = .now
        }

        // Idle duration is the shortest interval since any user or agent activity
        let idleInterval = min(Date.now.timeIntervalSince(lastActivityTime), systemIdle)
        let isInteracting = isDragging || overBody

        let shouldSleep = DesktopMochiLogic.shouldSleep(
            secondsSinceActivity: idleInterval,
            isInteracting: isInteracting,
            agentActive: agentActive
        )

        if shouldSleep != isSleeping {
            isSleeping = shouldSleep
            viewState?.isSleeping = shouldSleep
            engine?.setState(isSleeping ? .sleeping : AppState.shared.effectiveState)
        }
    }

    private func wakeUpIfNeeded() {
        lastActivityTime = .now
        if isSleeping {
            isSleeping = false
            viewState?.isSleeping = false
            engine?.setState(AppState.shared.effectiveState)
        }
    }

    // MARK: - Event monitors

    private func addEventMonitors() {
        mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self else { return event }
            MainActor.assumeIsolated {
                guard event.window === self.panel else { return }
                self.wakeUpIfNeeded()
                self.dragMouseStart    = NSEvent.mouseLocation
                self.dragOriginAtStart = self.panel?.frame.origin ?? .zero
            }
            return event
        }

        mouseDraggedMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDragged) { [weak self] event in
            guard let self else { return event }
            MainActor.assumeIsolated {
                self.wakeUpIfNeeded()
                let m = NSEvent.mouseLocation
                if !self.isDragging {
                    let dist = hypot(m.x - self.dragMouseStart.x, m.y - self.dragMouseStart.y)
                    guard self.dragMouseStart != .zero, dist > 3 else { return }
                    self.isDragging = true
                }
                guard let p = self.panel else { return }
                let dx = m.x - self.dragMouseStart.x
                let dy = m.y - self.dragMouseStart.y
                let newOrigin = self.clampToVisibleFrame(
                    NSPoint(x: self.dragOriginAtStart.x + dx, y: self.dragOriginAtStart.y + dy),
                    mouse: m)
                p.setFrameOrigin(newOrigin)
                self.viewState?.lookOrigin = self.lookOriginFor(panel: p)
                if self.alertPanel != nil {
                    self.updateAlertPanelPosition(animated: false)
                }
            }
            return event
        }

        // Local mouseUp (cursor still within panel)
        mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            guard let self else { return event }
            MainActor.assumeIsolated {
                self.wakeUpIfNeeded()
                let wasDragging = self.isDragging
                self.isDragging = false
                self.dragMouseStart = .zero
                if wasDragging {
                    self.handleDragRelease(at: NSEvent.mouseLocation)
                } else if event.window === self.panel {
                    self.handleClick(clickCount: event.clickCount)
                }
            }
            return event
        }

        // Global mouseUp (cursor moved outside panel during drag)
        globalMouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isDragging else { return }
                self.wakeUpIfNeeded()
                self.isDragging = false
                self.dragMouseStart = .zero
                self.handleDragRelease(at: NSEvent.mouseLocation)
            }
        }

        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self else { return event }
            MainActor.assumeIsolated {
                guard event.window === self.panel else { return }
                NotificationCenter.default.post(name: .openWardrobeFromDesktop, object: nil)
            }
            return event
        }
    }

    // MARK: - Click / drag helpers

    private func handleClick(clickCount: Int) {
        if clickCount >= 2 {
            pendingSlapWorkItem?.cancel()
            flyHome()
        } else {
            pendingSlapWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.engine?.slap() }
            pendingSlapWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: item)
        }
    }

    private func handleDragRelease(at mouse: NSPoint) {
        wakeUpIfNeeded()
        let islandController = (NSApp.delegate as? AppDelegate)?.islandController
        let inNotchZone = islandController?.window?.frame.contains(mouse) == true

        if inNotchZone {
            flyHome()
            return
        }

        #if !APPSTORE
        if let ctx = islandController?.windowContextAtPoint(mouse) {
            // Attach window context; Mochi returns to pre-drag position
            AppState.shared.promptContext = ctx
            SoundEngine.shared.play("approve")
            engine?.triggerEmote(.happy, duration: 0.6, silent: true)
            let origin = clampToVisibleFrame(dragOriginAtStart)
            panel?.setFrameOrigin(origin)
            persistPosition()
            islandController?.expand(to: .prompt)
            return
        }
        #endif
        // Elsewhere: keep new position
        persistPosition()
    }

    private func removeEventMonitors() {
        removeAlertKeyMonitor()
        if let m = mouseDownMonitor     { NSEvent.removeMonitor(m); mouseDownMonitor     = nil }
        if let m = mouseDraggedMonitor  { NSEvent.removeMonitor(m); mouseDraggedMonitor  = nil }
        if let m = mouseUpMonitor       { NSEvent.removeMonitor(m); mouseUpMonitor       = nil }
        if let m = globalMouseUpMonitor { NSEvent.removeMonitor(m); globalMouseUpMonitor = nil }
        if let m = rightClickMonitor    { NSEvent.removeMonitor(m); rightClickMonitor    = nil }
    }

    // MARK: - Screen sleep / wake

    private func observeScreenSleep() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.screenSleeping = true
                self?.viewState?.paused = true
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.screenSleeping = false
                self?.viewState?.paused = false
            }
        }
    }

    // MARK: - Screen lock / unlock

    private func observeScreenLock() {
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.screenSleeping = true
                self?.viewState?.paused = true
            }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.screenSleeping = false
                self?.viewState?.paused = false
            }
        }
    }

    // MARK: - Side-dock Alert Panel (Concept 2: In-place Flank Drawer)

    private func showAlertPanel() {
        guard let p = panel else { return }
        let isQuestion = AppState.shared.pendingQuestion != nil
        let cardSize = CGSize(width: 352, height: isQuestion ? 216 : 148)
        let screen = p.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let placement = DesktopMochiLogic.sideDockPlacement(
            mochiFrame: p.frame,
            cardSize: cardSize,
            visibleFrame: screen.visibleFrame,
            spacing: 12,
            margin: 16
        )
        self.alertIsRightSide = placement.isRightSide

        // Turn Mochi's gaze toward the card flank
        if placement.isRightSide {
            engine?.lookX = 0.8
            engine?.lookY = 0.0
        } else {
            engine?.lookX = -0.8
            engine?.lookY = 0.0
        }

        if let existing = alertPanel {
            existing.setFrame(NSRect(origin: placement.origin, size: cardSize), display: true, animate: true)
            existing.orderFront(nil)
            return
        }

        let ap = DesktopAlertPanel(
            contentRect: NSRect(origin: placement.origin, size: cardSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        ap.backgroundColor = NSColor.clear
        ap.isOpaque = false
        ap.hasShadow = true
        ap.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        ap.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        ap.ignoresMouseEvents = false

        let sideDockView = DesktopSideDockAlertView(
            appState: AppState.shared,
            isRightSide: placement.isRightSide,
            onClose: { [weak self] in
                self?.closeAlertPanel(animated: true)
            }
        )
        let hosting = NSHostingView(rootView: sideDockView)
        hosting.frame = CGRect(origin: .zero, size: cardSize)
        hosting.autoresizingMask = [.width, .height]
        ap.contentView = hosting

        // Start from horizontal offset adjacent to Mochi, slide into final docked origin
        let slideOffset: CGFloat = placement.isRightSide ? -16 : 16
        let startOrigin = NSPoint(x: placement.origin.x + slideOffset, y: placement.origin.y)
        ap.setFrameOrigin(startOrigin)
        ap.alphaValue = 0
        ap.orderFront(self)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)
            ap.animator().setFrameOrigin(placement.origin)
            ap.animator().alphaValue = 1.0
        }

        if isQuestion {
            SoundEngine.shared.play("question")
        } else {
            SoundEngine.shared.play("approval")
        }

        self.alertPanel = ap
        setupAlertKeyMonitor()
    }

    private func updateAlertPanelPosition(animated: Bool) {
        guard let p = panel, let ap = alertPanel else { return }
        let screen = p.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let placement = DesktopMochiLogic.sideDockPlacement(
            mochiFrame: p.frame,
            cardSize: ap.frame.size,
            visibleFrame: screen.visibleFrame,
            spacing: 12,
            margin: 16
        )
        self.alertIsRightSide = placement.isRightSide

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ap.animator().setFrameOrigin(placement.origin)
            }
        } else {
            ap.setFrameOrigin(placement.origin)
        }
    }

    private func closeAlertPanel(animated: Bool = true) {
        guard let ap = alertPanel else { return }
        removeAlertKeyMonitor()
        alertPanel = nil

        if !animated {
            ap.close()
            return
        }

        let slideOffset: CGFloat = alertIsRightSide ? -14 : 14
        let targetOrigin = NSPoint(x: ap.frame.origin.x + slideOffset, y: ap.frame.origin.y)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            ap.animator().setFrameOrigin(targetOrigin)
            ap.animator().alphaValue = 0.0
        }, completionHandler: {
            Task { @MainActor in
                ap.close()
            }
        })
    }

    private func setupAlertKeyMonitor() {
        removeAlertKeyMonitor()
        alertKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.alertPanel != nil else { return event }
            let s = AppState.shared
            // 53 = Escape -> Deny or Reply in terminal
            if event.keyCode == 53 {
                if s.pendingApproval != nil {
                    HookServer.shared.sendApprovalDecision("deny")
                    return nil
                } else if s.pendingQuestion != nil {
                    HookServer.shared.sendQuestionAsk()
                    return nil
                }
            }
            // 36 = Return / Enter -> Allow
            if event.keyCode == 36 {
                if s.pendingApproval != nil {
                    HookServer.shared.sendApprovalDecision("allow")
                    return nil
                }
            }
            // 49 = Space -> Always
            if event.keyCode == 49 {
                if s.pendingApproval != nil {
                    HookServer.shared.sendApprovalDecision("always")
                    return nil
                }
            }
            // 18, 19, 20, 21 = Keys 1, 2, 3, 4 -> Quick choose question option
            if let question = s.pendingQuestion, !question.questions.isEmpty {
                let keyIndexMap: [UInt16: Int] = [18: 0, 19: 1, 20: 2, 21: 3]
                if let optIdx = keyIndexMap[event.keyCode],
                   let curItem = question.questions.first,
                   optIdx < curItem.options.count {
                    let label = curItem.options[optIdx].label
                    let answers = AskQuestion.buildAnswers(questions: question.questions, selections: [[label]])
                    HookServer.shared.sendQuestionAnswers(answers)
                    return nil
                }
            }
            return event
        }
    }

    private func removeAlertKeyMonitor() {
        if let m = alertKeyDownMonitor {
            NSEvent.removeMonitor(m)
            alertKeyDownMonitor = nil
        }
    }

    // MARK: - Position helpers

    private func lookOriginFor(panel: NSPanel) -> CGPoint {
        DesktopMochiLogic.lookOrigin(
            panelMinX:  panel.frame.minX,
            panelMinY:  panel.frame.minY,
            desktopTop: IslandWindowController.desktopTop,
            panelSize:  DesktopMochiController.panelSize)
    }

    private func clampToVisibleFrame(_ origin: NSPoint, mouse: NSPoint? = nil) -> NSPoint {
        let targetPoint = mouse ?? origin
        let screen = NSScreen.screens.first(where: { NSMouseInRect(targetPoint, $0.frame, false) })
            ?? NSScreen.screens.min(by: {
                let da = hypot(origin.x - $0.visibleFrame.midX, origin.y - $0.visibleFrame.midY)
                let db = hypot(origin.x - $1.visibleFrame.midY, origin.y - $1.visibleFrame.midY)
                return da < db
            }) ?? NSScreen.main!
        let pt = DesktopMochiLogic.clampOrigin(
            CGPoint(x: origin.x, y: origin.y),
            panelSize:    DesktopMochiController.panelSize,
            visibleFrame: screen.visibleFrame,
            margin:       DesktopMochiLogic.clampMargin)
        return NSPoint(x: pt.x, y: pt.y)
    }

    private func loadSavedPosition() -> NSPoint {
        let ud = UserDefaults.standard
        guard ud.object(forKey: DesktopMochiController.posXKey) != nil else {
            return defaultPosition()
        }
        let x = CGFloat(ud.double(forKey: DesktopMochiController.posXKey))
        let y = CGFloat(ud.double(forKey: DesktopMochiController.posYKey))
        return clampToVisibleFrame(NSPoint(x: x, y: y))
    }

    private func defaultPosition() -> NSPoint {
        let s      = DesktopMochiController.panelSize
        let margin = DesktopMochiLogic.clampMargin
        let vf     = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        return NSPoint(x: vf.maxX - s - margin, y: vf.minY + margin)
    }

    private func persistPosition() {
        guard let p = panel else { return }
        let o = p.frame.origin
        UserDefaults.standard.set(Double(o.x), forKey: DesktopMochiController.posXKey)
        UserDefaults.standard.set(Double(o.y), forKey: DesktopMochiController.posYKey)
    }
}

// MARK: - Side-dock frosted glass background

struct SideDockFrostedGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.isEmphasized = true
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Side-dock alert view (Concept 2: Horizontal Flank Drawer)

struct DesktopSideDockAlertView: View {
    @ObservedObject var appState: AppState
    let isRightSide: Bool
    let onClose: () -> Void

    var isApproval: Bool { appState.pendingApproval != nil }
    var isQuestion: Bool { appState.pendingQuestion != nil }

    var body: some View {
        ZStack {
            // Frosted glass background
            SideDockFrostedGlass()
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            // Deep obsidian backdrop wash
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(hex: "#0A0D12").opacity(0.88))

            // Specular border
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.24), Color.white.opacity(0.06)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )

            // Top ambient accent line
            VStack {
                HStack {
                    if !isRightSide { Spacer() }
                    RoundedRectangle(cornerRadius: 2)
                        .fill(
                            LinearGradient(
                                colors: isApproval
                                    ? [Color(hex: "#F59E0B"), Color(hex: "#D97706")]
                                    : [Color(hex: "#22D3EE"), Color(hex: "#06B6D4")],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: 56, height: 3)
                        .shadow(
                            color: isApproval
                                ? Color(hex: "#F59E0B").opacity(0.65)
                                : Color(hex: "#22D3EE").opacity(0.65),
                            radius: 5,
                            x: 0,
                            y: 1
                        )
                        .padding(.horizontal, 22)
                    if isRightSide { Spacer() }
                }
                Spacer()
            }

            // Card content
            if let approval = appState.pendingApproval {
                DesktopApprovalCard(approval: approval, isRightSide: isRightSide, onClose: onClose)
            } else if let question = appState.pendingQuestion {
                DesktopQuestionCard(question: question, isRightSide: isRightSide, onClose: onClose)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Desktop Approval Card

struct DesktopApprovalCard: View {
    let approval: ApprovalInfo
    let isRightSide: Bool
    let onClose: () -> Void

    var hideAlways: Bool {
        approval.pillId == "agent_codex"
            || approval.pillId == "agent_copilot"
            || approval.pillId == "agent_muse"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(Color(hex: "#F59E0B").opacity(0.18))
                        .frame(width: 22, height: 22)
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color(hex: "#F59E0B"))
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text("Needs Permission")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(hex: "#F5F6F8"))
                    Text((approval.pillId == "agent_claude" || approval.pillId == "integration_claude") ? "Claude Code" : "Terminal Agent")
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "#8B949E"))
                }

                Spacer()

                // Keyboard shortcut hint
                Text("esc to deny")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(Color(hex: "#8B949E"))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            // Code command block
            HStack(spacing: 6) {
                Text("$")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(hex: "#F59E0B"))
                let cmdText = !approval.command.isEmpty ? approval.command : (!approval.tool.isEmpty ? approval.tool : "…")
                Text(cmdText)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(Color(hex: "#E6EDF3"))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.black.opacity(0.48))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )

            // Action buttons
            HStack(spacing: 8) {
                // Deny button
                Button {
                    HookServer.shared.sendApprovalDecision("deny")
                } label: {
                    HStack(spacing: 4) {
                        Text("Deny")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(Color(hex: "#C9D1D9"))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                // Allow button
                Button {
                    HookServer.shared.sendApprovalDecision("allow")
                } label: {
                    HStack(spacing: 4) {
                        Text("Allow")
                            .font(.system(size: 11, weight: .semibold))
                        Text("⏎")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .opacity(0.8)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        LinearGradient(
                            colors: [Color(hex: "#D97706"), Color(hex: "#B45309")],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(Color(hex: "#F59E0B").opacity(0.6), lineWidth: 1)
                    )
                    .shadow(color: Color(hex: "#F59E0B").opacity(0.3), radius: 4, x: 0, y: 1)
                }
                .buttonStyle(.plain)

                // Always button
                if !hideAlways {
                    Button {
                        HookServer.shared.sendApprovalDecision("always")
                    } label: {
                        Text("Always")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color(hex: "#8B949E"))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7)
                                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

// MARK: - Desktop Question Card

struct DesktopQuestionCard: View {
    let question: AskQuestion
    let isRightSide: Bool
    let onClose: () -> Void

    @State private var questionIndex = 0
    @State private var selections: [[String]] = []
    @State private var otherTexts: [String] = []
    @State private var showOther: [Bool] = []
    @FocusState private var otherFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !question.questions.isEmpty {
                let qi = min(questionIndex, question.questions.count - 1)
                let item = question.questions[qi]
                let isLast = qi == question.questions.count - 1
                let isMulti = item.multiSelect
                let curSel = qi < selections.count ? selections[qi] : []
                let curOther = qi < showOther.count ? showOther[qi] : false
                let curOtherText = qi < otherTexts.count ? otherTexts[qi] : ""
                let canProceed = !curSel.isEmpty || (curOther && !curOtherText.isEmpty)

                // Header
                HStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .fill(Color(hex: "#22D3EE").opacity(0.18))
                            .frame(width: 20, height: 20)
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Color(hex: "#22D3EE"))
                    }

                    Text("Claude Code is asking")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color(hex: "#F5F6F8"))

                    if question.questions.count > 1 {
                        Text("\(qi + 1)/\(question.questions.count)")
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "#6B7079"))
                    }

                    Spacer()

                    Button("Reply in terminal") {
                        HookServer.shared.sendQuestionAsk()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "#8B949E"))
                    .underline()
                }

                // Question text
                Text(item.question)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(hex: "#F5F6F8"))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                // Options or "Other…"
                if curOther {
                    HStack(spacing: 6) {
                        TextField("Your answer…", text: Binding(
                            get: { qi < otherTexts.count ? otherTexts[qi] : "" },
                            set: { v in if qi < otherTexts.count { otherTexts[qi] = v } }
                        ))
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#F5F6F8"))
                        .focused($otherFieldFocused)
                        .onAppear { otherFieldFocused = true }
                        .onSubmit { commitOtherAndProceed(q: question, qi: qi, isLast: isLast) }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                        Button(isLast ? "Send" : "Next") {
                            commitOtherAndProceed(q: question, qi: qi, isLast: isLast)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(curOtherText.isEmpty ? Color(hex: "#6B7079") : Color(hex: "#F5F6F8"))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(curOtherText.isEmpty ? 0.05 : 0.16))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .disabled(curOtherText.isEmpty)

                        Button {
                            if qi < showOther.count { showOther[qi] = false }
                        } label: {
                            Text("✕")
                                .font(.system(size: 9))
                                .foregroundColor(Color(hex: "#8B949E"))
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    ChipFlowLayout(spacing: 6) {
                        ForEach(Array(item.options.enumerated()), id: \.offset) { idx, opt in
                            let isSelected = curSel.contains(opt.label)
                            Button {
                                if isMulti {
                                    toggleSelection(qi: qi, label: opt.label)
                                } else {
                                    selectAndProceed(q: question, qi: qi, label: opt.label, isLast: isLast)
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text("\(idx + 1)")
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundColor(isSelected ? Color(hex: "#22D3EE") : Color(hex: "#8B949E"))
                                        .padding(.horizontal, 3.5)
                                        .padding(.vertical, 1)
                                        .background(Color.white.opacity(isSelected ? 0.15 : 0.06))
                                        .clipShape(RoundedRectangle(cornerRadius: 3))

                                    Text(opt.label)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(isSelected ? Color(hex: "#67E8F9") : Color(hex: "#E6EDF3"))
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(isSelected ? Color(hex: "#22D3EE").opacity(0.2) : Color.white.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(isSelected ? Color(hex: "#22D3EE").opacity(0.55) : Color.white.opacity(0.08), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }

                        Button {
                            if qi < showOther.count { showOther[qi] = true }
                        } label: {
                            Text("Other…")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Color(hex: "#8B949E"))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(Color.white.opacity(0.06))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }

                    if isMulti {
                        HStack {
                            Spacer()
                            Button(isLast ? "Send" : "Next") {
                                proceedFromQuestion(q: question, qi: qi, isLast: isLast)
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Color.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(
                                LinearGradient(
                                    colors: [Color(hex: "#06B6D4"), Color(hex: "#0891B2")],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .disabled(!canProceed)
                            .opacity(canProceed ? 1 : 0.4)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .onAppear { resetQuestionState() }
        .onChange(of: question) { _, _ in resetQuestionState() }
    }

    private func resetQuestionState() {
        questionIndex = 0
        let count = question.questions.count
        selections = Array(repeating: [], count: count)
        otherTexts = Array(repeating: "", count: count)
        showOther  = Array(repeating: false, count: count)
    }

    private func toggleSelection(qi: Int, label: String) {
        guard qi < selections.count else { return }
        if let i = selections[qi].firstIndex(of: label) {
            selections[qi].remove(at: i)
        } else {
            selections[qi].append(label)
        }
    }

    private func selectAndProceed(q: AskQuestion, qi: Int, label: String, isLast: Bool) {
        guard qi < selections.count else { return }
        selections[qi] = [label]
        if isLast { sendAnswers(q: q) } else { withAnimation { questionIndex = qi + 1 } }
    }

    private func proceedFromQuestion(q: AskQuestion, qi: Int, isLast: Bool) {
        if isLast { sendAnswers(q: q) } else { withAnimation { questionIndex = qi + 1 } }
    }

    private func commitOtherAndProceed(q: AskQuestion, qi: Int, isLast: Bool) {
        let text = qi < otherTexts.count ? otherTexts[qi] : ""
        guard !text.isEmpty else { return }
        if qi < selections.count { selections[qi] = [text] }
        if isLast {
            sendAnswers(q: q)
        } else {
            if qi < showOther.count { showOther[qi] = false }
            withAnimation { questionIndex = qi + 1 }
        }
    }

    private func sendAnswers(q: AskQuestion) {
        let answers = AskQuestion.buildAnswers(questions: q.questions, selections: selections)
        HookServer.shared.sendQuestionAnswers(answers)
    }
}

