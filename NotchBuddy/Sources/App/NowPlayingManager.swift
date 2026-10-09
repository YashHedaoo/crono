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

    static func sendCommand(_ command: Int32) -> Bool {
        if let fn = sendCommandFunc {
            return fn(command, nil)
        }
        return false
    }

    static func togglePlayPause() {
        _ = sendCommand(2) // kMRTogglePlayPause
        postMediaKey(key: 16) // NX_KEYTYPE_PLAY
    }

    static func nextTrack() {
        _ = sendCommand(4) // kMRNextTrack
        postMediaKey(key: 17) // NX_KEYTYPE_NEXT
    }

    static func previousTrack() {
        _ = sendCommand(5) // kMRPreviousTrack
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
    }

    // MARK: - Browser Scanner (YouTube in Safari, Chrome, Arc, Brave, Edge, etc.)

    private func startPeriodicScanner() {
        scanTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2.0s
                guard let self else { break }
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
                                        return "Safari|||" & name of t & "|||" & u
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
                                        return "\(b.name)|||" & title of t & "|||" & u
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
                if !self.youtubeIsPlaying && self.player != "Spotify" && self.player != "Apple Music" {
                    self.youtubeIsPlaying = true
                }
            }
        } else {
            // No YouTube video tab open
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

    func togglePlayPause() {
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
        } else if player == "YouTube" {
            MediaRemoteBridge.togglePlayPause()
            youtubeIsPlaying.toggle()
            isPlaying = youtubeIsPlaying
        } else {
            MediaRemoteBridge.togglePlayPause()
            isPlaying.toggle()
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
            MediaRemoteBridge.nextTrack()
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
            MediaRemoteBridge.previousTrack()
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
