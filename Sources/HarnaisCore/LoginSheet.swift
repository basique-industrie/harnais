import AppKit
import Domain
import Infrastructure
import SwiftTerm
import SwiftUI

struct LoginSheet: View {
    let account: Account
    @Bindable var runtime: HarnaisRuntime
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?
    @State private var command: LoginCommand?
    @State private var baseline = CredentialSnapshot()
    @State private var finished = false
    @State private var signedIn = false

    var body: some View {
        VStack(alignment: .leading, spacing: HarnaisSheetMetrics.spacing) {
            HStack(spacing: 8) {
                ProviderMark(provider: account.provider, size: 20)
                Text("Sign in to \(account.displayLabel())")
                    .font(HarnaisSheetMetrics.titleFont)
                    .foregroundStyle(HarnaisPalette.text)
            }
            Text("Complete the official \(account.provider.displayName) login below. This window closes when sign-in succeeds.")
                .font(HarnaisSheetMetrics.subtitleFont)
                .foregroundStyle(HarnaisPalette.label)
            if let command {
                LoginTerminalView(command: command, onTerminated: handleProcessExit)
                    .frame(minHeight: 360)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(HarnaisPalette.hairline, lineWidth: 1)
                    }
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(HarnaisType.status)
                    .foregroundStyle(HarnaisPalette.warning)
            }
            HStack {
                if !signedIn {
                    Text("Waiting for login…")
                        .font(HarnaisType.status)
                        .foregroundStyle(HarnaisPalette.label)
                }
                Spacer(minLength: 0)
                HarnaisButton(title: "Cancel") {
                    if signedIn {
                        finishNow()
                    } else {
                        dismiss()
                    }
                }
            }
        }
        .padding(HarnaisSheetMetrics.padding)
        .frame(width: 680, height: 560)
        .background(HarnaisPalette.background)
        .harnaisChrome(title: "Sign in", kind: .sheet)
        .toolbar(removing: .title)
        .onAppear {
            baseline = AccountMetadata().credentialSnapshot(for: account)
            signedIn = AccountMetadata().appearsSignedIn(account)
            do {
                command = try LoginCommand.make(for: account)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .task {
            let captured = AccountMetadata().credentialSnapshot(for: account)
            await MainActor.run { baseline = captured }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                if Task.isCancelled { return }
                let metadata = AccountMetadata()
                let visible = metadata.appearsSignedIn(account)
                await MainActor.run { signedIn = visible }
                if metadata.loginCompleted(account, since: captured) {
                    await MainActor.run { finishNow() }
                    return
                }
            }
        }
    }

    private func handleProcessExit(_ exitCode: Int32?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            finishIfLoginCompleted()
            if !finished, exitCode != 0, !AccountMetadata().appearsSignedIn(account) {
                errorMessage = HarnaisError.notLoggedIn.localizedDescription
            }
        }
    }

    private func finishIfLoginCompleted() {
        guard AccountMetadata().loginCompleted(account, since: baseline) else { return }
        finishNow()
    }

    private func finishNow() {
        guard !finished else { return }
        finished = true
        runtime.finishLogin(account)
        dismiss()
    }
}

struct LoginTerminalView: NSViewRepresentable {
    let command: LoginCommand
    var onTerminated: (Int32?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onTerminated: onTerminated)
    }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: .zero)
        view.processDelegate = context.coordinator
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(srgbRed: 0.09, green: 0.09, blue: 0.09, alpha: 1).cgColor
        view.nativeForegroundColor = NSColor(srgbRed: 0.90, green: 0.90, blue: 0.90, alpha: 1)
        view.nativeBackgroundColor = NSColor(srgbRed: 0.09, green: 0.09, blue: 0.09, alpha: 1)
        var environment = command.environment.map { "\($0.key)=\($0.value)" }
        environment.append("TERM=xterm-256color")
        view.startProcess(
            executable: "/usr/bin/env",
            args: ["-C", command.workingDirectory, command.executable] + command.arguments,
            environment: environment,
            execName: command.executable
        )
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        context.coordinator.onTerminated = onTerminated
    }

    final class Coordinator: LocalProcessTerminalViewDelegate {
        var onTerminated: (Int32?) -> Void

        init(onTerminated: @escaping (Int32?) -> Void) {
            self.onTerminated = onTerminated
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            onTerminated(exitCode)
        }
    }
}
