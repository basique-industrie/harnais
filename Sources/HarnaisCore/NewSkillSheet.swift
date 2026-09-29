import AppKit
import Domain
import Infrastructure
import SwiftUI

struct NewSkillSheet: View {
    @Bindable var runtime: HarnaisRuntime
    var onCreate: (SharedSkill) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var summary = ""
    @State private var instructions = ""
    @State private var message: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New shared skill").font(HarnaisSheetMetrics.titleFont)
            TextField("Name, for example review-changes", text: $name).textFieldStyle(.roundedBorder)
            TextField("When should this skill be used?", text: $summary).textFieldStyle(.roundedBorder)
            Text("Instructions").font(HarnaisType.rowTitle)
            TextEditor(text: $instructions).font(.system(size: 12, design: .monospaced)).frame(height: 230)
            Text("Create the shared source, then review it and choose which accounts can use it.").font(HarnaisType.control).foregroundStyle(HarnaisPalette.label)
            if let message { Text(message).foregroundStyle(HarnaisPalette.warning) }
            HStack {
                Spacer(); HarnaisButton(title: "Cancel") { dismiss() }
                HarnaisButton(title: "Create", prominence: .primary) {
                    do {
                        let skill = try SkillLibrary(identity: runtime.identity).create(name: name, description: summary, instructions: instructions)
                        runtime.refreshConnectionInventory()
                        onCreate(skill)
                        dismiss()
                    }
                    catch { message = error.localizedDescription }
                }.disabled(name.isEmpty || summary.isEmpty || instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 640).background(HarnaisPalette.background).harnaisChrome(title: "New skill", kind: .sheet)
    }
}
