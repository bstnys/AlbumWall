// AlbumWall — an interactive album-cover wallpaper for macOS.
// A WKWebView sits at desktop level (under the icons). It never takes mouse
// events itself; instead the app watches the cursor and forwards moves, clicks
// to the page whenever they land on bare desktop.

import Cocoa
import WebKit
import ServiceManagement

let coversDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Pictures/AlbumWall", isDirectory: true)
let imageExts: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "heic", "avif"]

func webDir() -> URL {
    if let res = Bundle.main.resourceURL?.appendingPathComponent("web"),
       FileManager.default.fileExists(atPath: res.appendingPathComponent("index.html").path) { return res }
    return URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("web")
}

func mime(_ ext: String) -> String {
    switch ext.lowercased() {
    case "html": return "text/html; charset=utf-8"
    case "js": return "text/javascript"
    case "css": return "text/css"
    case "json": return "application/json"
    case "jpg", "jpeg": return "image/jpeg"
    case "png": return "image/png"
    case "webp": return "image/webp"
    case "gif": return "image/gif"
    case "heic": return "image/heic"
    case "avif": return "image/avif"
    default: return "application/octet-stream"
    }
}

// Serves the page, the covers folder and now-playing artwork from one origin (wall://app),
// so the page can read pixel colors from every image.
final class SchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let path = url.path
        func reply(_ data: Data?, _ type: String) {
            let ok = data != nil
            let resp = HTTPURLResponse(url: url, statusCode: ok ? 200 : 404, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": type, "Cache-Control": "no-store"])!
            task.didReceive(resp)
            task.didReceive(data ?? Data())
            task.didFinish()
        }
        if path == "/covers.json" {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: coversDir.path)) ?? []
            let list = files.filter { imageExts.contains(($0 as NSString).pathExtension.lowercased()) }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            reply(try? JSONSerialization.data(withJSONObject: list), mime("json"))
        } else if path.hasPrefix("/covers/") {
            let name = url.lastPathComponent  // no sub-paths, no traversal
            reply(try? Data(contentsOf: coversDir.appendingPathComponent(name)), mime((name as NSString).pathExtension))
        } else if path.hasPrefix("/music-art/") {
            // Apple Music artwork, held in memory
            guard let art = NowPlaying.musicArt, art.id == url.lastPathComponent else { return reply(nil, "text/plain") }
            reply(art.data, art.data.starts(with: [0x89, 0x50]) ? "image/png" : "image/jpeg")
        } else if path == "/remote" {
            // Spotify artwork proxy (Spotify's image CDN only)
            let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "u" }?.value
            guard let s = q, let remote = URL(string: s), remote.scheme == "https",
                  let host = remote.host, host.hasSuffix("scdn.co") || host.hasSuffix("spotifycdn.com") else {
                return reply(nil, "text/plain")
            }
            URLSession.shared.dataTask(with: remote) { data, resp, _ in
                let type = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? "image/jpeg"
                DispatchQueue.main.async { reply(data, type) }
            }.resume()
        } else {
            let rel = path == "/" ? "index.html" : String(path.dropFirst())
            let file = webDir().appendingPathComponent(rel).standardizedFileURL
            guard file.path.hasPrefix(webDir().standardizedFileURL.path) else { return reply(nil, "text/plain") }
            reply(try? Data(contentsOf: file), mime(file.pathExtension))
        }
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

final class Bridge: NSObject, WKScriptMessageHandler {
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let body = m.body as? [String: Any], let cmd = body["cmd"] as? String else { return }
        switch cmd {
        case "hello":       // page (re)loaded: resend the current track
            delegate.lastTrack = ""
            delegate.pollPlayers()
        case "playpause":
            delegate.currentPlayer?.playpause()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { delegate.pollPlayers() }
        default: break
        }
    }
}

// MARK: music players (AppleScript — never launches an app that isn't already running)
enum Player: String {
    case spotify, music

    var bundleID: String { self == .spotify ? "com.spotify.client" : "com.apple.Music" }
    var appName: String { self == .spotify ? "Spotify" : "Music" }
    var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }

    @discardableResult func run(_ body: String) -> NSAppleEventDescriptor? {
        guard isRunning else { return nil }
        var err: NSDictionary?
        return NSAppleScript(source: "tell application \"\(appName)\"\n\(body)\nend tell")?.executeAndReturnError(&err)
    }
    func playpause() { run("playpause") }
}

struct Track {
    let player: Player
    let src: String       // URL the page loads the cover from ("" = no artwork)
    let playing: Bool
    var json: String {
        let d = try? JSONSerialization.data(withJSONObject: ["src": src, "playing": playing, "player": player.rawValue])
        return d.flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }
}

enum NowPlaying {
    /// Apple Music hands over artwork as raw bytes; keep the current one in memory.
    static var musicArt: (id: String, data: Data)?

    static func spotify() -> Track? {
        let script = """
        if player state is stopped then return ""
        set t to current track
        return (artwork url of t) & linefeed & (player state as string)
        """
        guard let out = Player.spotify.run(script)?.stringValue, !out.isEmpty else { return nil }
        let p = out.components(separatedBy: "\n")
        guard p.count >= 2 else { return nil }
        let src = p[0].isEmpty ? "" : "remote?u=" + (p[0].addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
        return Track(player: .spotify, src: src, playing: p[1] == "playing")
    }

    static func music() -> Track? {
        let script = """
        if player state is stopped then return ""
        set t to current track
        set n to 0
        try
          set n to count of artworks of t
        end try
        return (persistent ID of t) & linefeed & (player state as string) & linefeed & (n as string)
        """
        guard let out = Player.music.run(script)?.stringValue, !out.isEmpty else { return nil }
        let p = out.components(separatedBy: "\n")
        guard p.count >= 3 else { return nil }
        let id = p[0], playing = p[1] == "playing"
        if musicArt?.id != id {
            musicArt = nil
            if (Int(p[2]) ?? 0) > 0,
               let data = Player.music.run("return raw data of artwork 1 of current track")?.data, !data.isEmpty {
                musicArt = (id, data)
            }
        }
        return Track(player: .music, src: musicArt?.id == id ? "music-art/\(id)" : "", playing: playing)
    }

    /// Whichever app is actually playing wins (Spotify on a tie); otherwise a paused one.
    static func current() -> Track? {
        let s = spotify(), m = music()
        if let s, s.playing { return s }
        if let m, m.playing { return m }
        return s ?? m
    }
}

final class WallWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var walls: [(NSWindow, WKWebView)] = []
    var lastMouse = NSPoint(x: -1, y: -1)
    var statusItem: NSStatusItem!
    var folderWatch: DispatchSourceFileSystemObject?
    var reloadWork: DispatchWorkItem?
    var lastTrack = ""
    var currentPlayer: Player?
    let scheme = SchemeHandler()
    let bridge = Bridge()

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        try? FileManager.default.createDirectory(at: coversDir, withIntermediateDirectories: true)
        buildWindows()
        setupMenu()
        watchFolder()

        // cursor position → page (no permissions needed)
        Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.pollMouse() }
        // clicks that reach the bare desktop
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] e in
            self?.handleGlobal(e)
        }
        // Spotify / Apple Music cover sync
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.pollPlayers() }

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.buildWindows() }
    }

    // MARK: windows
    func buildWindows() {
        walls.forEach { $0.0.orderOut(nil) }
        walls = NSScreen.screens.map { screen in
            let win = WallWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            win.setFrame(screen.frame, display: false)
            win.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
            win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
            win.ignoresMouseEvents = true
            win.backgroundColor = NSColor(calibratedRed: 0.29, green: 0.44, blue: 0.59, alpha: 1)
            win.isReleasedWhenClosed = false

            let cfg = WKWebViewConfiguration()
            cfg.setURLSchemeHandler(scheme, forURLScheme: "wall")
            cfg.userContentController.add(bridge, name: "wall")
            let web = WKWebView(frame: win.contentView!.bounds, configuration: cfg)
            web.autoresizingMask = [.width, .height]
            web.setValue(false, forKey: "drawsBackground")
            win.contentView = web
            web.load(URLRequest(url: URL(string: "wall://app/index.html")!))
            win.orderFrontRegardless()
            return (win, web)
        }
    }

    func reloadAll() { walls.forEach { $0.1.reload() } }

    // MARK: input forwarding
    /// True when a normal app window covers this point (CG / top-left coordinates).
    func isCovered(_ p: NSPoint) -> Bool {
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let cg = CGPoint(x: p.x, y: primaryH - p.y)
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        for w in list {
            guard let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? Int32, pid != me,
                  let alpha = w[kCGWindowAlpha as String] as? Double, alpha > 0.01,
                  let b = w[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: b as CFDictionary) else { continue }
            if rect.contains(cg) { return true }
        }
        return false
    }

    func target(for p: NSPoint) -> (WKWebView, CGFloat, CGFloat)? {
        for (win, web) in walls where NSMouseInRect(p, win.frame, false) {
            return (web, p.x - win.frame.minX, win.frame.maxY - p.y)
        }
        return nil
    }

    func pollMouse() {
        let p = NSEvent.mouseLocation
        guard p != lastMouse else { return }
        lastMouse = p
        let covered = isCovered(p)
        for (win, web) in walls {
            if NSMouseInRect(p, win.frame, false) {
                let x = p.x - win.frame.minX, y = win.frame.maxY - p.y
                web.evaluateJavaScript("window.albumWall&&albumWall.move(\(x),\(y),\(covered))")
            } else {
                web.evaluateJavaScript("window.albumWall&&albumWall.leave()")
            }
        }
    }

    func handleGlobal(_ e: NSEvent) {
        let p = NSEvent.mouseLocation
        guard !isCovered(p), let (web, x, y) = target(for: p) else { return }
        web.evaluateJavaScript("window.albumWall&&albumWall.click(\(x),\(y))")
    }

    // MARK: now playing
    func pollPlayers() {
        let track = NowPlaying.current()
        currentPlayer = track?.player
        let json = track?.json ?? "null"
        guard json != lastTrack else { return }
        lastTrack = json
        walls.forEach { $0.1.evaluateJavaScript("window.albumWall&&albumWall.nowPlaying(\(json))") }
    }

    // MARK: covers folder
    func watchFolder() {
        let fd = open(coversDir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        src.setEventHandler { [weak self] in
            self?.reloadWork?.cancel()
            let w = DispatchWorkItem { self?.reloadAll() }
            self?.reloadWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: w)
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        folderWatch = src
    }

    // MARK: menu bar
    func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "opticaldisc", accessibilityDescription: "Album Wall")
        rebuildMenu()
    }
    func rebuildMenu() {
        let m = NSMenu()
        m.addItem(withTitle: "앨범 커버 폴더 열기", action: #selector(openFolder), keyEquivalent: "o").target = self
        m.addItem(withTitle: "새로고침", action: #selector(reload), keyEquivalent: "r").target = self
        m.addItem(.separator())
        if #available(macOS 13, *) {
            let li = m.addItem(withTitle: "로그인 시 자동 실행", action: #selector(toggleLogin), keyEquivalent: "")
            li.target = self; li.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }
        m.addItem(.separator())
        m.addItem(withTitle: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = m
    }
    @objc func openFolder() { NSWorkspace.shared.open(coversDir) }
    @objc func reload() { reloadAll() }
    @objc func toggleLogin() {
        if #available(macOS 13, *) {
            let s = SMAppService.mainApp
            do { if s.status == .enabled { try s.unregister() } else { try s.register() } }
            catch { NSLog("login item: \(error)") }
            rebuildMenu()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
