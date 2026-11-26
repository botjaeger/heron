import AppKit
import HeronUI
import Sparkle

/// Heron's own face for Sparkle: instead of Sparkle's windows, every step of an update moves
/// `AppServices.update`, which Settings › Updates, the update window, the icon dot, the popover
/// strip and the right-click menu all read.
///
/// - A check you asked for (Check Now, the menu, the strip) opens the update window when it finds one.
/// - The daily check only marks the update as waiting (dot, strip, menu item): nothing opens over
///   your work. Its answer goes back to Sparkle at once ("not now"); choosing it later runs a check
///   you asked for, which finds it again and opens the window.
/// - A downloaded update installs when Heron quits; Restart Heron Now installs it at once.
@MainActor
final class HeronUserDriver: NSObject, SPUUserDriver {
    let services: AppServices
    /// Opens (or brings forward) the update window; closes it.
    var showWindow: () -> Void = {}
    var closeWindow: () -> Void = {}
    /// The open session's answers: the update window's buttons call them.
    private var choose: ((SPUUserUpdateChoice) -> Void)?
    private var cancelDownload: (() -> Void)?
    /// Installs the downloaded update now and reopens Heron (Sparkle's install-on-quit, early).
    var installNow: (() -> Void)?
    /// Runs a check you asked for (`SPUUpdater.checkForUpdates`).
    var check: () -> Void = {}
    /// Install was chosen while no session was open: say yes as soon as the check finds it.
    private var installWhenFound = false

    init(services: AppServices) {
        self.services = services
    }

    /// What the update window and Settings show for an appcast entry.
    static func offer(_ item: SUAppcastItem, automatic: Bool = false) -> UpdateOffer {
        UpdateOffer(
            version: item.displayVersionString, size: item.contentLength > 0 ? item.contentLength : nil, date: item.date,
            notes: item.itemDescription.map(ReleaseNotes.parse) ?? [], automatic: automatic)
    }

    // MARK: The window's and Settings' buttons

    /// The dot's, the strip's and the menu item's action: the update window, with a session behind
    /// it. The daily check's session has ended, so a check you asked for opens a new one.
    func showUpdate() {
        showWindow()
        if choose == nil, case .available = services.update { check() }
    }

    func install() {
        if case .ready = services.update, let installNow {
            installNow()
        } else if let choose {
            self.choose = nil
            choose(.install)
        } else {
            // The daily check's update: its session ended; a check you ask for finds it again.
            installWhenFound = true
            check()
        }
    }

    func skip() {
        choose?(.skip)
        choose = nil
        services.update = .idle
        closeWindow()
    }

    func later() {
        choose?(.dismiss)
        choose = nil
        closeWindow()
    }

    // MARK: SPUUserDriver

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Info.plist turns automatic checks on (SUEnableAutomaticChecks), so Sparkle should not ask;
        // if it does, keep that default and send no system profile.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        // An update already shown stays shown while the check confirms it.
        if services.update.offer == nil { services.update = .checking }
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let offer = Self.offer(appcastItem)
        services.update = state.stage == .installing ? .installing(offer) : .available(offer)
        if state.userInitiated {
            if installWhenFound {
                installWhenFound = false
                reply(.install)
                return
            }
            choose = reply
            showWindow()
        } else {
            // Gentle: mark it as waiting, open nothing, and let this session end.
            reply(.dismiss)
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        installWhenFound = false
        services.update = .idle
        acknowledgement()
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        installWhenFound = false
        NSLog("Heron update: \(error.localizedDescription)")
        services.update = .failed(error.localizedDescription)
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        cancelDownload = cancellation
        if let offer = services.update.offer { services.update = .downloading(offer, received: 0, expected: offer.size) }
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        if case .downloading(let offer, let received, _) = services.update {
            services.update = .downloading(offer, received: received, expected: expectedContentLength > 0 ? expectedContentLength : offer.size)
        }
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        if case .downloading(let offer, let received, let expected) = services.update {
            services.update = .downloading(offer, received: received + length, expected: expected)
        }
    }

    func showDownloadDidStartExtractingUpdate() {
        cancelDownload = nil
        if let offer = services.update.offer { services.update = .preparing(offer) }
    }

    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        // "Not now" installs it when Heron quits; Sparkle then hands over the install-now block
        // (`Updater.updater(_:willInstallUpdateOnQuit:…)`) that Restart Heron Now uses.
        if let offer = services.update.offer { services.update = .ready(offer) }
        reply(.dismiss)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        if let offer = services.update.offer { services.update = .installing(offer) }
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        services.update = .idle
        acknowledgement()
    }

    func showUpdateInFocus() {
        if services.update.waiting != nil { showWindow() }
    }

    func dismissUpdateInstallation() {
        choose = nil
        cancelDownload = nil
        // A waiting or downloaded update stays marked; a check that ended without one clears.
        switch services.update {
        case .available, .ready, .installing: break
        case .downloading(let offer, _, _), .preparing(let offer): services.update = .available(offer)
        case .checking: services.update = .idle
        case .idle, .failed: break
        }
    }
}
