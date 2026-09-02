import AppKit
import Foundation

struct AppUpdate: Equatable, Sendable {
    var version: String
    var htmlURL: URL
    var downloadURL: URL?
    var assetName: String?
}

enum UpdateStatus: Equatable {
    case idle
    case checking
    case upToDate
    case available(AppUpdate)
    case downloading(Double?)
    case installing
    case failed(String)
}

enum Updater {
    static let owner = "hellorashid"
    static let repo = "oat"

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    static var isDevInstall: Bool {
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        return path.contains("/DerivedData/") || path.contains("/Build/Products/")
    }

    static func check() async throws -> AppUpdate? {
        let release = try await fetchLatest()
        guard let remote = SemVer(release.version) else {
            throw OatError.message("Latest GitHub release has an invalid version")
        }
        guard let local = SemVer(currentVersion) else { return release }
        return remote > local ? release : nil
    }

    static func download(
        _ update: AppUpdate,
        onProgress: @escaping @Sendable (Double?) -> Void
    ) async throws -> URL {
        guard let url = update.downloadURL else {
            throw OatError.message("This release has no macOS download")
        }
        let name = update.assetName ?? url.lastPathComponent
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("Oat-update-\(UUID().uuidString)-\(name)")
        try await FileDownload.run(from: url, to: destination, onProgress: onProgress)
        return destination
    }

    /// Replaces this install with the downloaded DMG/ZIP, then relaunches.
    static func install(from package: URL) throws {
        let extracted = try unpack(package)
        var handedOff = false
        defer {
            if !handedOff {
                extracted.cleanup()
            }
        }

        guard let newApp = extracted.app else {
            throw OatError.message("The download did not contain Oat.app")
        }
        if let identifier = Bundle(url: newApp)?.bundleIdentifier,
           let expected = Bundle.main.bundleIdentifier,
           identifier != expected {
            throw OatError.message("The download is not an Oat update")
        }

        let destination = installDestination()
        if isDevInstall {
            NSWorkspace.shared.open(package)
            throw OatError.message("Running from Xcode. Opened the download instead of replacing this build.")
        }

        if destination.resolvingSymlinksInPath() != Bundle.main.bundleURL.resolvingSymlinksInPath() {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: newApp, to: destination)
            stripQuarantine(destination)
            NSWorkspace.shared.open(destination)
            NSApp.terminate(nil)
            return
        }

        try launchReplacer(extracted: extracted, newApp: newApp, destination: destination)
        handedOff = true
        NSApp.terminate(nil)
    }

    static func openRelease(_ update: AppUpdate) {
        NSWorkspace.shared.open(update.htmlURL)
    }

    private static func installDestination() -> URL {
        let running = Bundle.main.bundleURL.resolvingSymlinksInPath()
        if running.path.contains("/AppTranslocation/") {
            return URL(fileURLWithPath: "/Applications/Oat.app")
        }
        if running.pathExtension == "app" {
            return running
        }
        return URL(fileURLWithPath: "/Applications/Oat.app")
    }

    private static func fetchLatest() async throws -> AppUpdate {
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest") else {
            throw OatError.message("Could not check for updates")
        }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 {
            throw OatError.message("No GitHub releases yet")
        }
        if status == 403 {
            throw OatError.message("GitHub rate-limited the update check. Try again in a few minutes.")
        }
        guard (200..<300).contains(status) else {
            throw OatError.message("Update check failed (\(status))")
        }

        let decoder = JSONDecoder()
        let payload = try decoder.decode(GitHubRelease.self, from: data)
        guard !payload.draft else {
            throw OatError.message("No published GitHub release")
        }

        let version = SemVer.normalize(payload.tagName)
        let asset = pickAsset(payload.assets)
        return AppUpdate(
            version: version,
            htmlURL: payload.htmlURL,
            downloadURL: asset?.browserDownloadURL,
            assetName: asset?.name
        )
    }

    private static var userAgent: String {
        "Oat/\(currentVersion) (+https://github.com/\(owner)/\(repo))"
    }

    private static func pickAsset(_ assets: [GitHubRelease.Asset]) -> GitHubRelease.Asset? {
        let dmgs = assets.filter { $0.name.lowercased().hasSuffix(".dmg") }
        let zips = assets.filter {
            let name = $0.name.lowercased()
            return name.hasSuffix(".zip") && !name.contains("source")
        }
        let pool = dmgs.isEmpty ? zips : dmgs
        guard !pool.isEmpty else { return nil }

        let ranked = pool.sorted { lhs, rhs in
            archScore(lhs.name) > archScore(rhs.name)
        }
        return ranked.first
    }

    private static func archScore(_ name: String) -> Int {
        let lower = name.lowercased()
        #if arch(arm64)
        if lower.contains("aarch64") || lower.contains("arm64") { return 3 }
        if lower.contains("x64") || lower.contains("x86") || lower.contains("intel") { return 0 }
        #else
        if lower.contains("x86_64") || lower.contains("x64") || lower.contains("intel") { return 3 }
        if lower.contains("aarch64") || lower.contains("arm64") { return 0 }
        #endif
        if lower.contains("universal") { return 2 }
        return 1
    }

    private static func unpack(_ package: URL) throws -> ExtractedApp {
        let name = package.lastPathComponent.lowercased()
        if name.hasSuffix(".dmg") {
            return try attachDMG(package)
        }
        if name.hasSuffix(".zip") {
            return try unzip(package)
        }
        throw OatError.message("Unsupported update package")
    }

    private static func attachDMG(_ url: URL) throws -> ExtractedApp {
        let result = try run(
            "/usr/bin/hdiutil",
            ["attach", "-nobrowse", "-readonly", "-plist", url.path]
        )
        guard result.status == 0 else {
            throw OatError.message("Could not open the update disk image")
        }
        guard let mount = mountPoint(fromPlist: result.stdout) else {
            throw OatError.message("Could not mount the update disk image")
        }
        return ExtractedApp(app: findApp(in: mount), mount: mount, scratch: nil)
    }

    private static func unzip(_ url: URL) throws -> ExtractedApp {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Oat-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let result = try run("/usr/bin/ditto", ["-xk", url.path, folder.path])
        guard result.status == 0 else {
            try? FileManager.default.removeItem(at: folder)
            throw OatError.message("Could not unpack the update")
        }
        return ExtractedApp(app: findApp(in: folder), mount: nil, scratch: folder)
    }

    private static func findApp(in directory: URL) -> URL? {
        let direct = directory.appendingPathComponent("Oat.app")
        if FileManager.default.fileExists(atPath: direct.path) {
            return direct
        }
        let items = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        if let match = items?.first(where: { $0.lastPathComponent == "Oat.app" }) {
            return match
        }
        return items?.first(where: { $0.pathExtension == "app" })
    }

    private static func mountPoint(fromPlist data: Data) -> URL? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]]
        else {
            return nil
        }
        for entity in entities {
            if let path = entity["mount-point"] as? String {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    private static func launchReplacer(extracted: ExtractedApp, newApp: URL, destination: URL) throws {
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("oat-update-\(UUID().uuidString).sh")
        let contents = """
        #!/bin/bash
        set -euo pipefail
        PID="$1"
        SRC="$2"
        DEST="$3"
        MOUNT="${4:-}"
        SCRATCH="${5:-}"
        while /usr/bin/kill -0 "$PID" 2>/dev/null; do
          sleep 0.2
        done
        sleep 0.4
        /bin/rm -rf "$DEST"
        /usr/bin/ditto "$SRC" "$DEST"
        /usr/bin/xattr -d -r com.apple.quarantine "$DEST" >/dev/null 2>&1 || true
        if [ -n "$MOUNT" ]; then
          /usr/bin/hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || true
        fi
        if [ -n "$SCRATCH" ]; then
          /bin/rm -rf "$SCRATCH"
        fi
        /usr/bin/open "$DEST"
        """
        try contents.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            script.path,
            "\(ProcessInfo.processInfo.processIdentifier)",
            newApp.path,
            destination.path,
            extracted.mount?.path ?? "",
            extracted.scratch?.path ?? "",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    private static func stripQuarantine(_ url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-d", "-r", "com.apple.quarantine", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    @discardableResult
    private static func run(_ launchPath: String, _ arguments: [String]) throws -> (status: Int32, stdout: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }
}

struct SemVer: Comparable, Sendable {
    var major: Int
    var minor: Int
    var patch: Int

    init?(_ string: String) {
        let parts = Self.normalize(string)
            .split(separator: ".")
            .prefix(3)
            .compactMap { Int($0) }
        guard let major = parts.first else { return nil }
        self.major = major
        self.minor = parts.count > 1 ? parts[1] : 0
        self.patch = parts.count > 2 ? parts[2] : 0
    }

    static func normalize(_ string: String) -> String {
        var value = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.first == "v" || value.first == "V" {
            value.removeFirst()
        }
        if let plus = value.firstIndex(of: "+") {
            value = String(value[..<plus])
        }
        if let dash = value.firstIndex(of: "-") {
            value = String(value[..<dash])
        }
        return value
    }

    static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

private struct GitHubRelease: Decodable {
    var tagName: String
    var htmlURL: URL
    var draft: Bool
    var assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case draft
        case assets
    }

    struct Asset: Decodable {
        var name: String
        var browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }
}

private struct ExtractedApp {
    var app: URL?
    var mount: URL?
    var scratch: URL?

    func cleanup() {
        if let mount {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            process.arguments = ["detach", mount.path, "-quiet"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }
        if let scratch {
            try? FileManager.default.removeItem(at: scratch)
        }
    }
}

private final class FileDownload: NSObject, URLSessionDownloadDelegate {
    private let destination: URL
    private let onProgress: @Sendable (Double?) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?

    static func run(
        from url: URL,
        to destination: URL,
        onProgress: @escaping @Sendable (Double?) -> Void
    ) async throws {
        let box = FileDownload(destination: destination, onProgress: onProgress)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                box.continuation = continuation
                let session = URLSession(configuration: .ephemeral, delegate: box, delegateQueue: nil)
                box.session = session
                var request = URLRequest(url: url)
                request.setValue(
                    "Oat/\(Updater.currentVersion) (+https://github.com/\(Updater.owner)/\(Updater.repo))",
                    forHTTPHeaderField: "User-Agent"
                )
                session.downloadTask(with: request).resume()
            }
        } onCancel: {
            box.session?.invalidateAndCancel()
        }
        box.session?.finishTasksAndInvalidate()
    }

    private init(destination: URL, onProgress: @escaping @Sendable (Double?) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if totalBytesExpectedToWrite > 0 {
            onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        } else {
            onProgress(nil)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            finish(error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(error)
            return
        }
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        if !(200..<300).contains(status) {
            finish(OatError.message("Download failed (\(status))"))
            return
        }
        finish(nil)
    }

    private func finish(_ error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }
}
