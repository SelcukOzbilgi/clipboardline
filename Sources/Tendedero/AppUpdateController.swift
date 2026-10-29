import AppKit
import Combine

private enum UpdateClientError: Error, LocalizedError, Equatable {
    case unavailable, authorization, response, tooLarge, keychain, invalidToken, saveEdits
    var errorDescription: String? {
        switch self {
        case .unavailable: L("Updates are available in the installed review app.")
        case .authorization: L("GitHub could not access the private repository. Add a token with Contents: Read-only access to this repository.")
        case .response: L("GitHub could not complete the update request. Try again later.")
        case .tooLarge: L("The update download has an unexpected size.")
        case .keychain: L("The GitHub token could not be accessed in Keychain.")
        case .invalidToken: L("Enter a valid GitHub access token.")
        case .saveEdits: L("Save your open edits before installing the update.")
        }
    }
}

/// Only the frozen, mutually verified XPC broker accesses the user's token.
/// Updating the app does not change the executable that Keychain authorizes.
private final class UpdateCredentialCompletion<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }
    func finish(_ result: Result<Value, Error>) {
        lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
        pending?.resume(with: result)
    }
}

/// Broker/Keychain IPC can block even when interactive UI is forbidden. Keep
/// it off MainActor and bound the caller's waiting time. A timed-out worker is
/// never overlapped by another credential operation until it returns.
final class UpdateCredentialStore: @unchecked Sendable {
    static let live = UpdateCredentialStore(load: { try UpdateCredentialBrokerClient.live.readToken() },
        save: { try UpdateCredentialBrokerClient.live.writeToken($0) }, remove: { try UpdateCredentialBrokerClient.live.deleteToken() },
        authorize: { try UpdateCredentialBrokerClient.live.readToken(allowInteraction: true) })
    private let queue = DispatchQueue(label: "local.clipboardline.update-credentials", qos: .utility)
    private let lock = NSLock()
    private var inFlight = false
    private let timeout: TimeInterval
    private let read: @Sendable () throws -> String?
    private let write: @Sendable (String) throws -> Void
    private let erase: @Sendable () throws -> Void
    private let authorizeRead: @Sendable () throws -> String?

    init(timeout: TimeInterval = 15, load: @escaping @Sendable () throws -> String?,
         save: @escaping @Sendable (String) throws -> Void, remove: @escaping @Sendable () throws -> Void,
         authorize: (@Sendable () throws -> String?)? = nil) {
        self.timeout = timeout.isFinite ? max(0.01, min(60, timeout)) : 15
        read = load; write = save; erase = remove; authorizeRead = authorize ?? load
    }
    func load() async throws -> String? { try await perform(read) }
    func save(_ token: String) async throws { try await perform { [write] in try write(token) } }
    func remove() async throws { try await perform(erase) }
    func authorize() async throws -> String? { try await perform(authorizeRead, deadline: 150) }

    private func reserve() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !inFlight else { return false }; inFlight = true; return true
    }
    private func release() { lock.lock(); inFlight = false; lock.unlock() }
    private func perform<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value, deadline: TimeInterval? = nil) async throws -> Value {
        guard reserve() else { throw UpdateClientError.keychain }
        return try await withCheckedThrowingContinuation { continuation in
            let completion = UpdateCredentialCompletion<Value>(continuation)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + (deadline ?? timeout)) {
                completion.finish(.failure(UpdateClientError.keychain))
            }
            queue.async { [self] in
                let result = Result { try operation() }
                release(); completion.finish(result)
            }
        }
    }
}

/// Credentials are deliberately stripped on every redirect, including redirects
/// between GitHub hosts. GitHub's signed asset CDN URLs need no bearer token.
class UpdateRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let hosts = ["github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com"]
        guard let url = request.url, url.scheme == "https", let host = url.host,
              hosts.contains(host), url.user == nil, url.password == nil, url.port == nil else {
            completionHandler(nil); return
        }
        var clean = request
        clean.setValue(nil, forHTTPHeaderField: "Authorization")
        clean.setValue(nil, forHTTPHeaderField: "Cookie")
        completionHandler(clean)
    }
}

final class UpdateDownloadObserver: UpdateRedirectGuard, URLSessionDownloadDelegate {
    let limit: Int64
    let progress: @Sendable (Double) -> Void
    init(limit: Int64, progress: @escaping @Sendable (Double) -> Void) { self.limit = limit; self.progress = progress }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesWritten <= limit, totalBytesExpectedToWrite <= limit else { downloadTask.cancel(); return }
        progress(min(1, Double(totalBytesWritten) / Double(limit)))
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

@MainActor
final class AppUpdateController: ObservableObject {
    struct AvailableUpdate {
        let manifest: UpdateManifest
        let asset: GitHubUpdateAsset
        let releaseURL: URL
    }
    let enabled: Bool
    @Published private(set) var status = L("Check for an update when you are ready.")
    @Published private(set) var error: String?
    @Published private(set) var available: AvailableUpdate?
    @Published private(set) var busy = false
    @Published private(set) var progress: Double?
    @Published private(set) var needsAuthorization = false
    @Published private(set) var hasSavedToken = false
    @Published private(set) var automaticChecksEnabled: Bool
    @Published private(set) var lastSuccessfulCheck: Date? = nil
    var canQuit: () -> Bool = { true }
    /// Called only for a verified newer offer. Acknowledgement distinguishes a
    /// delivered notice/terminal permission denial from cancellation or a
    /// transient delivery failure, so unfinished delivery can be retried.
    var onAutomaticUpdateAvailable: ((AvailableUpdate, @escaping (Bool) -> Void) -> Void)?
    private var task: Task<Void, Never>?
    private var automaticTimer: Task<Void, Never>?
    private var automaticLifecycleStarted = false
    private var automaticGeneration = 0
    private var runningAutomaticGeneration: Int?
    private var automaticNotification: (build: Int, identifier: UUID, generation: Int)?
    private let credentials: UpdateCredentialStore
    private let configured: (() -> (UpdateRepository, Data, Int)?)?
    private let fetchOverride: (@Sendable (URL, String?, Int, Bool) async throws -> Data)?
    private let defaults: UserDefaults
    private let now: () -> Date
    private let startupDelay: TimeInterval
    private let automaticInterval: TimeInterval
    private let automaticBusyRetryDelay: TimeInterval
    #if canImport(Sparkle)
    private var nativeUpdater: SparkleUpdateDriver?
    private var nativeObservation: AnyCancellable?
    #endif
    @Published private(set) var nativeAvailableVersion: String?
    @Published private(set) var nativeAvailableBuild: Int?
    var onPublicUpdateAvailable: ((String, Int) -> Void)?

    var usesPublicUpdates: Bool {
        #if canImport(Sparkle)
        nativeUpdater != nil
        #else
        false
        #endif
    }
    var availableVersion: String? { nativeAvailableVersion ?? available?.manifest.version }
    var availableBuild: Int? { nativeAvailableBuild ?? available?.manifest.build }
    var releaseNotesURL: URL? {
        usesPublicUpdates ? URL(string: "https://github.com/\(PublicUpdateChannel.repository)/releases") : available?.releaseURL
    }

    /// Keep the authenticated envelope, not just decoded mutable version fields.
    /// It is reverified against the installed key/build before restoring an offer.
    private struct StoredUpdate: Codable {
        let envelope: Data
        let tag: String
        let assetID: Int
        let assetName: String
        let assetSize: Int64
        let assetURL: URL
        let browserURL: URL
    }

    init(enabled: Bool = true, credentials: UpdateCredentialStore = .live,
         configuration: (() -> (UpdateRepository, Data, Int)?)? = nil,
         fetch: (@Sendable (URL, String?, Int, Bool) async throws -> Data)? = nil,
         defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init,
         startupDelay: TimeInterval = AutomaticUpdateSchedule.startupDelay,
         automaticInterval: TimeInterval = AutomaticUpdateSchedule.interval,
         automaticBusyRetryDelay: TimeInterval = AutomaticUpdateSchedule.busyRetryDelay) {
        self.enabled = enabled; self.credentials = credentials; configured = configuration; fetchOverride = fetch
        self.defaults = defaults; self.now = now
        self.startupDelay = AutomaticUpdateSchedule.bounded(startupDelay, fallback: AutomaticUpdateSchedule.startupDelay)
        self.automaticInterval = max(0.01, AutomaticUpdateSchedule.bounded(automaticInterval, fallback: AutomaticUpdateSchedule.interval))
        self.automaticBusyRetryDelay = max(0.01, AutomaticUpdateSchedule.bounded(automaticBusyRetryDelay, fallback: AutomaticUpdateSchedule.busyRetryDelay))
        automaticChecksEnabled = enabled && ((defaults.object(forKey: AutomaticUpdateSchedule.preferenceKey) as? Bool) ?? true)
        if enabled, let date = defaults.object(forKey: AutomaticUpdateSchedule.lastSuccessfulCheckKey) as? Date,
           date.timeIntervalSince1970.isFinite { lastSuccessfulCheck = date }
        #if canImport(Sparkle)
        if configuration == nil, fetch == nil {
            nativeUpdater = SparkleUpdateDriver(enabled: enabled, defaults: defaults)
            if let nativeUpdater {
                nativeUpdater.canQuit = { [weak self] in self?.canQuit() ?? false }
                nativeUpdater.onAvailable = { [weak self] version, build in
                    self?.onPublicUpdateAvailable?(version, build)
                }
                observeNativeState(nativeUpdater.states)
            }
        }
        #endif
        if !usesPublicUpdates { restoreAvailableUpdate() }
    }
    deinit { automaticTimer?.cancel(); task?.cancel() }
    var isConfigured: Bool { usesPublicUpdates || configuration != nil }

    #if canImport(Sparkle)
    /// Keep Settings, menu actions and notifications on the same emitted state.
    /// Do not defer a will-change read to the default run-loop mode: Sparkle's
    /// native alerts may keep that mode inactive while the check has finished.
    func observeNativeState(_ states: AnyPublisher<SparkleUpdateDriver.State, Never>) {
        nativeObservation = states.sink { [weak self] state in self?.applyNativeState(state) }
    }

    private func refreshNativeState() {
        guard let nativeUpdater else { return }
        applyNativeState(nativeUpdater.state)
    }

    private func applyNativeState(_ state: SparkleUpdateDriver.State) {
        status = state.status; error = state.error
        busy = state.busy; progress = nil
        nativeAvailableVersion = state.availableVersion
        nativeAvailableBuild = state.availableBuild
        automaticChecksEnabled = state.automaticChecksEnabled
        lastSuccessfulCheck = state.lastSuccessfulCheck
        needsAuthorization = false
    }
    #endif

    func setAutomaticChecksEnabled(_ value: Bool) {
        #if canImport(Sparkle)
        if let nativeUpdater { nativeUpdater.setAutomaticChecksEnabled(value); refreshNativeState(); return }
        #endif
        guard enabled, automaticChecksEnabled != value else { return }
        automaticChecksEnabled = value
        defaults.set(value, forKey: AutomaticUpdateSchedule.preferenceKey)
        cancelAutomaticWork()
        if value && automaticLifecycleStarted { scheduleAutomaticCheck(after: startupDelay) }
    }

    /// Safe to call repeatedly. Disabled UI harnesses never read a configuration,
    /// start a credential operation, or create network traffic.
    func startAutomaticChecks() {
        #if canImport(Sparkle)
        if let nativeUpdater { nativeUpdater.start(); refreshNativeState(); return }
        #endif
        guard enabled, !automaticLifecycleStarted else { return }
        automaticLifecycleStarted = true
        guard automaticChecksEnabled, configuration != nil else { return }
        notifyAboutAutomaticOfferIfNeeded()
        scheduleAutomaticCheck(after: startupDelay)
    }

    /// Ends only automatic work. A user's manual check, authorization, or install
    /// is independent of this preference and is allowed to finish.
    func stopAutomaticChecks() {
        #if canImport(Sparkle)
        if let nativeUpdater { nativeUpdater.stop(); return }
        #endif
        automaticLifecycleStarted = false
        cancelAutomaticWork()
    }

    func recheckAutomaticUpdatesAfterWake() {
        #if canImport(Sparkle)
        if let nativeUpdater { nativeUpdater.refreshWhenShown(); return }
        #endif
        guard enabled, automaticLifecycleStarted, automaticChecksEnabled, configuration != nil else { return }
        let lastAttempt = defaults.object(forKey: AutomaticUpdateSchedule.lastAttemptKey) as? Date
        let delay = lastAttempt.map { AutomaticUpdateSchedule.delay(now: now(), lastAttempt: $0, interval: automaticInterval) } ?? startupDelay
        scheduleAutomaticCheck(after: delay)
    }

    private func cancelAutomaticWork() {
        automaticGeneration &+= 1
        automaticTimer?.cancel(); automaticTimer = nil
        automaticNotification = nil
        if runningAutomaticGeneration != nil { task?.cancel() }
    }

    private func scheduleAutomaticCheck(after delay: TimeInterval) {
        automaticTimer?.cancel(); automaticTimer = nil
        guard enabled, automaticLifecycleStarted, automaticChecksEnabled else { return }
        let generation = automaticGeneration
        automaticTimer = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000)) }
            catch { return }
            guard let self, !Task.isCancelled, self.automaticGeneration == generation else { return }
            self.automaticTimer = nil
            guard !self.busy else { self.scheduleAutomaticCheck(after: self.automaticBusyRetryDelay); return }
            self.beginCheck(automatic: generation)
        }
    }

    private func scheduleNextAutomaticCheck() {
        let lastAttempt = defaults.object(forKey: AutomaticUpdateSchedule.lastAttemptKey) as? Date
        scheduleAutomaticCheck(after: AutomaticUpdateSchedule.delay(now: now(), lastAttempt: lastAttempt, interval: automaticInterval))
    }

    private func checkIsCurrent(_ generation: Int?) -> Bool {
        guard !Task.isCancelled else { return false }
        guard let generation else { return true }
        return automaticLifecycleStarted && automaticChecksEnabled && automaticGeneration == generation
    }

    private func notifyAboutAutomaticOfferIfNeeded() {
        guard automaticLifecycleStarted, automaticChecksEnabled, let offer = available,
              offer.manifest.build > defaults.integer(forKey: AutomaticUpdateSchedule.notifiedBuildKey),
              let notify = onAutomaticUpdateAvailable else { return }
        guard automaticNotification?.build != offer.manifest.build else { return }
        let identifier = UUID(), generation = automaticGeneration, build = offer.manifest.build
        automaticNotification = (build, identifier, generation)
        notify(offer) { [weak self] delivered in
            guard let self, let pending = self.automaticNotification,
                  pending.identifier == identifier, pending.generation == generation,
                  self.automaticGeneration == generation,
                  self.automaticLifecycleStarted, self.automaticChecksEnabled else { return }
            self.automaticNotification = nil
            if delivered {
                self.defaults.set(max(build, self.defaults.integer(forKey: AutomaticUpdateSchedule.notifiedBuildKey)),
                                  forKey: AutomaticUpdateSchedule.notifiedBuildKey)
            }
        }
    }

    private func restoreAvailableUpdate() {
        guard enabled, let bytes = defaults.data(forKey: AutomaticUpdateSchedule.availableUpdateKey), bytes.count <= 131_072,
              let stored = try? JSONDecoder().decode(StoredUpdate.self, from: bytes),
              let (repository, key, build) = configuration,
              let manifest = try? AppUpdatePolicy.verifyManifest(data: stored.envelope, publicKey: key, repository: repository, currentBuild: build) else { return }
        let asset = GitHubUpdateAsset(id: stored.assetID, name: stored.assetName, size: stored.assetSize, url: stored.assetURL, browserDownloadURL: stored.browserURL)
        guard asset.name == manifest.archiveName, asset.size == manifest.archiveSize,
              repository.acceptsAsset(asset, tag: stored.tag), let releaseURL = try? repository.releaseURL(tag: stored.tag) else { return }
        available = AvailableUpdate(manifest: manifest, asset: asset, releaseURL: releaseURL)
        status = String(format: L("Version %@ is ready to install."), manifest.version)
    }

    private func storeAvailableUpdate(_ update: AvailableUpdate, envelope: Data, tag: String) {
        let stored = StoredUpdate(envelope: envelope, tag: tag, assetID: update.asset.id, assetName: update.asset.name,
                                  assetSize: update.asset.size, assetURL: update.asset.url, browserURL: update.asset.browserDownloadURL)
        if let data = try? JSONEncoder().encode(stored), data.count <= 131_072 {
            defaults.set(data, forKey: AutomaticUpdateSchedule.availableUpdateKey)
        }
    }

    private var configuration: (UpdateRepository, Data, Int)? {
        guard enabled else { return nil }
        if let configured { return configured() }
        return Self.bundledConfiguration(info: Bundle.main.infoDictionary ?? [:], build: AppIdentity.build)
    }

    /// Only the official bundle ID may enable the private GitHub updater.
    nonisolated static func bundledConfiguration(info: [String: Any], build: String) -> (UpdateRepository, Data, Int)? {
        guard info["CFBundleIdentifier"] as? String == "local.clipboardline.review",
              let slug = info["ClipboardLineUpdateRepository"] as? String,
              let encoded = info["ClipboardLineUpdatePublicKey"] as? String,
              let key = Data(base64Encoded: encoded), key.count == 32,
              let build = Int(build) else { return nil }
        let parts = slug.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let repository = try? UpdateRepository(owner: String(parts[0]), name: String(parts[1])) else { return nil }
        return (repository, key, build)
    }

    func saveToken(_ value: String) {
        guard enabled, !busy, !usesPublicUpdates else { return }
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            guard (10...512).contains(token.count), token.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { throw UpdateClientError.invalidToken }
            busy = true; error = nil
            task = Task { [weak self] in
                guard let self else { return }
                defer { self.busy = false; self.task = nil }
                do {
                    try await self.credentials.save(token)
                    self.hasSavedToken = true; self.needsAuthorization = false; self.error = nil
                    self.status = L("GitHub token saved in Keychain.")
                } catch { self.credentialFailure(error) }
            }
        } catch { self.error = error.localizedDescription }
    }
    func disconnect() {
        guard enabled, !busy, !usesPublicUpdates else { return }
        busy = true; error = nil
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.busy = false; self.task = nil }
            do {
                try await self.credentials.remove(); self.hasSavedToken = false; self.error = nil
                self.status = L("GitHub token removed from this Mac.")
            } catch { self.credentialFailure(error) }
        }
    }

    /// This is the only read that may request macOS approval, and is called
    /// solely by the user's explicit Authorize saved token button.
    func authorizeSavedToken() {
        guard enabled, !busy, !usesPublicUpdates, configuration != nil else { return }
        busy = true; error = nil
        task = Task { [weak self] in
            guard let self else { return }
            var authorized = false
            defer {
                self.busy = false; self.task = nil
                if authorized { self.manualCheck() }
            }
            do {
                guard try await self.credentials.authorize() != nil else { throw UpdateClientError.keychain }
                self.hasSavedToken = true; self.needsAuthorization = false
                authorized = true
            } catch { self.credentialFailure(error); self.needsAuthorization = true }
        }
    }
    private func credentialFailure(_ failure: Error) {
        error = failure.localizedDescription
        if failure is UpdateCredentialBrokerError || (failure as? UpdateClientError) == .keychain { needsAuthorization = true }
    }

    func manualCheck() {
        #if canImport(Sparkle)
        if let nativeUpdater { nativeUpdater.manualCheck(); refreshNativeState(); return }
        #endif
        beginCheck(automatic: nil)
    }

    /// Showing About refreshes an old result without waiting for the twelve-hour
    /// timer. This uses the same noninteractive credential read as every check;
    /// only the explicit authorization button can display a Keychain prompt.
    func refreshWhenUpdatesAreShown() {
        #if canImport(Sparkle)
        if let nativeUpdater { nativeUpdater.refreshWhenShown(); return }
        #endif
        guard enabled, automaticChecksEnabled, !busy, configuration != nil,
              AutomaticUpdateSchedule.shouldRefreshWhenShown(now: now(),
                lastAttempt: defaults.object(forKey: AutomaticUpdateSchedule.lastAttemptKey) as? Date) else { return }
        // About is visible, so show progress and any failure like a manual
        // check. Starting this refresh does not require the background lifecycle.
        beginCheck(automatic: nil)
    }

    private func beginCheck(automatic generation: Int?) {
        guard enabled, !busy else { return }
        if let generation, !checkIsCurrent(generation) { return }
        guard let (repository, key, build) = configuration else {
            if generation == nil { error = UpdateClientError.unavailable.localizedDescription }
            return
        }
        automaticTimer?.cancel(); automaticTimer = nil
        defaults.set(now(), forKey: AutomaticUpdateSchedule.lastAttemptKey)
        runningAutomaticGeneration = generation
        busy = true
        if generation == nil {
            error = nil; progress = nil
            status = L("Checking for updates…")
        }
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.busy = false; self.task = nil; self.runningAutomaticGeneration = nil
                // A newly enabled generation (or wake) may already have queued
                // an earlier check while this cancelled request was settling.
                // Its timer owns the next deadline; stale work cannot postpone it.
                if self.automaticTimer == nil { self.scheduleNextAutomaticCheck() }
            }
            do {
                let token = try await self.credentials.load()
                guard self.checkIsCurrent(generation) else { return }
                if generation == nil { self.hasSavedToken = token != nil }
                let list = try await self.fetch(repository.releasesURL.appending(queryItems: [.init(name: "per_page", value: "100")]), token: token, limit: 4_194_304)
                guard self.checkIsCurrent(generation) else { return }
                let releases = try JSONDecoder().decode([GitHubUpdateRelease].self, from: list)
                var best: AvailableUpdate?
                var bestEnvelope: Data?
                var bestTag: String?
                for release in releases where !release.draft {
                    guard self.checkIsCurrent(generation) else { return }
                    guard let asset = release.assets.first(where: { $0.name == "clipboardline-update.json" }),
                          asset.size <= 65_536, repository.acceptsAsset(asset, tag: release.tagName) else { continue }
                    let data = try await self.fetch(try repository.releaseAssetURL(id: asset.id), token: token, limit: 65_536, asset: true)
                    guard self.checkIsCurrent(generation) else { return }
                    let manifest: UpdateManifest
                    do { manifest = try AppUpdatePolicy.verifyManifest(data: data, publicKey: key, repository: repository, currentBuild: build) }
                    catch AppUpdatePolicyError.nonIncreasingBuild { continue }
                    guard manifest.build > (best?.manifest.build ?? build) else { continue }
                    guard let archive = release.assets.first(where: { $0.name == manifest.archiveName }),
                          archive.size == manifest.archiveSize, repository.acceptsAsset(archive, tag: release.tagName) else { throw AppUpdatePolicyError.invalidRelease }
                    best = AvailableUpdate(manifest: manifest, asset: archive, releaseURL: try repository.releaseURL(tag: release.tagName))
                    bestEnvelope = data; bestTag = release.tagName
                }
                guard self.checkIsCurrent(generation) else { return }
                // A temporary API failure, toggling checks off, or an empty
                // release listing never erases a previously authenticated offer.
                if let best, best.manifest.build >= (self.available?.manifest.build ?? build),
                   let bestEnvelope, let bestTag {
                    self.available = best
                    self.storeAvailableUpdate(best, envelope: bestEnvelope, tag: bestTag)
                }
                self.hasSavedToken = token != nil; self.needsAuthorization = false; self.error = nil
                self.status = self.available.map { String(format: L("Version %@ is ready to install."), $0.manifest.version) } ?? L("You are up to date.")
                let completed = self.now()
                if completed.timeIntervalSince1970.isFinite {
                    self.lastSuccessfulCheck = completed
                    self.defaults.set(completed, forKey: AutomaticUpdateSchedule.lastSuccessfulCheckKey)
                }
                if generation != nil { self.notifyAboutAutomaticOfferIfNeeded() }
            } catch {
                guard self.checkIsCurrent(generation) else { return }
                // Automatic checks never authorize Keychain, open a window, or
                // replace the user's current status with a background failure.
                guard generation == nil else { return }
                self.needsAuthorization = (error as? UpdateClientError) == .authorization || (error as? UpdateClientError) == .keychain || error is UpdateCredentialBrokerError
                self.error = error.localizedDescription; self.status = L("Update check could not be completed.")
            }
        }
    }

    /// Notification actions identify the exact advertised build. A delayed click
    /// cannot silently install a different release that appeared in the meantime.
    /// If no matching offer is retained, refresh About and let the user review it.
    func installAvailableUpdate(expectedBuild: Int) {
        #if canImport(Sparkle)
        if let nativeUpdater { nativeUpdater.installAvailableUpdate(expectedBuild: expectedBuild); refreshNativeState(); return }
        #endif
        guard enabled, !busy else { return }
        guard expectedBuild > 0, available?.manifest.build == expectedBuild else {
            manualCheck(); return
        }
        downloadAndInstall()
    }

    func downloadAndInstall() {
        #if canImport(Sparkle)
        if let nativeUpdater {
            if let build = nativeUpdater.availableBuild { nativeUpdater.installAvailableUpdate(expectedBuild: build) }
            else { nativeUpdater.manualCheck() }
            refreshNativeState(); return
        }
        #endif
        guard enabled, !busy, let update = available, let (repository, _, _) = configuration else { return }
        guard canQuit() else { error = UpdateClientError.saveEdits.localizedDescription; return }
        busy = true; error = nil; progress = 0; status = L("Downloading update…")
        task = Task { [weak self] in
            guard let self else { return }
            var work: URL?
            var launched = false
            defer {
                if !launched, let work { try? FileManager.default.removeItem(at: work) }
                self.busy = false; self.progress = nil; self.task = nil
            }
            do {
                let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                let directory = support.appendingPathComponent("ClipboardLine/Updates/\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                work = directory
                let token = try await self.credentials.load()
                let observer = UpdateDownloadObserver(limit: update.manifest.archiveSize) { [weak self] amount in Task { @MainActor in self?.progress = amount } }
                let session = Self.session(delegate: observer)
                defer { session.invalidateAndCancel() }
                let (temporary, response) = try await session.download(for: Self.request(try repository.releaseAssetURL(id: update.asset.id), token: token, asset: true))
                try Self.validate(response)
                let archive = directory.appendingPathComponent(update.manifest.archiveName)
                try FileManager.default.moveItem(at: temporary, to: archive)
                guard (try archive.resourceValues(forKeys: [.fileSizeKey])).fileSize == Int(update.manifest.archiveSize) else { throw UpdateClientError.tooLarge }
                self.status = L("Verifying update…"); self.progress = nil
                let active = Bundle.main.bundleURL
                let candidate = try await Task.detached(priority: .utility) {
                    try AppUpdateInstaller.prepare(archive: archive, manifest: update.manifest, activeApp: active, workDirectory: directory)
                }.value
                guard self.canQuit() else { throw UpdateClientError.saveEdits }
                try AppUpdateInstaller.launch(candidate: candidate, activeApp: active, manifest: update.manifest, workDirectory: directory, parentPID: ProcessInfo.processInfo.processIdentifier)
                launched = true; self.available = nil
                self.defaults.removeObject(forKey: AutomaticUpdateSchedule.availableUpdateKey)
                self.status = L("Quit the app to finish installing the update.")
                NSApp.terminate(nil)
            } catch { self.error = error.localizedDescription; self.status = L("The update was not installed.") }
        }
    }

    private func fetch(_ url: URL, token: String?, limit: Int, asset: Bool = false) async throws -> Data {
        if let fetchOverride { return try await fetchOverride(url, token, limit, asset) }
        let session = Self.session(delegate: UpdateRedirectGuard())
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: Self.request(url, token: token, asset: asset))
        try Self.validate(response)
        guard response.expectedContentLength <= Int64(limit) else { throw UpdateClientError.tooLarge }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw UpdateClientError.tooLarge }
            data.append(byte)
        }
        return data
    }
    private static func session(delegate: URLSessionDelegate) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 1_800
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }
    private static func request(_ url: URL, token: String?, asset: Bool) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(asset ? "application/octet-stream" : "application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("ClipboardLine-Update", forHTTPHeaderField: "User-Agent")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }
    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw UpdateClientError.response }
        if [401, 403, 404].contains(http.statusCode) { throw UpdateClientError.authorization }
        guard http.statusCode == 200 else { throw UpdateClientError.response }
    }
}
