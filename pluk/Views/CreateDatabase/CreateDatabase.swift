//
//  CreateDatabase.swift
//  Pluk
//

import SwiftUI

struct CreateTableForm: View {
    @Environment(ConnectionInstance.self) private var instance
    @Environment(\.dismiss) var dismiss

    var onCreated: ((String) -> Void)?

    @State private var name = ""
    @State private var nameError: String?
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var showErrorAlert = false

    private var entityName: String {
        instance.databaseType?.dataModelType == .sql ? "Table" : "Collection"
    }

    private var isFormValid: Bool {
        !name.isEmpty && nameError == nil
    }

    private func validateName(_ name: String) -> String? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedName.isEmpty {
            return "\(entityName) name cannot be empty"
        }

        if trimmedName.count > 64 {
            return "\(entityName) name cannot exceed 64 characters"
        }

        if trimmedName.hasPrefix("system.") {
            return "\(entityName) names cannot start with 'system.'"
        }

        if trimmedName.contains("$") {
            return "\(entityName) name cannot contain '$'"
        }

        if trimmedName.contains("\0") {
            return "\(entityName) name cannot contain null characters"
        }

        if trimmedName.hasPrefix(".") {
            return "\(entityName) name cannot start with a period"
        }

        let reservedChars = ["\\", "/", ":", "*", "\"", "<", ">", "|", "?"]
        for char in reservedChars {
            if trimmedName.contains(char) {
                return "\(entityName) name cannot contain '\(char)'"
            }
        }

        return nil
    }

    private func create() {
        guard !isSubmitting else { return }

        errorMessage = nil
        isSubmitting = true

        Task {
            do {
                try await instance.databaseService.createCollection(named: name)
                let createdName = name

                await MainActor.run {
                    isSubmitting = false
                    if let onCreated {
                        onCreated(createdName)
                    } else {
                        instance.createNewTab(name: createdName)
                    }
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isSubmitting = false
                    errorMessage = error.localizedDescription
                    showErrorAlert = true
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create \(entityName)")
                .font(.system(size: 13, weight: .semibold))

            VStack(alignment: .leading, spacing: 6) {
                TextField("\(entityName) name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .disabled(isSubmitting)
                    .onChange(of: name) { _, newValue in
                        nameError = validateName(newValue)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(.textBackgroundColor))
                    )
                    .shadow(color: Color(.sRGBLinear, white: 0, opacity: 0.10), radius: 1)

                if let nameError {
                    Text(nameError)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
            }

            Button(action: create) {
                Text("Create \(entityName)")
                    .opacity(isSubmitting ? 0 : 1)
                    .frame(maxWidth: .infinity)
                    .overlay {
                        if isSubmitting {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.7)
                        }
                    }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.extraLarge)
            .tint(Color.primaryButton)
            .buttonBorderShape(.capsule)
            .disabled(!isFormValid || isSubmitting)
            .keyboardShortcut(.defaultAction)
        }
        .padding(20)
        .frame(width: 280)
        .alert("Error", isPresented: $showErrorAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage ?? "An unknown error occurred")
        }
        .disabled(isSubmitting)
    }
}

// MARK: - CreateDatabaseForm

struct CreateDatabaseForm: View {
    @Environment(ConnectionInstance.self) private var instance
    @Environment(\.dismiss) var dismiss
    @Namespace private var segmentAnimation

    var onCreated: ((String) -> Void)?

    @State private var name = ""
    @State private var nameError: String?
    @State private var encoding = "UTF8"
    @State private var charset = "utf8mb4"
    @State private var collation = "utf8mb4_unicode_ci"
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var showErrorAlert = false

    private var isFormValid: Bool {
        !name.isEmpty && nameError == nil
    }

    private var showsPostgresOptions: Bool {
        instance.databaseType == .postgres
    }

    private var showsMySQLOptions: Bool {
        instance.databaseType == .mysql
    }

    private var supportsOperation: Bool {
        guard let databaseType = instance.databaseType else { return false }
        return databaseType.supportsDatabaseCreation
    }

    private var unsupportedMessage: String {
        guard let databaseType = instance.databaseType else {
            return "Database creation is not supported"
        }
        switch databaseType {
        case .sqlite:
            return "SQLite databases are file-based. Create a new .db file to create a new database."
        case .convex:
            return "Convex databases are managed through the Convex dashboard."
        default:
            return "Database creation is not supported for this database type"
        }
    }

    private func validateName(_ name: String) -> String? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedName.isEmpty {
            return "Database name cannot be empty"
        }

        if trimmedName.count > 64 {
            return "Database name cannot exceed 64 characters"
        }

        if trimmedName.hasPrefix("_") {
            return "Database name cannot start with an underscore"
        }

        guard let firstChar = trimmedName.first, firstChar.isLetter else {
            return "Database name must start with a letter"
        }

        let reservedChars = ["\\", "/", ":", "*", "\"", "<", ">", "|", "?", " ", "'", ";"]
        for char in reservedChars {
            if trimmedName.contains(char) {
                return "Database name cannot contain '\(char)'"
            }
        }

        return nil
    }

    private func create() {
        guard !isSubmitting else { return }

        errorMessage = nil
        isSubmitting = true

        Task {
            do {
                var options = CreateDatabaseOptions.default
                if showsPostgresOptions {
                    options = CreateDatabaseOptions(encoding: encoding)
                } else if showsMySQLOptions {
                    options = CreateDatabaseOptions(charset: charset, collation: collation)
                }

                try await instance.databaseService.createDatabase(named: name, options: options)
                let createdName = name

                await instance.loadDatabases()

                if let onCreated {
                    await MainActor.run {
                        isSubmitting = false
                        onCreated(createdName)
                        dismiss()
                    }
                } else {
                    if let instanceId = await ConnectionService.shared.openEnvironmentInNewTab(
                        from: instance,
                        databaseName: createdName
                    ) {
                        await MainActor.run {
                            isSubmitting = false
                            WindowController.switchToTab(.connection(instanceId))
                            dismiss()
                        }
                    } else {
                        await MainActor.run {
                            isSubmitting = false
                            dismiss()
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    isSubmitting = false
                    errorMessage = error.localizedDescription
                    showErrorAlert = true
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create Database")
                .font(.system(size: 13, weight: .semibold))

            if supportsOperation {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Database name", text: $name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .disabled(isSubmitting)
                        .onChange(of: name) { _, newValue in
                            nameError = validateName(newValue)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color(.textBackgroundColor))
                        )
                        .shadow(color: Color(.sRGBLinear, white: 0, opacity: 0.10), radius: 1)

                    if let nameError {
                        Text(nameError)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                    }
                }

                if showsPostgresOptions {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Encoding")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)

                        SegmentedTextToggle(
                            options: ["UTF8", "LATIN1", "SQL_ASCII"],
                            selection: $encoding,
                            namespace: segmentAnimation,
                            segmentId: "encoding"
                        )
                        .disabled(isSubmitting)
                    }
                }

                if showsMySQLOptions {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Character Set")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)

                            SegmentedTextToggle(
                                options: ["utf8mb4", "utf8mb3", "latin1", "ascii"],
                                selection: $charset,
                                namespace: segmentAnimation,
                                segmentId: "charset"
                            )
                            .disabled(isSubmitting)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Collation")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)

                            SegmentedTextToggle(
                                options: ["utf8mb4_unicode_ci", "utf8mb4_general_ci", "utf8mb4_bin"],
                                selection: $collation,
                                namespace: segmentAnimation,
                                segmentId: "collation",
                                labelTransform: { $0.replacing("utf8mb4_", with: "") }
                            )
                            .disabled(isSubmitting)
                        }
                    }
                }

                Button(action: create) {
                    Text("Create")
                        .opacity(isSubmitting ? 0 : 1)
                        .frame(maxWidth: .infinity)
                        .overlay {
                            if isSubmitting {
                                ProgressView()
                                    .controlSize(.small)
                                    .scaleEffect(0.7)
                            }
                        }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.extraLarge)
                .tint(Color.primaryButton)
                .buttonBorderShape(.capsule)
                .disabled(!isFormValid || isSubmitting)
                .keyboardShortcut(.defaultAction)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                        .foregroundStyle(.secondary)

                    Text(unsupportedMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(20)
            }
        }
        .padding(20)
        .frame(width: 280)
        .alert("Error", isPresented: $showErrorAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage ?? "An unknown error occurred")
        }
        .disabled(isSubmitting)
    }
}

// MARK: - CreateSchemaForm

struct CreateSchemaForm: View {
    @Environment(ConnectionInstance.self) private var instance
    @Environment(\.dismiss) var dismiss

    var onCreated: ((String) -> Void)?

    @State private var name = ""
    @State private var nameError: String?
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var showErrorAlert = false

    private var isFormValid: Bool {
        !name.isEmpty && nameError == nil
    }

    private var supportsOperation: Bool {
        instance.databaseType == .postgres || instance.databaseType == .supabase
    }

    private var unsupportedMessage: String {
        switch instance.databaseType {
        case .mysql:
            return "MySQL uses databases instead of schemas. Create a new database to organize your tables."
        case .sqlite:
            return "SQLite does not support schemas."
        case .mongodb:
            return "MongoDB does not support schemas."
        case .convex:
            return "Convex schemas are managed through the Convex dashboard."
        default:
            return "Schema creation is not supported for this database type"
        }
    }

    private static let reservedSchemaNames = ["pg_catalog", "information_schema", "pg_toast", "pg_temp"]

    private func validateName(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            return "Schema name cannot be empty"
        }

        if trimmed.count > 63 {
            return "Schema name cannot exceed 63 characters"
        }

        guard let firstChar = trimmed.first,
              firstChar.isLetter || firstChar == "_" else {
            return "Schema name must start with a letter or underscore"
        }

        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        if trimmed.unicodeScalars.contains(where: { !allowedCharacters.contains($0) }) {
            return "Schema name can only contain letters, digits, and underscores"
        }

        if Self.reservedSchemaNames.contains(trimmed.lowercased()) {
            return "'\(trimmed)' is a reserved schema name"
        }

        return nil
    }

    private func create() {
        guard !isSubmitting else { return }

        errorMessage = nil
        isSubmitting = true

        Task {
            do {
                try await instance.databaseService.createSchema(named: name)
                let createdName = name

                await MainActor.run {
                    isSubmitting = false
                    onCreated?(createdName)
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isSubmitting = false
                    errorMessage = error.localizedDescription
                    showErrorAlert = true
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create Schema")
                .font(.system(size: 13, weight: .semibold))

            if supportsOperation {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Schema name", text: $name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .disabled(isSubmitting)
                        .onChange(of: name) { _, newValue in
                            nameError = validateName(newValue)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color(.textBackgroundColor))
                        )
                        .shadow(color: Color(.sRGBLinear, white: 0, opacity: 0.10), radius: 1)

                    if let nameError {
                        Text(nameError)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                    }
                }

                Button(action: create) {
                    Text("Create Schema")
                        .opacity(isSubmitting ? 0 : 1)
                        .frame(maxWidth: .infinity)
                        .overlay {
                            if isSubmitting {
                                ProgressView()
                                    .controlSize(.small)
                                    .scaleEffect(0.7)
                            }
                        }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.extraLarge)
                .tint(Color.primaryButton)
                .buttonBorderShape(.capsule)
                .disabled(!isFormValid || isSubmitting)
                .keyboardShortcut(.defaultAction)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                        .foregroundStyle(.secondary)

                    Text(unsupportedMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(20)
            }
        }
        .padding(20)
        .frame(width: 280)
        .alert("Error", isPresented: $showErrorAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage ?? "An unknown error occurred")
        }
        .disabled(isSubmitting)
    }
}

// MARK: - SegmentedTextToggle
// Mirrors the visual style of `ViewModeToggle` (table/schema view) but for text segments.
private struct SegmentedTextToggle: View {
    @Environment(\.colorScheme) private var colorScheme
    let options: [String]
    @Binding var selection: String
    let namespace: Namespace.ID
    let segmentId: String
    var labelTransform: (String) -> String = { $0 }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { option in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        selection = option
                    }
                } label: {
                    Text(labelTransform(option))
                        .font(.system(size: 11))
                        .foregroundStyle(selection == option ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .background {
                    if selection == option {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.secondary.opacity(colorScheme == .dark ? 1 : 0.2))
                            .matchedGeometryEffect(id: segmentId, in: namespace)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(
                    colorScheme == .dark
                        ? Color(.controlColor).opacity(0.3)
                        : Color(.white)
                )
        )
        .shadow(color: Color(.sRGBLinear, white: 0, opacity: 0.10), radius: 1)
    }
}
