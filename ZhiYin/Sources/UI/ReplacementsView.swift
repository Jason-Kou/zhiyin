import SwiftUI

struct ReplacementsView: View {
    @ObservedObject private var manager = TextReplacementManager.shared
    @State private var newTrigger = ""
    @State private var newReplacement = ""
    @State private var newIsRegex = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSection("Add Replacement") {
                HStack(spacing: 8) {
                    TextField("Trigger", text: $newTrigger)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 80)
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                    TextField("Output", text: $newReplacement)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 80)
                    Toggle("Regex", isOn: $newIsRegex)
                        .toggleStyle(.checkbox)
                        .fixedSize()
                    Button {
                        guard !newTrigger.isEmpty else { return }
                        manager.add(trigger: newTrigger, replacement: newReplacement, isRegex: newIsRegex)
                        newTrigger = ""
                        newReplacement = ""
                        newIsRegex = false
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)
                    .disabled(newTrigger.isEmpty)
                }

                Text("Applied after STT, before dictionary and AI. Use \\n for newline.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            List {
                if manager.replacements.isEmpty {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            Image(systemName: "arrow.2.squarepath")
                                .font(.title)
                                .foregroundStyle(.quaternary)
                            Text("No replacements")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 20)
                        Spacer()
                    }
                } else {
                    ForEach(manager.replacements) { entry in
                        HStack {
                            Text(entry.trigger)
                                .fontWeight(.medium)
                                .frame(minWidth: 60, alignment: .leading)
                            Image(systemName: "arrow.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Text(entry.replacement.replacingOccurrences(of: "\n", with: "↵"))
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 60, alignment: .leading)
                            Spacer()
                            if entry.isRegex {
                                Text("regex")
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .foregroundStyle(.orange)
                                    .background(.orange.opacity(0.12), in: Capsule())
                            }
                        }
                        .padding(.vertical, 1)
                    }
                    .onDelete(perform: manager.remove)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .frame(minHeight: 140)

            HStack {
                Text("\(manager.replacements.count) rules")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    manager.resetToDefaults()
                } label: {
                    Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
        }
    }
}
