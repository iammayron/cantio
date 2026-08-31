import AppKit
import Combine
import SwiftUI

@main
struct CantioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var prefs = Preferences.shared

    var body: some Scene {
        Settings {
            SettingsView(prefs: prefs)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let monitor = SpotifyMonitor()
    let lyrics = LyricsStore()
    let prefs = Preferences.shared
    let pillHitTarget = PillHitTarget()
    private var floatingController: FloatingLyricsController?
    private var statusBar: StatusBarPopover?
    private var onboarding: OnboardingController?
    private var didBootstrap = false
    private var permissionSink: AnyCancellable?
    private var didWarnAboutAccess = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Decide prompt suppression BEFORE the monitor starts polling: while the
        // assistant is up, the Spotify consent prompt must come only from its
        // dedicated step, never as a standalone popup over the splash. Setting
        // the gate after `monitor.start()` would race the loop's first poll.
        let needsOnboarding = !prefs.didCompleteOnboarding
        monitor.allowsPermissionPrompt = !needsOnboarding
        installStatusBar()
        bootstrapIfNeeded()
        if needsOnboarding { presentOnboarding() }
    }

    private func presentOnboarding() {
        let controller = OnboardingController(prefs: prefs) { [weak self] in
            // Re-enable the lazy prompt once setup closes so a later revoke can
            // still re-prompt on first use.
            self?.monitor.allowsPermissionPrompt = true
        }
        onboarding = controller
        controller.presentIfNeeded()
    }

    private func installStatusBar() {
        let bar = StatusBarPopover(monitor: monitor)
        bar.setContent { [unowned self, unowned bar] in
            MenuBarPanel(
                monitor: self.monitor,
                lyrics: self.lyrics,
                prefs: self.prefs,
                onAppear: {},
                onDismiss: { bar.dismiss() },
                onRecenter: { [unowned self] in self.floatingController?.recenter() }
            )
        }
        statusBar = bar
    }

    func bootstrapIfNeeded() {
        guard !didBootstrap else { return }
        didBootstrap = true
        monitor.start()
        watchForLostAccess()
        lyrics.bind(to: monitor)
        let controller = FloatingLyricsController(
            monitor: monitor,
            lyrics: lyrics,
            prefs: prefs,
            hitTarget: pillHitTarget
        )
        controller.start()
        floatingController = controller
    }

    // MARK: - Lost-access recovery

    /// Without the Automation grant Cantio just shows nothing — a silent
    /// failure the user has no reason to connect to a permission. Surface it
    /// once per launch, with the fix attached. Suppressible, and never shown
    /// during onboarding (its Spotify step owns the ask).
    private func watchForLostAccess() {
        permissionSink = monitor.$permission
            .removeDuplicates()
            .filter { $0 == .denied }
            .sink { [weak self] _ in self?.presentLostAccessAlert() }
    }

    private func presentLostAccessAlert() {
        guard !didWarnAboutAccess, monitor.allowsPermissionPrompt else { return }
        guard !UserDefaults.standard.bool(forKey: Self.suppressAccessAlertKey) else { return }
        didWarnAboutAccess = true

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Cantio can’t read Spotify"
        alert.informativeText = """
        macOS is blocking Cantio from reading your current track, so lyrics can’t load. \
        The switch lives in Privacy & Security → Automation → Spotify.

        Reconnecting clears Cantio’s Automation decision and asks again.
        """
        // Order matters: this alert arrives unbidden from a background poll, so
        // neither Return (first button) nor Escape may land on "Reconnect" —
        // a keystroke meant for whatever the user was typing in would run
        // `tccutil reset` and raise a blocking consent prompt. Return opens the
        // settings pane, Escape dismisses, Reconnect needs a deliberate click.
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Reconnect")
        alert.addButton(withTitle: "Later")
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don’t remind me again"

        // Alerts need a regular-policy app to reliably come forward from an
        // .accessory menu-bar agent.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(true, forKey: Self.suppressAccessAlertKey)
        }
        SettingsActivator.demoteIfNoSettingsWindow()

        switch response {
        case .alertFirstButtonReturn: SpotifyPermission.openSystemSettings()
        case .alertSecondButtonReturn: reconnectSpotify()
        default: break
        }
    }

    /// Clears our own Automation record so macOS prompts again — a denied
    /// decision is otherwise sticky and the Automation pane offers no way to
    /// re-add a missing app. Falls back to System Settings if that doesn't
    /// land (managed Macs, or the user denying a second time).
    private func reconnectSpotify() {
        DispatchQueue.global(qos: .userInitiated).async {
            let cleared = SpotifyPermission.reset()
            let resolved = cleared ? SpotifyPermission.request() : .denied
            DispatchQueue.main.async { [weak self] in
                guard resolved != .granted else {
                    self?.didWarnAboutAccess = false
                    return
                }
                SpotifyPermission.openSystemSettings()
            }
        }
    }

    private static let suppressAccessAlertKey = "suppressSpotifyAccessAlert"
}
