import AppKit
import CryptoKit
import SwiftUI

// Self-update from the GitHub releases of this repository: check, download the zipped app,
// verify it, swap the bundle in place and relaunch.

enum UpdateError: Error, CustomStringConvertible {
    case network(String), noArchive, digestMismatch, badArchive(String), notInApp, replace(String)
    var description: String {
        switch self {
        case .network(let text): return "sem resposta do GitHub (\(text))"
        case .noArchive: return "a versão publicada não traz o app"
        case .digestMismatch: return "o arquivo baixado não confere com o publicado"
        case .badArchive(let text): return "pacote inválido: \(text)"
        case .notInApp: return "este executável não está dentro de um .app"
        case .replace(let text): return "não foi possível trocar o app: \(text)"
        }
    }
}

enum UpdateEngine {
    static var runningVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static func latestRelease() async throws -> ReleaseInfo? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(updateRepository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("HomeLab/\(runningVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 404 { return nil }   // no release published yet
            guard code == 200 else { throw UpdateError.network("HTTP \(code)") }
            return try JSONDecoder().decode(ReleaseInfo.self, from: data)
        } catch let error as UpdateError {
            throw error
        } catch {
            throw UpdateError.network(error.localizedDescription)
        }
    }

    /// Downloads and checks the release's app, then puts it where the running app is.
    /// The old bundle is kept aside until the new one is in place, and restored if that fails.
    static func install(_ release: ReleaseInfo) async throws -> URL {
        guard let asset = release.appArchive, let source = URL(string: asset.browser_download_url) else { throw UpdateError.noArchive }
        let current = Bundle.main.bundleURL
        guard current.pathExtension == "app" else { throw UpdateError.notInApp }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("homelab-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let archive = work.appendingPathComponent("app.zip")
        do {
            let (downloaded, response) = try await URLSession.shared.download(from: source)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.network("download recusado") }
            try FileManager.default.moveItem(at: downloaded, to: archive)
        } catch let error as UpdateError {
            throw error
        } catch {
            throw UpdateError.network(error.localizedDescription)
        }
        // GitHub publishes the SHA-256 of each asset; a file that does not match is not installed.
        if let digest = asset.digest, digest.hasPrefix("sha256:") {
            let data = try Data(contentsOf: archive, options: .mappedIfSafe)
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard actual == digest.dropFirst(7).lowercased() else { throw UpdateError.digestMismatch }
        }
        let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
        guard await run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path], timeout: 120).ok else { throw UpdateError.badArchive("não descompactou") }
        let apps = (try? FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "app" } ?? []
        guard let fresh = apps.first, let bundle = Bundle(url: fresh) else { throw UpdateError.badArchive("sem .app dentro") }
        guard bundle.bundleIdentifier == Bundle.main.bundleIdentifier else { throw UpdateError.badArchive("é outro aplicativo") }
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        guard isNewer(version, than: runningVersion) else { throw UpdateError.badArchive("versão \(version) não é mais nova") }
        guard await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", fresh.path], timeout: 60).ok else {
            throw UpdateError.badArchive("assinatura quebrada")
        }

        let aside = work.appendingPathComponent("previous.app")
        do {
            try FileManager.default.moveItem(at: current, to: aside)
            do {
                try FileManager.default.moveItem(at: fresh, to: current)
            } catch {
                try? FileManager.default.moveItem(at: aside, to: current)
                throw error
            }
        } catch {
            throw UpdateError.replace(error.localizedDescription)
        }
        return current
    }
}

@MainActor
final class Updater: ObservableObject {
    enum State: Equatable {
        case idle, checking, upToDate, available(ReleaseInfo), installing(String), failed(String)
    }
    static let shared = Updater()
    @Published var state: State = .idle
    @Published var lastCheck: Date?

    var offer: ReleaseInfo? { if case .available(let release) = state { return release } else { return nil } }
    var busy: Bool { if case .installing = state { return true } else { return state == .checking } }

    private init() {
        // Quietly on launch, then twice a day while the app stays open.
        Task { [weak self] in
            while let self {
                await self.check(quiet: true)
                try? await Task.sleep(nanoseconds: 12 * 3600 * 1_000_000_000)
            }
        }
    }

    func check(quiet: Bool = false) async {
        guard !busy else { return }
        let before = state
        state = .checking
        do {
            let release = try await UpdateEngine.latestRelease()
            lastCheck = Date()
            state = updateOffer(release, running: UpdateEngine.runningVersion).map(State.available) ?? .upToDate
        } catch {
            // A background check that cannot reach GitHub should not nag.
            state = quiet ? (before == .checking ? .idle : before) : .failed(String(describing: error))
        }
    }

    func install() async {
        guard let release = offer else { return }
        state = .installing(release.version)
        do {
            let app = try await UpdateEngine.install(release)
            // Start the new copy once this one has gone.
            let relaunch = Process()
            relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
            relaunch.arguments = ["-c", "sleep 1; /usr/bin/open -n \"$0\"", app.path]
            try? relaunch.run()
            NSApplication.shared.terminate(nil)
        } catch {
            state = .failed(String(describing: error))
        }
    }
}

/// `HomeLab update-check` and `HomeLab update-install`: the updater without the interface,
/// for scripts and for testing a release. Neither relaunches anything.
func runUpdateCommand(_ command: String) -> Never {
    let done = DispatchSemaphore(value: 0)
    var code: Int32 = 0
    Task.detached {
        do {
            let release = try await UpdateEngine.latestRelease()
            let running = UpdateEngine.runningVersion
            print("running: \(running)")
            print("latest:  \(release?.version ?? "none published")")
            guard let offer = updateOffer(release, running: running) else {
                print("update:  none")
                done.signal()
                return
            }
            print("update:  \(offer.version) (\(offer.appArchive?.name ?? ""))")
            if command == "update-install" {
                let app = try await UpdateEngine.install(offer)
                let installed = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] ?? "?"
                print("installed: \(installed) at \(app.path)")
            }
        } catch {
            print("error: \(error)")
            code = 1
        }
        done.signal()
    }
    done.wait()
    exit(code)
}
