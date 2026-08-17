//
//  CollectionDetails.swift
//  Collection
//
//  Created by Fauzaan on 3/23/25.
//

import SwiftUI

// MARK: - ScrollOffsetPreferenceKey
struct ScrollOffsetPreferenceKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

enum SidebarViewMode {
    case tables
    case history
}

@MainActor
@Observable
final class SidebarCollectionLoadCoordinator {
    @ObservationIgnored
    private var loadTask: Task<Void, Never>?
    @ObservationIgnored
    private var loadTaskID = UUID()

    var isLoading = false

    func start(_ operation: @escaping @MainActor @Sendable () async -> Void) {
        cancel()

        let taskID = UUID()
        loadTaskID = taskID
        isLoading = true

        loadTask = Task { [weak self] in
            guard let self else { return }
            await operation()

            guard self.loadTaskID == taskID else { return }
            self.loadTask = nil
            self.isLoading = false
        }
    }

    func cancel() {
        loadTaskID = UUID()
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
    }
}

// MARK: - Sidebar View Mode Toggle
struct SidebarViewModeToggle: View {
    @Binding var viewMode: SidebarViewMode
    @Binding var showAdvancedHistory: Bool
    var databaseType: DatabaseType?

    var body: some View {
        HStack(spacing: 2) {
            SegmentIconButton(
                icon: "tablecells",
                isSelected: viewMode == .tables
            ) {
                viewMode = .tables
            }
            .customHelp(databaseType == .redis ? "Keys" : "Tables")

            SegmentIconButton(
                icon: "clock.arrow.circlepath",
                isSelected: viewMode == .history
            ) {
                viewMode = .history
            }
            .customHelp("Query History")
            .contextMenu {
                Button {
                    showAdvancedHistory = true
                } label: {
                    Label("Advanced View...", systemImage: "rectangle.expand.vertical")
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .toolbarIsland()
    }
}

struct SegmentIconButton: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .frame(width: 14, height: 14)
                .padding(.horizontal, ToolbarIslandMetrics.controlHorizontalPadding)
                .padding(.vertical, ToolbarIslandMetrics.controlVerticalPadding)
                .background(
                    RoundedRectangle(cornerRadius: ToolbarIslandMetrics.innerCornerRadius)
                        .fill(backgroundFill)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private var backgroundFill: Color {
        if isSelected {
            return Color(.separatorColor).opacity(0.5)
        }
        if isHovering {
            return colorScheme == .dark
                ? Color.white.opacity(0.04)
                : Color.black.opacity(0.03)
        }
        return .clear
    }
}

// MARK: - Query History Sidebar List
struct QueryHistorySidebarList: View {
    @Environment(ConnectionInstance.self) private var instance
    @State private var historyEntries: [QueryHistoryEntryViewModel] = []
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, 40)
            } else if historyEntries.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("No queries yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
            } else {
                ForEach(groupedHistory, id: \.key) { group in
                    QueryHistoryDateSection(
                        title: group.key,
                        entries: group.entries,
                        onDelete: { loadHistory() }
                    )
                }
            }
        }
        .onAppear {
            loadHistory()
        }
    }

    private var groupedHistory: [QueryHistoryGroup] {
        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday)!
        let startOfThisWeek = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))!
        let startOfLastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: startOfThisWeek)!

        var groups: [String: [QueryHistoryEntryViewModel]] = [:]

        for entry in historyEntries {
            let key: String
            if entry.executedAt >= startOfToday {
                key = "Today"
            } else if entry.executedAt >= startOfYesterday {
                key = "Yesterday"
            } else if entry.executedAt >= startOfThisWeek {
                key = "This Week"
            } else if entry.executedAt >= startOfLastWeek {
                key = "Last Week"
            } else {
                key = "Older"
            }

            groups[key, default: []].append(entry)
        }

        let order = ["Today", "Yesterday", "This Week", "Last Week", "Older"]
        return order.compactMap { key in
            guard let entries = groups[key], !entries.isEmpty else { return nil }
            return QueryHistoryGroup(key: key, entries: entries)
        }
    }

    private func loadHistory() {
        isLoading = true
        guard let service = instance.queryHistoryService else {
            isLoading = false
            return
        }
        historyEntries = service.fetchHistory(limit: 50)
        isLoading = false
    }
}

struct QueryHistoryGroup {
    let key: String
    let entries: [QueryHistoryEntryViewModel]
}

struct QueryHistoryDateSection: View {
    let title: String
    let entries: [QueryHistoryEntryViewModel]
    var onDelete: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.tertiary)
                .padding(.leading, 8)
                .padding(.top, 8)
                .padding(.bottom, 4)

            ForEach(entries) { entry in
                QueryHistorySidebarRow(entry: entry, onDelete: onDelete)
            }
        }
    }
}

struct QueryHistorySidebarRow: View {
    @Environment(ConnectionInstance.self) private var instance
    let entry: QueryHistoryEntryViewModel
    var onDelete: (() -> Void)?
    var isLast: Bool = false
    @State private var isHovered = false

    var body: some View {
        Button {
            loadQueryInEditor()
        } label: {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.queryPreview)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(.primary)

                    HStack(spacing: 4) {
                        Text(entry.formattedDate)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)

                        if let duration = entry.formattedDuration {
                            Text("·")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                            Text(duration)
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                Spacer()

                if !entry.wasSuccessful {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color(.separatorColor).opacity(0.5) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .contextMenu {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.query, forType: .string)
            } label: {
                Label("Copy Query", systemImage: "doc.on.doc")
            }

            Button {
                loadQueryInEditor()
            } label: {
                Label("Load in Editor", systemImage: "arrow.up.forward.square")
            }

            if let tableName = entry.tableName {
                Divider()
                Button {
                    instance.createNewTab(name: tableName, databaseSchema: entry.schemaName)
                } label: {
                    Label("Open Table: \(tableName)", systemImage: "table")
                }
            }

            Divider()

            Button(role: .destructive) {
                instance.queryHistoryService?.deleteEntry(entry.id)
                onDelete?()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .help(entry.query)
    }

    private func loadQueryInEditor() {
        if instance.connection.databaseType == .redis {
            instance.createRedisCommandTab(withCommand: entry.query)
        } else {
            instance.createSQLEditorTab(withQuery: entry.query)
        }
    }
}
