//
//  QueryHistoryView.swift
//  Pluk
//
//  Created by Claude on 1/23/26.
//

import SwiftUI

struct QueryHistoryView: View {
    @Environment(ConnectionInstance.self) private var instance
    @State private var searchText = ""
    @State private var selectedQueryTypes: Set<QueryType> = []
    @State private var selectedSources: Set<QuerySource> = []
    @State private var showSuccessOnly: Bool? = nil
    @State private var historyEntries: [QueryHistoryEntryViewModel] = []
    @State private var isLoading = false
    @State private var showClearConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            QueryHistoryFilterBar(
                searchText: $searchText,
                selectedQueryTypes: $selectedQueryTypes,
                selectedSources: $selectedSources,
                showSuccessOnly: $showSuccessOnly,
                onClearHistory: { showClearConfirmation = true }
            )

            Divider()

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if historyEntries.isEmpty {
                ContentUnavailableView(
                    "No Query History",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Executed queries will appear here")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(historyEntries) { entry in
                            QueryHistoryRow(entry: entry, onReExecute: reExecuteQuery)
                                .contextMenu {
                                    contextMenuContent(for: entry)
                                }
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .frame(minWidth: 400, minHeight: 300)
        .task {
            await loadHistory()
        }
        .onChange(of: searchText) { _, _ in
            Task { await loadHistory() }
        }
        .onChange(of: selectedQueryTypes) { _, _ in
            Task { await loadHistory() }
        }
        .onChange(of: selectedSources) { _, _ in
            Task { await loadHistory() }
        }
        .onChange(of: showSuccessOnly) { _, _ in
            Task { await loadHistory() }
        }
        .confirmationDialog(
            "Clear Query History",
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) {
                clearHistory()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete all query history for this connection. This action cannot be undone.")
        }
    }

    @MainActor
    private func loadHistory() async {
        isLoading = true
        defer { isLoading = false }

        guard let service = instance.queryHistoryService else { return }

        historyEntries = service.fetchHistory(
            limit: 200,
            searchText: searchText.isEmpty ? nil : searchText,
            queryTypes: selectedQueryTypes.isEmpty ? nil : selectedQueryTypes,
            sources: selectedSources.isEmpty ? nil : selectedSources,
            successOnly: showSuccessOnly
        )
    }

    private func clearHistory() {
        instance.queryHistoryService?.clearHistory()
        historyEntries = []
    }

    private func reExecuteQuery(_ entry: QueryHistoryEntryViewModel) {
        guard entry.isReplayable else { return }
        if instance.connection.databaseType == .redis {
            instance.createRedisCommandTab(withCommand: entry.query)
        } else {
            instance.createSQLEditorTab(withQuery: entry.query)
        }
    }

    @ViewBuilder
    private func contextMenuContent(for entry: QueryHistoryEntryViewModel) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.query, forType: .string)
        } label: {
            Label("Copy Query", systemImage: "doc.on.doc")
        }

        Button {
            reExecuteQuery(entry)
        } label: {
            Label(
                entry.isReplayable ? "Load in Editor" : "Load in Editor (Credentials Redacted)",
                systemImage: "arrow.up.forward.square"
            )
        }
        .disabled(!entry.isReplayable)
        .help(
            entry.isReplayable
                ? "Load this query in an editor"
                : "Credentials were redacted. Copy the command and re-enter them before running it."
        )

        Divider()

        if let tableName = entry.tableName {
            Button {
                instance.createNewTab(name: tableName, databaseSchema: entry.schemaName)
            } label: {
                Label("Open Table: \(tableName)", systemImage: "table")
            }
        }

        Divider()

        Button(role: .destructive) {
            instance.queryHistoryService?.deleteEntry(entry.id)
            Task { await loadHistory() }
        } label: {
            Label("Delete Entry", systemImage: "trash")
        }
    }
}

struct QueryHistoryFilterBar: View {
    @Binding var searchText: String
    @Binding var selectedQueryTypes: Set<QueryType>
    @Binding var selectedSources: Set<QuerySource>
    @Binding var showSuccessOnly: Bool?
    var onClearHistory: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search queries...", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.quaternary)
            .clipShape(.rect(cornerRadius: 8))

            Menu {
                Section("Query Type") {
                    ForEach(QueryType.allCases, id: \.self) { (type: QueryType) in
                        Button {
                            if selectedQueryTypes.contains(type) {
                                selectedQueryTypes.remove(type)
                            } else {
                                selectedQueryTypes.insert(type)
                            }
                        } label: {
                            HStack {
                                Image(systemName: type.icon)
                                Text(type.displayName)
                                if selectedQueryTypes.contains(type) {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }

                Divider()

                Section("Source") {
                    ForEach(QuerySource.allCases, id: \.self) { (source: QuerySource) in
                        Button {
                            if selectedSources.contains(source) {
                                selectedSources.remove(source)
                            } else {
                                selectedSources.insert(source)
                            }
                        } label: {
                            HStack {
                                Text(source.displayName)
                                if selectedSources.contains(source) {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }

                Divider()

                Section("Status") {
                    Button {
                        showSuccessOnly = showSuccessOnly == true ? nil : true
                    } label: {
                        HStack {
                            Text("Successful Only")
                            if showSuccessOnly == true {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    Button {
                        showSuccessOnly = showSuccessOnly == false ? nil : false
                    } label: {
                        HStack {
                            Text("Failed Only")
                            if showSuccessOnly == false {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }

                if hasActiveFilters {
                    Divider()
                    Button("Clear Filters") {
                        selectedQueryTypes.removeAll()
                        selectedSources.removeAll()
                        showSuccessOnly = nil
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                    Text("Filter")
                    if hasActiveFilters {
                        Text("\(activeFilterCount)")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.accentColor)
                            .clipShape(.capsule)
                            .foregroundStyle(.white)
                    }
                }
            }
            .menuStyle(.borderlessButton)

            Spacer()

            Button {
                onClearHistory()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Clear all history")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var hasActiveFilters: Bool {
        !selectedQueryTypes.isEmpty || !selectedSources.isEmpty || showSuccessOnly != nil
    }

    private var activeFilterCount: Int {
        var count = 0
        if !selectedQueryTypes.isEmpty { count += selectedQueryTypes.count }
        if !selectedSources.isEmpty { count += selectedSources.count }
        if showSuccessOnly != nil { count += 1 }
        return count
    }
}

struct QueryHistoryRow: View {
    let entry: QueryHistoryEntryViewModel
    var onReExecute: (QueryHistoryEntryViewModel) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                queryTypeBadge
                if entry.wasSanitized {
                    sanitizedBadge
                }
                if !entry.wasSuccessful {
                    failedBadge
                }
                Spacer()
                Text(entry.formattedDate)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(entry.queryPreview)
                .font(.system(.body, design: .monospaced))
                .lineLimit(2)
                .foregroundColor(entry.wasSuccessful ? .primary : .red)

            HStack(spacing: 12) {
                if let tableName = entry.tableName {
                    Label(tableName, systemImage: "table")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let duration = entry.formattedDuration {
                    Label(duration, systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let rows = entry.rowsAffected {
                    Label("\(rows) rows", systemImage: "number")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(entry.querySource.displayName)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if let errorMessage = entry.errorMessage, !entry.wasSuccessful {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            guard entry.isReplayable else { return }
            onReExecute(entry)
        }
    }

    private var queryTypeBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: entry.queryType.icon)
            Text(entry.queryType.displayName)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(badgeColor.opacity(0.15))
        .foregroundStyle(badgeColor)
        .clipShape(.capsule)
    }

    private var sanitizedBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "eye.slash")
            Text("Sanitized")
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.orange.opacity(0.15))
        .foregroundStyle(.orange)
        .clipShape(.capsule)
        .help("Credentials were redacted. Copy the command and re-enter them before running it.")
    }

    private var failedBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle")
            Text("Failed")
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.red.opacity(0.15))
        .foregroundStyle(.red)
        .clipShape(.capsule)
    }

    private var badgeColor: Color {
        switch entry.queryType {
        case .select: return .blue
        case .insert: return .green
        case .update: return .orange
        case .delete: return .red
        case .ddl: return .purple
        case .raw: return .gray
        }
    }
}

extension Notification.Name {
    static let loadQueryInEditor = Notification.Name("loadQueryInEditor")
}
