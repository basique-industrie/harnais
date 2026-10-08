import Combine
import Foundation
import Infrastructure
import Observation
import Sparkle
import SwiftUI

/// One production updater, shared by About and the application menu.
/// Development bundles and command-line tools never start an update session.
@MainActor
@Observable
public final class HarnaisUpdater: NSObject, SPUUpdaterDelegate {
    public static let shared = HarnaisUpdater()
    public private(set) var canCheck = false
    public private(set) var latestVersion: String?
    public private(set) var lastCheckedAt: Date?
    public private(set) var failure: String?
    public private(set) var automaticallyChecks = false
    public private(set) var isAvailable = false
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observations: [AnyCancellable] = []

    private override init() {
        super.init()
        guard Bundle.main.bundleIdentifier == AppIdentity.shippedBundleIdentifier,
              Bundle.main.bundleURL.pathExtension == "app" else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self,
                                                     userDriverDelegate: nil)
        self.controller = controller
        isAvailable = true
        controller.updater.publisher(for: \.canCheckForUpdates)
            .sink { [weak self] in self?.canCheck = $0 }.store(in: &observations)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates)
            .sink { [weak self] in self?.automaticallyChecks = $0 }.store(in: &observations)
        controller.updater.publisher(for: \.lastUpdateCheckDate)
            .sink { [weak self] in self?.lastCheckedAt = $0 }.store(in: &observations)
        controller.startUpdater()
    }

    public func check() {
        guard canCheck else { return }
        failure = nil
        controller?.checkForUpdates(nil)
    }

    public func setAutomaticChecks(_ enabled: Bool) {
        controller?.updater.automaticallyChecksForUpdates = enabled
    }

    public func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        latestVersion = item.displayVersionString
        failure = nil
    }

    public func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        if (error as NSError).code == SUError.noUpdateError.rawValue {
            latestVersion = nil
            failure = nil
        } else {
            failure = error.localizedDescription
        }
    }
}

public struct HarnaisUpdateCommands: Commands {
    private var updater = HarnaisUpdater.shared
    public init() {}

    public var body: some Commands {
        CommandGroup(after: .appInfo) {
            if updater.isAvailable {
                Button("Check for Updates…", action: updater.check).disabled(!updater.canCheck)
            }
        }
    }
}

struct HarnaisUpdateSection: View {
    private var updater = HarnaisUpdater.shared

    var body: some View {
        SettingsSection(title: "Updates") {
            if updater.isAvailable {
                SettingsRow(title: updater.latestVersion.map { "Version \($0) available" } ?? "Harnais updates",
                            description: updater.failure ?? "Signed updates from Harnais’s official releases.",
                            status: updater.lastCheckedAt.map { "Last checked \($0.formatted(date: .abbreviated, time: .shortened))" }) {
                    HarnaisButton(title: "Check for updates…", action: updater.check).disabled(!updater.canCheck)
                }
                SettingsDivider()
                SettingsRow(title: "Check automatically", description: "Notify when an update is available. You choose when to install it.") {
                    Toggle("Check automatically", isOn: Binding(get: { updater.automaticallyChecks },
                                                                set: { updater.setAutomaticChecks($0) }))
                        .labelsHidden().toggleStyle(.switch)
                }
            } else {
                SettingsRow(title: "Development build", description: "Build Harnais Dev from source. Install the standard app to receive release updates.") {
                    EmptyView()
                }
            }
        }
    }
}
