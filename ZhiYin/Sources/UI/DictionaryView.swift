import SwiftUI
import UniformTypeIdentifiers

struct DictionaryView: View {
    @ObservedObject private var dictionary = PersonalDictionary.shared
    @State private var newOriginal = ""
    @State private var newReplacement = ""
    @State private var searchText = ""

    @State private var editingID: UUID?
    @State private var editOriginal = ""
    @State private var editReplacement = ""

    /// Kept so a mis-click on the trash can be taken back. Deleting is otherwise
    /// instant and silent, and the entry is gone with no way to recover it.
    @State private var undoTarget: (entry: DictionaryEntry, index: Int)?

    @FocusState private var focusedField: Field?
    private enum Field: Hashable { case editOriginal, editReplacement }

    private var filtered: [DictionaryEntry] {
        if searchText.isEmpty { return dictionary.entries }
        return dictionary.entries.filter {
            $0.original.localizedCaseInsensitiveContains(searchText) ||
            $0.replacement.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var duplicate: DictionaryEntry? {
        newOriginal.isEmpty ? nil : dictionary.existing(original: newOriginal)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            addEntrySection
            searchField
            entryList
            footer
        }
    }

    // MARK: - Add

    private var addEntrySection: some View {
        SettingsSection("Add Entry") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TextField("As transcribed", text: $newOriginal)
                        .textFieldStyle(.roundedBorder)
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                    TextField("Replace with", text: $newReplacement)
                        .textFieldStyle(.roundedBorder)
                    Button(action: commitNew) {
                        Image(systemName: duplicate == nil ? "plus.circle.fill" : "arrow.triangle.2.circlepath.circle.fill")
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)
                    .disabled(newOriginal.isEmpty || newReplacement.isEmpty)
                    .help(duplicate == nil ? "Add entry" : "Update the existing entry")
                }

                if let dupe = duplicate {
                    Label("Already mapped to \u{201C}\(dupe.replacement)\u{201D} — adding will replace it.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text("Left is what the model hears, right is what you want. Matching ignores case.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func commitNew() {
        let original = newOriginal.trimmingCharacters(in: .whitespaces)
        let replacement = newReplacement.trimmingCharacters(in: .whitespaces)
        guard !original.isEmpty, !replacement.isEmpty else { return }
        if let dupe = dictionary.existing(original: original) {
            dictionary.update(id: dupe.id, original: original, replacement: replacement)
        } else {
            dictionary.add(original: original, replacement: replacement)
        }
        newOriginal = ""
        newReplacement = ""
        // Adding from the form finishes the interaction. Leaving a half-open row
        // editor behind reads as "there is still something to save".
        editingID = nil
    }

    // MARK: - Search

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search dictionary...", text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - List

    private var entryList: some View {
        List {
            if filtered.isEmpty {
                emptyState
            } else {
                ForEach(filtered) { entry in
                    if editingID == entry.id {
                        editRow(entry)
                    } else {
                        displayRow(entry)
                    }
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .frame(minHeight: 120)
    }

    private var emptyState: some View {
        HStack {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: "book.closed")
                    .font(.title)
                    .foregroundStyle(.quaternary)
                Text(searchText.isEmpty ? "No entries yet" : "No matches")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if searchText.isEmpty {
                    Text("Add a word the model keeps getting wrong — say, \u{201C}open cloud\u{201D} when you mean \u{201C}OpenClaw\u{201D}. Entries also nudge recognition toward the spelling you want.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 340)
                }
            }
            .padding(.vertical, 20)
            Spacer()
        }
    }

    private func displayRow(_ entry: DictionaryEntry) -> some View {
        HStack {
            Text(entry.original)
                .fontWeight(.medium)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "arrow.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text(entry.replacement)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { beginEditing(entry) } label: {
                Image(systemName: "pencil")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Edit entry")
            Button { delete(entry) } label: {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Delete entry")
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { beginEditing(entry) }
    }

    private func editRow(_ entry: DictionaryEntry) -> some View {
        HStack(spacing: 6) {
            TextField("As transcribed", text: $editOriginal)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .editOriginal)
                .onSubmit(commitEdit)
            Image(systemName: "arrow.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
            TextField("Replace with", text: $editReplacement)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .editReplacement)
                .onSubmit(commitEdit)
            Button(action: commitEdit) {
                Image(systemName: "checkmark.circle.fill").font(.body)
            }
            .buttonStyle(.borderless)
            .disabled(editOriginal.isEmpty || editReplacement.isEmpty)
            .help("Done editing")
            Button { editingID = nil } label: {
                Image(systemName: "xmark.circle").font(.body).foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Discard changes")
        }
        .padding(.vertical, 1)
    }

    private func beginEditing(_ entry: DictionaryEntry) {
        editingID = entry.id
        editOriginal = entry.original
        editReplacement = entry.replacement
        focusedField = .editOriginal
    }

    private func commitEdit() {
        guard let id = editingID else { return }
        let original = editOriginal.trimmingCharacters(in: .whitespaces)
        let replacement = editReplacement.trimmingCharacters(in: .whitespaces)
        guard !original.isEmpty, !replacement.isEmpty else { return }
        dictionary.update(id: id, original: original, replacement: replacement)
        editingID = nil
    }

    private func delete(_ entry: DictionaryEntry) {
        if editingID == entry.id { editingID = nil }
        undoTarget = dictionary.remove(id: entry.id)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if let target = undoTarget {
                Label("Deleted \u{201C}\(target.entry.original)\u{201D}", systemImage: "trash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Undo") {
                    dictionary.insert(target.entry, at: target.index)
                    undoTarget = nil
                }
                .buttonStyle(.link)
                .font(.caption)
            } else {
                Text("\(dictionary.entries.count) entries")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.json]
                if panel.runModal() == .OK, let url = panel.url {
                    dictionary.importFrom(url: url)
                }
            } label: {
                Label("Import", systemImage: "square.and.arrow.down").font(.caption)
            }
            .buttonStyle(.borderless)

            Button {
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.json]
                panel.nameFieldStringValue = "dictionary.json"
                if panel.runModal() == .OK, let url = panel.url {
                    try? FileManager.default.copyItem(at: dictionary.exportURL(), to: url)
                }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up").font(.caption)
            }
            .buttonStyle(.borderless)
        }
    }
}
