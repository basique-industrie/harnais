import AppKit
import CoreImage.CIFilterBuiltins
import Domain
import Infrastructure
import SwiftUI

struct WhatsAppConnectSheet: View {
    @Bindable var runtime: HarnaisRuntime
    @Environment(\.dismiss) private var dismiss
    @State private var label = "Personal"
    @State private var status: WhatsAppStatus?
    @State private var errorMessage: String?
    @State private var checking = false
    @State private var saved = false
    @State private var attempt = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                IntegrationMark(kind: .whatsapp, size: 28)
                Text("Connect WhatsApp").font(HarnaisSheetMetrics.titleFont)
            }
            Text("Link once with your phone. Use the connection across your selected coding accounts.")
                .font(HarnaisType.control).foregroundStyle(HarnaisPalette.label)
            LabeledContent("Display name") { HarnaisField(text: $label, placeholder: "Personal", width: 240) }
            if let status, status.connected {
                Label("WhatsApp linked", systemImage: "checkmark.circle.fill").foregroundStyle(HarnaisPalette.accent)
                Text("\(status.messageCount) messages synced so far. History may take a few minutes to arrive.")
                    .font(HarnaisType.control).foregroundStyle(HarnaisPalette.label)
            } else if let qr = status?.qr, let image = qrImage(qr) {
                HStack(spacing: 20) {
                    Image(nsImage: image).interpolation(.none).resizable().frame(width: 200, height: 200)
                        .padding(10).background(.white, in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityLabel("Scan this QR code with WhatsApp on your phone")
                    VStack(alignment: .leading, spacing: 10) {
                        Text("On your phone").font(HarnaisType.rowTitle)
                        Text("1. Open WhatsApp\n2. Open Settings → Linked devices\n3. Choose Link a device\n4. Scan this code")
                            .font(HarnaisType.control).fixedSize(horizontal: false, vertical: true)
                        Text("Your current WhatsApp app stays signed in.").font(HarnaisType.status).foregroundStyle(HarnaisPalette.label)
                    }
                }
            } else if checking {
                HStack { ProgressView().controlSize(.small); Text("Preparing your link…").font(HarnaisType.control) }.frame(height: 120)
            }
            Text("Uses whatsmeow, an unofficial WhatsApp client. Session keys and synced messages stay on this Mac; messages agents read are passed to their AI provider. Agents can read documents and send text or files when you explicitly ask.")
                .font(HarnaisType.status).foregroundStyle(HarnaisPalette.label).fixedSize(horizontal: false, vertical: true)
            if let errorMessage { Text(errorMessage).font(HarnaisType.control).foregroundStyle(HarnaisPalette.warning) }
            HStack {
                if status?.connected != true {
                    HarnaisButton(title: "New QR code", enabled: !checking) { attempt += 1 }
                }
                Spacer()
                HarnaisButton(title: "Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                HarnaisButton(title: saved ? "Connected" : "Connect and sync", prominence: .primary,
                              enabled: status?.connected == true && !saved && AccountNaming.isReadable(label)) { save() }
            }
        }
        .padding(HarnaisSheetMetrics.padding).frame(width: 560).background(HarnaisPalette.background)
        .harnaisChrome(title: "Connect WhatsApp", kind: .sheet).toolbar(removing: .title)
        .task(id: attempt) { await poll(restart: attempt > 0) }
        .onAppear { label = runtime.connections.first { $0.kind == .whatsapp }?.label ?? "Personal" }
    }

    private func poll(restart: Bool) async {
        let bridge = WhatsAppBridge(identity: runtime.integrations.identity)
        checking = true; errorMessage = nil
        if restart { _ = await Task.detached { try? bridge.restart() }.value }
        for _ in 0..<180 {
            if Task.isCancelled { return }
            let result = await Task.detached { Result { try bridge.status() } }.value
            if Task.isCancelled { return }
            switch result {
            case .success(let next):
                status = next
                if next.connected { checking = false; return }
                if ["timeout", "unlinked", "link-failed", "error", "offline", "err-client-outdated", "err-scanned-without-multidevice"].contains(next.state) {
                    errorMessage = "The link expired or was refused. Request a new QR code and try again."
                    checking = false; return
                }
            case .failure(let error): errorMessage = error.localizedDescription; checking = false; return
            }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
        checking = false; errorMessage = "Linking timed out. Request a new QR code."
    }

    private func save() {
        saved = true
        let service = runtime.integrations, accounts = runtime.accounts, name = label
        Task {
            let result = await Task.detached { Result { try service.connectWhatsApp(label: name, accounts: accounts) } }.value
            switch result {
            case .success(let connection): runtime.finishConnection(connection); dismiss()
            case .failure(let error): saved = false; runtime.reload(); errorMessage = error.localizedDescription
            }
        }
    }

    private func qrImage(_ value: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8); filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 6, y: 6)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
