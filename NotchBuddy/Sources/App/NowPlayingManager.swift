import Foundation
import SwiftUI
import AppKit

// MARK: - MediaRemote / System Media Key Bridge

private enum MediaRemoteBridge {
    typealias MRSendCommandFunc = @convention(c) (Int32, AnyObject?) -> Bool

    private static let sendCommandFunc: MRSendCommandFunc? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW),
              let sym = dlsym(handle, "MRMediaRemoteSendCommand") else {
            return nil
        }
        return unsafeBitCast(sym, to: MRSendCommandFunc.self)
    }()

    typealias MRSendCommandToAppFunc = @convention(c) (
        Int32,             // command
        CFDictionary?,     // options
        AnyObject?,        // origin (nil for local)
        CFString,          // appBundleID
        Int32,             // appOptions (0)
        DispatchQueue?,    // queue
        AnyObject?         // completion
    ) -> Bool

    private static let sendCommandToAppFunc: MRSendCommandToAppFunc? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW),
              let sym = dlsym(handle, "MRMediaRemoteSendCommandToApp") else {
            return nil
        }
        return unsafeBitCast(sym, to: MRSendCommandToAppFunc.self)
    }()

    static func sendCommand(_ command: Int32, bundleId: String? = nil) -> Bool {
        if let bundleId = bundleId, !bundleId.isEmpty, let fn = sendCommandToAppFunc {
            let res = fn(command, nil, nil, bundleId as CFString, 0, nil, nil)
            if res { return true }
        }
        if let fn = sendCommandFunc {
            return fn(command, nil)
        }
        return false
    }

    typealias MRIsPlayingFunc = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void

    private static let isPlayingFunc: MRIsPlayingFunc? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW),
              let sym = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") else {
            return nil
        }
        return unsafeBitCast(sym, to: MRIsPlayingFunc.self)
    }()

    static func isApplicationPlaying() async -> Bool {
        await withCheckedContinuation { continuation in
            if let fn = isPlayingFunc {
                fn(DispatchQueue.global()) { playing in
                    continuation.resume(returning: playing)
                }
            } else {
                continuation.resume(returning: false)
            }
        }
    }

    typealias MRRegisterFunc = @convention(c) (DispatchQueue) -> Void

    private static let registerFunc: MRRegisterFunc? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW),
              let sym = dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications") else {
            return nil
        }
        return unsafeBitCast(sym, to: MRRegisterFunc.self)
    }()

    static func registerForNotifications() {
        registerFunc?(DispatchQueue.main)
    }

    static func play(bundleId: String? = nil) {
        _ = sendCommand(2, bundleId: bundleId) // kMRTogglePlayPause = 2 (browsers don't handle kMRPlay=0)
    }

    static func pause(bundleId: String? = nil) {
        _ = sendCommand(1, bundleId: bundleId) // kMRPause = 1
    }

    static func togglePlayPause(bundleId: String? = nil) {
        _ = sendCommand(2, bundleId: bundleId) // kMRTogglePlayPause = 2
    }

    static func nextTrack(bundleId: String? = nil) {
        _ = sendCommand(4, bundleId: bundleId) // kMRNextTrack
        postMediaKey(key: 17) // NX_KEYTYPE_NEXT
    }

    static func previousTrack(bundleId: String? = nil) {
        _ = sendCommand(5, bundleId: bundleId) // kMRPreviousTrack
        postMediaKey(key: 18) // NX_KEYTYPE_PREVIOUS
    }

    static func postMediaKey(key: Int32) {
        func post(down: Bool) {
            let flags: NSEvent.ModifierFlags = down ? .init(rawValue: 0xa00) : .init(rawValue: 0xb00)
            let data1 = Int((key << 16) | (down ? 0xa00 : 0xb00))
            if let ev = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            ) {
                ev.cgEvent?.post(tap: .cghidEventTap)
            }
        }
        post(down: true)
        post(down: false)
    }
}

// MARK: - NowPlayingManager

@MainActor
final class NowPlayingManager: ObservableObject {
    static let shared = NowPlayingManager()

    @Published var isPlaying: Bool = false
    @Published var title: String = ""
    @Published var artist: String = ""
    @Published var album: String = ""
    @Published var player: String = ""          // "Spotify", "YouTube", "Apple Music"
    @Published var playerColor: String = "#10B981" // #10B981 (Spotify), #EF4444 (YouTube), #FA2D48 (Music)
    @Published var playerIcon: String = "music.note"
    @Published var mediaUrl: String = ""
    @Published var sourceBrowser: String = ""
    @Published var thumbnailUrl: String? = nil

    // Internal trackers
    private var spotifyIsPlaying = false
    private var spotifyTitle = ""
    private var spotifyArtist = ""
    private var spotifyAlbum = ""

    private var musicIsPlaying = false
    private var musicTitle = ""
    private var musicArtist = ""
    private var musicAlbum = ""

    private var youtubeTitle = ""
    private var youtubeArtist = ""
    private var youtubeUrl = ""
    private var youtubeBrowser = ""
    private var youtubeIsPlaying = false

    private var scanTask: Task<Void, Never>?
    private var commandCooldownUntil: Date = .distantPast
    private var lastYouTubeTabSeenAt: Date = .distantPast

    private init() {
        setupObservers()
        startPeriodicScanner()
    }

    deinit {
        scanTask?.cancel()
    }

    // MARK: - Observers (Spotify & Apple Music)

    private func setupObservers() {
        let center = DistributedNotificationCenter.default()

        // 1. Spotify
        center.addObserver(
            forName: NSNotification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, let userInfo = notification.userInfo else { return }
            let state = userInfo["Player State"] as? String ?? ""
            let playing = (state == "Playing" || state == "kPSP")
            self.spotifyIsPlaying = playing
            self.spotifyTitle = userInfo["Name"] as? String ?? ""
            self.spotifyArtist = userInfo["Artist"] as? String ?? ""
            self.spotifyAlbum = userInfo["Album"] as? String ?? ""

            self.recomputeActivePlayer()
        }

        // 2. Apple Music
        center.addObserver(
            forName: NSNotification.Name("com.apple.Music.playerInfo"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, let userInfo = notification.userInfo else { return }
            let state = userInfo["Player State"] as? String ?? ""
            let playing = (state == "Playing")
            self.musicIsPlaying = playing
            self.musicTitle = userInfo["Name"] as? String ?? ""
            self.musicArtist = userInfo["Artist"] as? String ?? ""
            self.musicAlbum = userInfo["Album"] as? String ?? ""

            self.recomputeActivePlayer()
        }

        // 3. System / Browser (YouTube in Chrome, Safari, Brave, Arc, Edge)
        MediaRemoteBridge.registerForNotifications()
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard Date() >= self.commandCooldownUntil else { return }
                let isSystemPlaying = await MediaRemoteBridge.isApplicationPlaying()
                // Re-check: a command may have been issued during the async call above.
                guard Date() >= self.commandCooldownUntil else { return }
                // YouTube play state is driven by DOM — MediaRemote not reliable for browsers
                if self.player != "YouTube" && !self.spotifyIsPlaying && !self.musicIsPlaying {
                    if self.youtubeIsPlaying != isSystemPlaying || self.isPlaying != isSystemPlaying {
                        self.youtubeIsPlaying = isSystemPlaying
                        self.isPlaying = isSystemPlaying
                    }
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("kMRMediaRemoteNowPlayingInfoDidChangeNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.scanForYouTubePlayback()
            }
        }
    }

    // MARK: - Browser Scanner (YouTube in Safari, Chrome, Arc, Brave, Edge, etc.)

    private func startPeriodicScanner() {
        scanTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 350_000_000) // 0.35s responsive loop
                guard let self else { break }
                if Date() >= self.commandCooldownUntil {
                    let isSystemPlaying = await MediaRemoteBridge.isApplicationPlaying()
                    // Re-check after await — a togglePlayPause() may have fired during the call.
                    if Date() >= self.commandCooldownUntil {
                        // YouTube play state is driven by DOM query in scanForYouTubePlayback — skip here
                        if !self.player.isEmpty && self.player != "Spotify" && self.player != "Apple Music" && self.player != "YouTube" {
                            self.isPlaying = isSystemPlaying
                        }
                    }
                }
                await self.scanForYouTubePlayback()
            }
        }
    }

    private func scanForYouTubePlayback() async {
        // Run script off-main-thread to keep UI 100% fluid
        let scanResult = await Task.detached(priority: .utility) { () -> String? in
            let browsers: [(name: String, bundleId: String, isSafari: Bool)] = [
                ("Safari", "com.apple.Safari", true),
                ("Google Chrome", "com.google.Chrome", false),
                ("Arc", "company.thebrowser.Browser", false),
                ("Brave Browser", "com.brave.Browser", false),
                ("Microsoft Edge", "com.microsoft.edgemac", false),
                ("Opera", "com.operasoftware.Opera", false),
                ("Vivaldi", "com.vivaldi.Vivaldi", false)
            ]

            let runningApps = NSWorkspace.shared.runningApplications
            let runningBundles = Set(runningApps.compactMap { $0.bundleIdentifier })

            for b in browsers where runningBundles.contains(b.bundleId) {
                let script: String
                if b.isSafari {
                    script = """
                    tell application "Safari"
                        if (count of windows) > 0 then
                            repeat with w in windows
                                repeat with t in tabs of w
                                    set u to URL of t
                                    if u contains "youtube.com/watch" or u contains "youtu.be" or u contains "youtube.com/live" or u contains "youtube.com/shorts" then
                                        try
                                            set isPaused to do JavaScript "document.querySelector('video')?.paused?.toString() ?? 'unknown'" in t
                                        on error
                                            set isPaused to "unknown"
                                        end try
                                        return "Safari|||" & name of t & "|||" & u & "|||" & isPaused
                                    end if
                                end repeat
                            end repeat
                        end if
                    end tell
                    return ""
                    """
                } else {
                    script = """
                    tell application "\(b.name)"
                        if (count of windows) > 0 then
                            repeat with w in windows
                                repeat with t in tabs of w
                                    set u to URL of t
                                    if u contains "youtube.com/watch" or u contains "youtu.be" or u contains "youtube.com/live" or u contains "youtube.com/shorts" then
                                        try
                                            set isPaused to execute t javascript "document.querySelector('video')?.paused?.toString() ?? 'unknown'"
                                        on error
                                            set isPaused to "unknown"
                                        end try
                                        return "\(b.name)|||" & title of t & "|||" & u & "|||" & isPaused
                                    end if
                                end repeat
                            end repeat
                        end if
                    end tell
                    return ""
                    """
                }

                var error: NSDictionary?
                if let appleScript = NSAppleScript(source: script) {
                    let result = appleScript.executeAndReturnError(&error)
                    if let str = result.stringValue, !str.isEmpty, str.contains("|||") {
                        return str
                    }
                }
            }
            return nil
        }.value

        if let scanResult {
            let parts = scanResult.components(separatedBy: "|||")
            if parts.count >= 3 {
                let browser = parts[0]
                let rawTitle = parts[1]
                let url = parts[2]

                let parsed = Self.parseYouTubeTitle(rawTitle)
                self.youtubeBrowser = browser
                self.youtubeTitle = parsed.title
                self.youtubeArtist = parsed.artist
                self.youtubeUrl = url
                self.lastYouTubeTabSeenAt = Date()

                if Date() >= self.commandCooldownUntil {
                    // "false" = video.paused is false = playing; "true" = paused
                    let domPausedRaw = parts.count >= 4 ? parts[3].trimmingCharacters(in: .whitespacesAndNewlines) : "unknown"
                    let domIsPlaying: Bool? = domPausedRaw == "false" ? true : (domPausedRaw == "true" ? false : nil)

                    if let isPlaying = domIsPlaying {
                        // DOM ground truth — no MediaRemote call needed
                        if self.youtubeIsPlaying != isPlaying {
                            self.youtubeIsPlaying = isPlaying
                            self.isPlaying = isPlaying
                        }
                    } else {
                        // JavaScript unavailable — fall back to MediaRemote
                        let isSystemPlaying = await MediaRemoteBridge.isApplicationPlaying()
                        if Date() >= self.commandCooldownUntil {
                            self.youtubeIsPlaying = isSystemPlaying
                            self.isPlaying = isSystemPlaying
                        }
                    }
                }
            }
        } else {
            // No YouTube tab found — skip during cooldown or if the tab was seen recently.
            // Chrome can briefly fail to respond to AppleScript while processing a MediaRemote
            // command, causing a transient "gone" read that would wrongly clear play state.
            guard Date() >= commandCooldownUntil else {
                recomputeActivePlayer()
                return
            }
            // Require the tab to be gone for at least 1.5s before clearing state, so a single
            // failed AppleScript scan right after a play command doesn't reset the UI.
            guard Date().timeIntervalSince(lastYouTubeTabSeenAt) > 1.5 else {
                recomputeActivePlayer()
                return
            }
            self.youtubeTitle = ""
            self.youtubeArtist = ""
            self.youtubeUrl = ""
            self.youtubeBrowser = ""
            self.youtubeIsPlaying = false
        }

        recomputeActivePlayer()
    }

    // MARK: - Title Sanitizer

    static func parseYouTubeTitle(_ raw: String) -> (title: String, artist: String) {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip notification badge like (1) or (99+)
        if let match = cleaned.range(of: #"^\(\d+\+?\)\s*"#, options: .regularExpression) {
            cleaned.removeSubrange(match)
        }
        // Strip trailing "- YouTube" or "| YouTube" or "• YouTube"
        if let match = cleaned.range(of: #"\s*[-|•]\s*YouTube.*$"#, options: [.regularExpression, .caseInsensitive]) {
            cleaned.removeSubrange(match)
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        let parts = cleaned.components(separatedBy: " - ")
        if parts.count == 2 {
            let artist = parts[0].trimmingCharacters(in: .whitespaces)
            let song = parts[1].trimmingCharacters(in: .whitespaces)
            return (title: song, artist: artist)
        }

        return (title: cleaned.isEmpty ? "YouTube Video" : cleaned, artist: "YouTube")
    }

    static func parseYouTubeVideoId(_ url: String) -> String? {
        if let match = url.range(of: #"(?:v=|\/vi\/|\/embed\/|\/shorts\/|youtu\.be\/|\/v\/|\/e\/|watch\?v=)([^#&?\/]{11})"#, options: .regularExpression) {
            let matched = String(url[match])
            let id = String(matched.suffix(11))
            if id.count == 11 { return id }
        }
        return nil
    }

    // MARK: - State Arbitration

    private func recomputeActivePlayer() {
        // Priority 1: Spotify if actively playing
        if spotifyIsPlaying {
            player = "Spotify"
            playerColor = "#10B981"
            playerIcon = "music.note"
            title = spotifyTitle
            artist = spotifyArtist
            album = spotifyAlbum
            mediaUrl = ""
            sourceBrowser = ""
            thumbnailUrl = nil
            isPlaying = true
            return
        }

        // Priority 2: Apple Music if actively playing
        if musicIsPlaying {
            player = "Apple Music"
            playerColor = "#FA2D48"
            playerIcon = "music.note"
            title = musicTitle
            artist = musicArtist
            album = musicAlbum
            mediaUrl = ""
            sourceBrowser = ""
            thumbnailUrl = nil
            isPlaying = true
            return
        }

        // Priority 3: YouTube if detected in any browser
        if !youtubeTitle.isEmpty {
            player = "YouTube"
            playerColor = "#EF4444"
            playerIcon = "play.rectangle.fill"
            title = youtubeTitle
            artist = youtubeArtist
            album = youtubeBrowser
            mediaUrl = youtubeUrl
            sourceBrowser = youtubeBrowser
            isPlaying = youtubeIsPlaying
            if let videoId = Self.parseYouTubeVideoId(youtubeUrl) {
                thumbnailUrl = "https://img.youtube.com/vi/\(videoId)/mqdefault.jpg"
            } else {
                thumbnailUrl = nil
            }
            return
        }

        // Don't reset to idle/paused while a playback command is in flight — the scan
        // may have transiently lost the YouTube tab while Chrome processed the command.
        if Date() < commandCooldownUntil { return }

        // Priority 4: Paused Spotify if recently active
        if !spotifyTitle.isEmpty {
            player = "Spotify"
            playerColor = "#10B981"
            playerIcon = "music.note"
            title = spotifyTitle
            artist = spotifyArtist
            album = spotifyAlbum
            mediaUrl = ""
            sourceBrowser = ""
            thumbnailUrl = nil
            isPlaying = false
            return
        }

        // Priority 5: Paused Music
        if !musicTitle.isEmpty {
            player = "Apple Music"
            playerColor = "#FA2D48"
            playerIcon = "music.note"
            title = musicTitle
            artist = musicArtist
            album = musicAlbum
            mediaUrl = ""
            sourceBrowser = ""
            thumbnailUrl = nil
            isPlaying = false
            return
        }

        // Idle state
        player = ""
        playerColor = "#10B981"
        playerIcon = "music.note"
        title = ""
        artist = ""
        album = ""
        mediaUrl = ""
        sourceBrowser = ""
        thumbnailUrl = nil
        isPlaying = false
    }

    // MARK: - Playback Controls

    private func bundleIdForCurrentPlayer() -> String? {
        if player == "Spotify" { return "com.spotify.client" }
        if player == "Apple Music" { return "com.apple.Music" }
        if player == "YouTube" {
            let browser = sourceBrowser.isEmpty ? youtubeBrowser : sourceBrowser
            switch browser {
            case "Google Chrome": return "com.google.Chrome"
            case "Safari": return "com.apple.Safari"
            case "Arc": return "company.thebrowser.Browser"
            case "Brave Browser": return "com.brave.Browser"
            case "Microsoft Edge": return "com.microsoft.edgemac"
            case "Opera": return "com.operasoftware.Opera"
            case "Vivaldi": return "com.vivaldi.Vivaldi"
            default: return "com.google.Chrome"
            }
        }
        return nil
    }

    func togglePlayPause() {
        let bundleId = bundleIdForCurrentPlayer()
        if player == "Spotify" {
            executeAppleScript("""
            if application "Spotify" is running then
                tell application "Spotify" to playpause
            end if
            """)
            isPlaying.toggle()
        } else if player == "Apple Music" {
            executeAppleScript("""
            if application "Music" is running then
                tell application "Music" to playpause
            end if
            """)
            isPlaying.toggle()
        } else {
            // YouTube / Browser / System:
            // Set cooldown before sending so the scanner doesn't undo the optimistic state
            // while the browser is processing the command (~100-400ms latency).
            commandCooldownUntil = Date().addingTimeInterval(1.5)
            if isPlaying {
                MediaRemoteBridge.pause(bundleId: bundleId)
                isPlaying = false
                youtubeIsPlaying = false
            } else {
                MediaRemoteBridge.play(bundleId: bundleId)
                isPlaying = true
                youtubeIsPlaying = true
            }
        }
    }

    private func wakeUpBrowserTab(browser: String) {
        guard !youtubeUrl.isEmpty else { return }
        if browser == "Google Chrome" || browser == "Brave Browser" || browser == "Microsoft Edge" || browser == "Arc" || browser == "Opera" || browser == "Vivaldi" {
            executeAppleScript("""
            tell application "\(browser)"
                if (count of windows) > 0 then
                    repeat with w in windows
                        set tabIdx to 1
                        repeat with t in tabs of w
                            if URL of t contains "youtube.com" then
                                set active tab index of w to tabIdx
                                exit repeat
                            end if
                            set tabIdx to tabIdx + 1
                        end repeat
                    end repeat
                end if
            end tell
            """)
        } else if browser == "Safari" {
            executeAppleScript("""
            tell application "Safari"
                if (count of windows) > 0 then
                    repeat with w in windows
                        set tabIdx to 1
                        repeat with t in tabs of w
                            if URL of t contains "youtube.com" then
                                set current tab of w to t
                                exit repeat
                            end if
                            set tabIdx to tabIdx + 1
                        end repeat
                    end repeat
                end if
            end tell
            """)
        }
    }

    func nextTrack() {
        if player == "Spotify" {
            executeAppleScript("""
            if application "Spotify" is running then
                tell application "Spotify" to next track
            end if
            """)
        } else if player == "Apple Music" {
            executeAppleScript("""
            if application "Music" is running then
                tell application "Music" to next track
            end if
            """)
        } else if player == "YouTube" {
            let bundleId = bundleIdForCurrentPlayer()
            MediaRemoteBridge.nextTrack(bundleId: bundleId)
        } else {
            MediaRemoteBridge.nextTrack()
        }
    }

    func previousTrack() {
        if player == "Spotify" {
            executeAppleScript("""
            if application "Spotify" is running then
                tell application "Spotify" to previous track
            end if
            """)
        } else if player == "Apple Music" {
            executeAppleScript("""
            if application "Music" is running then
                tell application "Music" to previous track
            end if
            """)
        } else if player == "YouTube" {
            let bundleId = bundleIdForCurrentPlayer()
            MediaRemoteBridge.previousTrack(bundleId: bundleId)
        } else {
            MediaRemoteBridge.previousTrack()
        }
    }

    func openActiveMedia() {
        if player == "Spotify" {
            if let url = URL(string: "spotify:") {
                NSWorkspace.shared.open(url)
            }
        } else if player == "Apple Music" {
            if let url = URL(string: "music:") {
                NSWorkspace.shared.open(url)
            }
        } else if player == "YouTube" {
            if !mediaUrl.isEmpty, let url = URL(string: mediaUrl) {
                NSWorkspace.shared.open(url)
            } else if !sourceBrowser.isEmpty {
                executeAppleScript("""
                tell application "\(sourceBrowser)" to activate
                """)
            }
        }
    }

    private func executeAppleScript(_ source: String) {
        if let script = NSAppleScript(source: source) {
            var error: NSDictionary?
            script.executeAndReturnError(&error)
        }
    }
}
