//
//  DatabaseSelectorModal.swift
//  Pluk
//
//  Created by Fauzaan on 6/27/25.
//
import Foundation
import SwiftUI

struct DatabaseSelectorModal: View {
    let databaseService: DatabaseService
    let databaseType: DatabaseType?
    let onSelection: (DatabaseWrapper) -> Void
    let onCreateNew: () -> Void
    let onCancel: () -> Void

    @State private var databases: [DatabaseWrapper] = []
    @State private var searchText = ""
    @State private var isLoading = true
    @State private var loadError: Error? = nil
    @State private var showCreateDatabasePopover = false
    @FocusState private var searchFocused: Bool

    private var supportsCreateDatabase: Bool {
        guard let databaseType else { return false }
        return databaseType.supportsDatabaseCreation
    }

    var filteredDatabases: [DatabaseWrapper] {
        if searchText.isEmpty {
            return databases
        }
        return databases.filter {
            $0.name.localizedStandardContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            contentWithFloatingSearchBar {
                contentView
            }
            footerActions
        }
        .frame(width: 450, height: 560)
        .task {
            await loadDatabases()
            searchFocused = true
        }
        .onAppear {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(50))
                searchFocused = true
            }
        }
    }

    private var contentView: some View {
        Form {
            Section {
                if isLoading && databases.isEmpty {
                    loadingState
                } else if databases.isEmpty {
                    emptyState
                } else {
                    ForEach(filteredDatabases, id: \.name) { database in
                        Button {
                            onSelection(database)
                        } label: {
                            databaseRowLabel(for: database)
                        }
                        .buttonStyle(.plain)
                    }

                    if filteredDatabases.isEmpty && !searchText.isEmpty {
                        Text("No results found")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 6)
                    }

                    if supportsCreateDatabase {
                        HStack {
                            Spacer()
                            Button("Add Database…") {
                                showCreateDatabasePopover = true
                            }
                            .popover(isPresented: $showCreateDatabasePopover) {
                                CreateDatabaseForm(onCreated: { _ in
                                    Task {
                                        await loadDatabases()
                                    }
                                })
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var loadingState: some View {
        VStack {
            Spacer()
            ProgressView().controlSize(.small)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func contentWithFloatingSearchBar<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        if #available(macOS 26.0, *) {
            content()
                .safeAreaBar(edge: .top, spacing: 0) {
                    headerRow
                }
                .scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            content()
                .safeAreaInset(edge: .top, spacing: 0) {
                    headerRow
                }
        }
    }

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Database")
                    .font(.body)
                    .bold()
                    .foregroundStyle(.primary)

                Text("Choose a database to continue")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            floatingSearchChrome
        }
        .padding(.trailing, 20)
        .padding(.leading, 22)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var floatingSearchChrome: some View {
        if #available(macOS 26.0, *) {
            floatingSearchField
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .glassEffect(.clear, in: .capsule)
        } else {
            floatingSearchField
                .toolbarIsland()
        }
    }

    private var footerActions: some View {
        HStack {
            Spacer()
            Button("Cancel") { onCancel() }
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var floatingSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 14, height: 14)

            TextField("Search databases", text: $searchText)
                .font(.system(size: 12))
                .textFieldStyle(.plain)
                .focused($searchFocused)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, ToolbarIslandMetrics.controlVerticalPadding)
        .frame(width: 170, alignment: .trailing)
    }

    private static let iconPalette: [Color] = [
        .indigo, .blue, .orange, .green, .pink, .teal, .purple, .red, .cyan, .mint
    ]

    private func iconGradient(for name: String) -> LinearGradient {
        let index = abs(name.hashValue) % Self.iconPalette.count
        let base = Self.iconPalette[index]
        return LinearGradient(
            colors: [base.opacity(0.85), base],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func databaseRowLabel(for database: DatabaseWrapper) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(iconGradient(for: database.name))
                    .frame(width: 28, height: 28)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.08), radius: 1.5, y: 0.5)

                Image(systemName: "cylinder.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(database.name)
                    .lineLimit(1)

                HStack(spacing: 10) {
                    if let size = database.size {
                        HStack(spacing: 3) {
                            Image(systemName: "internaldrive")
                                .font(.system(size: 10))
                            Text(size)
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(.tertiary)
                    }

                    if let tableCount = database.tableCount {
                        HStack(spacing: 3) {
                            Image(systemName: "tablecells")
                                .font(.system(size: 10))
                            Text("\(tableCount) tables")
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.leading, 4)
        .contentShape(.rect)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()

            Image(systemName: "cylinder.split.1x2")
                .font(.system(size: 32))
                .foregroundStyle(.secondary.opacity(0.6))

            Text("No databases available")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)

            Text("Create your first database to get started")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
    }

    @MainActor
    private func loadDatabases() async {
        isLoading = true
        loadError = nil

        do {
            databases = try await databaseService.getDatabaseMetadata()
        } catch {
            loadError = error
            debugLog("Failed to load databases: \(error)")
        }

        isLoading = false
    }
}
