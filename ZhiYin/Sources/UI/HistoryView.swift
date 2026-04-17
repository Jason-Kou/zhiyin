import SwiftUI
import SwiftData

// MARK: - History Window View

struct TranscriptionHistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var searchText = ""
    @State private var selectedRecord: TranscriptionRecord?
    @State private var selectedRecords: Set<PersistentIdentifier> = []
    @State private var showDeleteConfirmation = false
    @State private var displayedRecords: [TranscriptionRecord] = []
    @State private var isLoading = false
    @State private var hasMore = true
    @State private var lastTimestamp: Date?
    @State private var isVisible = false

    private let pageSize = 20

    // Watch for new records
    @Query(sort: \TranscriptionRecord.timestamp, order: .reverse)
    private var latestIndicator: [TranscriptionRecord]

    var body: some View {
        HStack(spacing: 0) {
            leftSidebar
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
            Divider()
            detailPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .alert("Delete Selected?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) { deleteSelected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete \(selectedRecords.count) transcription\(selectedRecords.count == 1 ? "" : "s") and their audio files.")
        }
        .onAppear {
            isVisible = true
            Task { await loadInitial() }
        }
        .onDisappear { isVisible = false }
        .onChange(of: searchText) { _, _ in
            Task { await resetAndLoad() }
        }
        .onChange(of: latestIndicator.first?.id) { old, new in
            guard isVisible, new != old else { return }
            Task { await resetAndLoad() }
        }
    }

    // MARK: - Left Sidebar

    private var leftSidebar: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 13))
                TextField("Search transcriptions", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(.thinMaterial))
            .padding(12)

            Divider()

            // List
            ZStack(alignment: .bottom) {
                if displayedRecords.isEmpty && !isLoading {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("No transcriptions")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(displayedRecords) { record in
                                HistoryListItem(
                                    record: record,
                                    isSelected: selectedRecord?.id == record.id,
                                    isChecked: selectedRecords.contains(record.persistentModelID),
                                    onSelect: { selectedRecord = record },
                                    onToggleCheck: { toggleCheck(record) }
                                )
                            }

                            if hasMore {
                                Button(action: { Task { await loadMore() } }) {
                                    HStack(spacing: 8) {
                                        if isLoading { ProgressView().controlSize(.small) }
                                        Text(isLoading ? "Loading..." : "Load More")
                                            .font(.system(size: 13, weight: .medium))
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                }
                                .buttonStyle(.plain)
                                .disabled(isLoading)
                            }
                        }
                        .padding(8)
                        .padding(.bottom, 50)
                    }
                }

                if !displayedRecords.isEmpty {
                    selectionToolbar
                }
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: - Detail Pane

    private var detailPane: some View {
        Group {
            if let record = selectedRecord {
                HistoryDetailView(record: record)
                    .id(record.id)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 50))
                        .foregroundColor(.secondary)
                    Text("No Selection")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.secondary)
                    Text("Select a transcription to view details")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(NSColor.controlBackgroundColor))
            }
        }
    }

    // MARK: - Selection Toolbar

    private var selectionToolbar: some View {
        HStack(spacing: 12) {
            if selectedRecords.isEmpty {
                Button("Select All") { selectAll() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            } else {
                Button("Deselect All") { selectedRecords.removeAll() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)

                Divider().frame(height: 16)

                Button(action: { showDeleteConfirmation = true }) {
                    Image(systemName: "trash")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Delete selected")
            }

            Spacer()

            if !selectedRecords.isEmpty {
                Text("\(selectedRecords.count) selected")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Color(NSColor.windowBackgroundColor)
                .shadow(color: .black.opacity(0.15), radius: 3, y: -2)
        )
    }

    // MARK: - Data Loading

    private func fetchDescriptor(after cursor: Date? = nil) -> FetchDescriptor<TranscriptionRecord> {
        var desc = FetchDescriptor<TranscriptionRecord>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )

        if let cursor {
            if !searchText.isEmpty {
                desc.predicate = #Predicate<TranscriptionRecord> {
                    $0.text.localizedStandardContains(searchText) && $0.timestamp < cursor
                }
            } else {
                desc.predicate = #Predicate<TranscriptionRecord> { $0.timestamp < cursor }
            }
        } else if !searchText.isEmpty {
            desc.predicate = #Predicate<TranscriptionRecord> {
                $0.text.localizedStandardContains(searchText)
            }
        }

        desc.fetchLimit = pageSize
        return desc
    }

    @MainActor
    private func loadInitial() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let items = try modelContext.fetch(fetchDescriptor())
            displayedRecords = items
            lastTimestamp = items.last?.timestamp
            hasMore = items.count == pageSize
        } catch {
            print("Error loading history: \(error)")
        }
    }

    @MainActor
    private func loadMore() async {
        guard !isLoading, hasMore, let cursor = lastTimestamp else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let items = try modelContext.fetch(fetchDescriptor(after: cursor))
            displayedRecords.append(contentsOf: items)
            lastTimestamp = items.last?.timestamp
            hasMore = items.count == pageSize
        } catch {
            print("Error loading more: \(error)")
        }
    }

    @MainActor
    private func resetAndLoad() async {
        displayedRecords = []
        lastTimestamp = nil
        hasMore = true
        await loadInitial()
    }

    // MARK: - Selection & Deletion

    private func toggleCheck(_ record: TranscriptionRecord) {
        let pid = record.persistentModelID
        if selectedRecords.contains(pid) {
            selectedRecords.remove(pid)
        } else {
            selectedRecords.insert(pid)
        }
    }

    private func selectAll() {
        for record in displayedRecords {
            selectedRecords.insert(record.persistentModelID)
        }
    }

    private func deleteSelected() {
        for record in displayedRecords where selectedRecords.contains(record.persistentModelID) {
            if let path = record.audioFilePath {
                try? FileManager.default.removeItem(atPath: path)
            }
            if selectedRecord?.id == record.id { selectedRecord = nil }
            modelContext.delete(record)
        }
        selectedRecords.removeAll()
        try? modelContext.save()
        Task { await resetAndLoad() }
    }
}

// MARK: - List Item

struct HistoryListItem: View {
    let record: TranscriptionRecord
    let isSelected: Bool
    let isChecked: Bool
    let onSelect: () -> Void
    let onToggleCheck: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggleCheck) {
                Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundColor(isChecked ? Color(NSColor.controlAccentColor) : .secondary)
                    .font(.system(size: 18))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    if record.source == "ai_agent" {
                        HStack(spacing: 3) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 9))
                            Text(record.aiAgentName ?? "Agent")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .foregroundStyle(.purple)
                        .background(.purple.opacity(0.12), in: Capsule())
                    }
                    Text(record.timestamp, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                    if record.duration > 0 {
                        Text(record.duration.formatTiming())
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.1)))
                            .foregroundColor(.secondary)
                    }
                }

                Text(record.text)
                    .font(.system(size: 12))
                    .lineLimit(2)
                    .foregroundColor(.primary)
            }
        }
        .padding(10)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.selectedContentBackgroundColor).opacity(0.3))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.thinMaterial)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
    }
}

// MARK: - Detail View

struct HistoryDetailView: View {
    let record: TranscriptionRecord
    @State private var justCopied = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Metadata header
                    HStack {
                        if record.source == "ai_agent" {
                            HStack(spacing: 4) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 11))
                                Text("AI Agent — \(record.aiAgentName ?? "Agent")")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .foregroundStyle(.purple)
                        }
                        Text(record.timestamp, format: .dateTime.year().month().day().hour().minute().second())
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Spacer()
                        if record.duration > 0 {
                            Text(record.duration.formatTiming())
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                    }

                    // Transcription text
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(record.source == "ai_agent" ? "Voice Intent" : "Transcription")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.secondary)
                            Spacer()
                            Button(action: copyText) {
                                Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 12))
                                    .foregroundColor(justCopied ? .green : .secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Copy to clipboard")
                        }

                        Text(record.text)
                            .font(.system(size: 14))
                            .lineSpacing(4)
                            .textSelection(.enabled)
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.thinMaterial)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                            )
                    )
                }
                .padding(20)
            }

            // Audio player at bottom
            if record.hasAudioFile, let url = record.audioURL {
                Divider()
                AudioPlayerView(url: url) { newText in
                    record.text = newText
                    try? record.modelContext?.save()
                }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(NSColor.controlBackgroundColor).opacity(0.5))
                    )
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
    }

    private func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(record.text, forType: .string)
        withAnimation { justCopied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { justCopied = false }
        }
    }
}
