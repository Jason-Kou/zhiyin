import SwiftUI
import UniformTypeIdentifiers

struct DictionaryView: View {
    @ObservedObject private var dictionary = PersonalDictionary.shared
    @State private var newOriginal = ""
    @State private var newReplacement = ""
    @State private var searchText = ""

    private var filtered: [DictionaryEntry] {
        if searchText.isEmpty { return dictionary.entries }
        return dictionary.entries.filter {
            $0.original.localizedCaseInsensitiveContains(searchText) ||
            $0.replacement.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSection("Add Entry") {
                HStack(spacing: 8) {
                    TextField("Original word", text: $newOriginal)
                        .textFieldStyle(.roundedBorder)
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                    TextField("Correct form", text: $newReplacement)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        guard !newOriginal.isEmpty, !newReplacement.isEmpty else { return }
                        dictionary.add(original: newOriginal, replacement: newReplacement)
                        newOriginal = ""
                        newReplacement = ""
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)
                    .disabled(newOriginal.isEmpty || newReplacement.isEmpty)
                }
            }

            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search dictionary...", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))

            // Entry list
            List {
                if filtered.isEmpty {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            Image(systemName: "book.closed")
                                .font(.title)
                                .foregroundStyle(.quaternary)
                            Text(searchText.isEmpty ? "No entries yet" : "No matches")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 20)
                        Spacer()
                    }
                } else {
                    ForEach(filtered) { entry in
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
                            Button {
                                if let idx = dictionary.entries.firstIndex(where: { $0.id == entry.id }) {
                                    dictionary.remove(at: IndexSet(integer: idx))
                                }
                            } label: {
                                Image(systemName: "trash")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help("Delete entry")
                        }
                        .padding(.vertical, 1)
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .frame(minHeight: 120)

            // Import / Export
            HStack {
                Text("\(dictionary.entries.count) entries")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.json]
                    if panel.runModal() == .OK, let url = panel.url {
                        dictionary.importFrom(url: url)
                    }
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                        .font(.caption)
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
                    Label("Export", systemImage: "square.and.arrow.up")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
        }
    }
}
