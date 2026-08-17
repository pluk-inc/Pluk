import SwiftUI

struct RedisKeyDetailView: View {
    @Environment(ConnectionInstance.self) private var instance
    let tab: DatabaseTab

    @State private var metadata: RedisKeyMetadata?
    @State private var value: RedisValue?
    @State private var isLoading = false
    @State private var isMutating = false
    @State private var errorMessage: String?
    @State private var loadGeneration = UUID()

    @State private var valueText = ""
    @State private var valueIsHex = false
    @State private var editRequest: RedisEditRequest?
    @State private var isRenaming = false
    @State private var renameText = ""
    @State private var isEditingTTL = false
    @State private var ttlText = ""
    @State private var isConfirmingDelete = false

    private var redisKey: RedisKey? {
        tab.redisKeyData.map(RedisKey.init(bytes:))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if isLoading, value == nil {
                ProgressView("Loading key…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage, value == nil {
                ContentUnavailableView(
                    "Unable to Load Key",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if metadata?.exists == false {
                ContentUnavailableView(
                    "Key No Longer Exists",
                    systemImage: "key.slash",
                    description: Text("Refresh the key browser to update the keyspace.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                valueContent
            }
        }
        .task(id: tab.redisKeyData) {
            await reload()
        }
        .sheet(item: $editRequest) { request in
            RedisValueEditSheet(request: request) { first, firstIsHex, second, secondIsHex in
                await applyEdit(
                    request,
                    first: redisData(first, isHex: firstIsHex),
                    second: redisData(second, isHex: secondIsHex)
                )
            }
        }
        .sheet(isPresented: $isRenaming) {
            RedisRenameKeySheet(initialName: renameText) { name, overwrite in
                await renameKey(to: name, overwrite: overwrite)
            }
        }
        .sheet(isPresented: $isEditingTTL) {
            RedisTTLView(initialMilliseconds: metadata?.ttlMilliseconds) { milliseconds in
                await updateTTL(milliseconds)
            }
        }
        .confirmationDialog(
            "Delete this Redis key?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete with UNLINK", role: .destructive) {
                Task { await deleteKey() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletion cannot be undone. Pluk uses UNLINK so large values do not block the Redis server.")
        }
        .alert("Redis Error", isPresented: Binding(
            get: { errorMessage != nil && value != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "key.horizontal")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(redisKey?.displayString ?? tab.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                HStack(spacing: 10) {
                    if let metadata {
                        Label(metadata.type.displayName, systemImage: typeIcon(metadata.type))
                        Text(ttlDescription(metadata.ttlMilliseconds))
                        if let bytes = metadata.memoryUsageBytes {
                            Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory))
                        }
                        if let encoding = metadata.encoding, !encoding.isEmpty {
                            Text(encoding)
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if isMutating {
                ProgressView().controlSize(.small)
            }

            Button {
                Task { await reload() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh key")
            .disabled(isLoading || isMutating)

            Menu {
                Button("Rename…") {
                    renameText = redisKey?.utf8String ?? ""
                    isRenaming = true
                }
                Button("Change TTL…") {
                    ttlText = metadata?.ttlMilliseconds.map(String.init) ?? ""
                    isEditingTTL = true
                }
                Divider()
                Button("Delete…", role: .destructive) {
                    isConfirmingDelete = true
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(redisKey == nil || isMutating)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var valueContent: some View {
        switch value {
        case nil, .some(.none):
            ContentUnavailableView("No Value", systemImage: "key.slash")

        case .string:
            stringEditor(title: "String value", saveTitle: "Save String", isJSON: false)

        case .json:
            stringEditor(title: "JSON document", saveTitle: "Save JSON", isJSON: true)

        case .hash(let entries, let totalCount, let nextCursor):
            collectionContainer(
                title: "\(totalCount) hash fields",
                canLoadMore: nextCursor != 0,
                addAction: {
                    editRequest = RedisEditRequest(kind: .hashField, title: "Add Hash Field")
                }
            ) {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    RedisTwoColumnRow(
                        first: redisDisplay(entry.field),
                        second: redisDisplay(entry.value),
                        editAction: {
                            editRequest = RedisEditRequest(
                                kind: .hashField,
                                title: "Edit Hash Field",
                                first: redisDraft(entry.field).text,
                                firstIsHex: redisDraft(entry.field).isHex,
                                firstIsReadOnly: true,
                                second: redisDraft(entry.value).text,
                                secondIsHex: redisDraft(entry.value).isHex
                            )
                        },
                        deleteAction: {
                            Task { await mutate(.deleteHashField(field: entry.field)) }
                        }
                    )
                }
            }

        case .list(let elements, let totalCount, let offset):
            collectionContainer(
                title: "\(totalCount) list elements",
                canLoadMore: offset + elements.count < totalCount,
                addAction: {
                    editRequest = RedisEditRequest(kind: .appendList, title: "Append List Element")
                }
            ) {
                ForEach(Array(elements.enumerated()), id: \.offset) { index, element in
                    RedisTwoColumnRow(
                        first: "\(offset + index)",
                        second: redisDisplay(element),
                        editAction: {
                            let draft = redisDraft(element)
                            editRequest = RedisEditRequest(
                                kind: .listElement(index: offset + index),
                                title: "Edit List Element",
                                second: draft.text,
                                secondIsHex: draft.isHex
                            )
                        }
                    )
                }
            }

        case .set(let members, let totalCount, let nextCursor):
            collectionContainer(
                title: "\(totalCount) set members",
                canLoadMore: nextCursor != 0,
                addAction: {
                    editRequest = RedisEditRequest(kind: .setMember, title: "Add Set Member")
                }
            ) {
                ForEach(Array(members.enumerated()), id: \.offset) { _, member in
                    RedisTwoColumnRow(
                        first: redisDisplay(member),
                        second: "",
                        deleteAction: {
                            Task { await mutate(.setMember(member, isPresent: false)) }
                        }
                    )
                }
            }

        case .sortedSet(let entries, let totalCount, let offset):
            collectionContainer(
                title: "\(totalCount) sorted-set members",
                canLoadMore: offset + entries.count < totalCount,
                addAction: {
                    editRequest = RedisEditRequest(kind: .sortedSetMember, title: "Add Sorted-Set Member")
                }
            ) {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    RedisTwoColumnRow(
                        first: redisDisplay(entry.member),
                        second: entry.score.formatted(),
                        editAction: {
                            let draft = redisDraft(entry.member)
                            editRequest = RedisEditRequest(
                                kind: .sortedSetMember,
                                title: "Edit Sorted-Set Member",
                                first: draft.text,
                                firstIsHex: draft.isHex,
                                firstIsReadOnly: true,
                                // Redis command arguments always use a dot as
                                // the decimal separator. Keep the editable
                                // seed locale-independent even though the
                                // display-only score above is localized.
                                second: String(entry.score)
                            )
                        },
                        deleteAction: {
                            Task { await mutate(.sortedSetMember(member: entry.member, score: nil)) }
                        }
                    )
                }
            }

        case .stream(let entries, let totalCount):
            collectionContainer(title: "\(totalCount) stream entries", canLoadMore: false) {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(redisDisplay(entry.id))
                            .font(.system(.body, design: .monospaced).weight(.medium))
                        ForEach(Array(entry.fields.enumerated()), id: \.offset) { _, field in
                            HStack(alignment: .firstTextBaseline) {
                                Text(redisDisplay(field.field)).foregroundStyle(.secondary)
                                Text(redisDisplay(field.value)).textSelection(.enabled)
                                Spacer()
                            }
                            .font(.system(.caption, design: .monospaced))
                        }
                    }
                    .padding(.vertical, 7)
                    Divider()
                }
            }

        case .unsupported(let type, let raw):
            ScrollView {
                Text("Unsupported \(type.displayName) value\n\n\(redisCommandDisplay(raw))")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
    }

    private func stringEditor(title: String, saveTitle: String, isJSON: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Toggle("Hex bytes", isOn: $valueIsHex)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Button(saveTitle) {
                    Task {
                        let data = redisData(valueText, isHex: valueIsHex)
                        await mutate(isJSON ? .json(data) : .string(data))
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isMutating || (valueIsHex && redisHexData(valueText) == nil))
            }

            TextEditor(text: $valueText)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.separator, lineWidth: 1)
                }

            if valueIsHex {
                Text("Hex input accepts hexadecimal digits with optional spaces.")
                    .font(.caption)
                    .foregroundStyle(redisHexData(valueText) == nil ? .red : .secondary)
            }
        }
        .padding(16)
    }

    private func collectionContainer<Content: View>(
        title: String,
        canLoadMore: Bool,
        addAction: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                if let addAction {
                    Button(action: addAction) {
                        Label("Add", systemImage: "plus")
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    content()
                    if canLoadMore {
                        Button("Load More") {
                            Task { await loadMore() }
                        }
                        .padding(16)
                        .disabled(isLoading)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func reload() async {
        guard let redisKey else { return }
        let requestGeneration = UUID()
        loadGeneration = requestGeneration
        isLoading = true
        defer {
            if loadGeneration == requestGeneration {
                isLoading = false
            }
        }
        do {
            async let metadataRequest = instance.databaseService.redisKeyMetadata(for: redisKey)
            async let valueRequest = instance.databaseService.redisValue(for: redisKey, page: RedisValuePage())
            let (newMetadata, newValue) = try await (metadataRequest, valueRequest)
            try Task.checkCancellation()
            guard loadGeneration == requestGeneration, self.redisKey == redisKey else { return }
            metadata = newMetadata
            value = newValue
            updateStringDraft(from: newValue)
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled,
                  loadGeneration == requestGeneration,
                  self.redisKey == redisKey else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func loadMore() async {
        guard let redisKey, let value, !isLoading else { return }
        let requestGeneration = loadGeneration
        isLoading = true
        defer {
            if loadGeneration == requestGeneration, self.redisKey == redisKey {
                isLoading = false
            }
        }

        let page: RedisValuePage
        switch value {
        case .hash(_, _, let nextCursor), .set(_, _, let nextCursor):
            page = RedisValuePage(cursor: nextCursor)
        case .list(let elements, _, let offset):
            page = RedisValuePage(offset: offset + elements.count)
        case .sortedSet(let entries, _, let offset):
            page = RedisValuePage(offset: offset + entries.count)
        default:
            return
        }

        do {
            let next = try await instance.databaseService.redisValue(for: redisKey, page: page)
            try Task.checkCancellation()
            guard loadGeneration == requestGeneration, self.redisKey == redisKey else { return }
            self.value = merge(value, with: next)
        } catch is CancellationError {
            return
        } catch {
            guard loadGeneration == requestGeneration, self.redisKey == redisKey else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func mutate(_ update: RedisValueUpdate) async {
        guard let redisKey else { return }
        errorMessage = nil
        isMutating = true
        defer { isMutating = false }
        do {
            try await instance.databaseService.updateRedisValue(update, for: redisKey, preserveTTL: true)
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func applyEdit(
        _ request: RedisEditRequest,
        first: Data,
        second: Data
    ) async -> Bool {
        switch request.kind {
        case .hashField:
            await mutate(.hashField(field: first, value: second))
        case .listElement(let index):
            await mutate(.listElement(index: index, value: second))
        case .appendList:
            await mutate(.appendList(values: [second], toHead: false))
        case .setMember:
            await mutate(.setMember(first, isPresent: true))
        case .sortedSetMember:
            guard let score = Double(String(data: second, encoding: .utf8) ?? "") else {
                errorMessage = "Score must be a number."
                return false
            }
            await mutate(.sortedSetMember(member: first, score: score))
        }
        return errorMessage == nil
    }

    private func renameKey(to name: String, overwrite: Bool) async -> Bool {
        guard let redisKey else { return false }
        guard !name.isEmpty else {
            errorMessage = "Key name cannot be empty."
            return false
        }
        isMutating = true
        defer { isMutating = false }
        do {
            let newKey = RedisKey(name)
            try await instance.databaseService.renameRedisKey(redisKey, to: newKey, overwrite: overwrite)
            tab.redisKeyData = newKey.bytes
            tab.name = newKey.displayString
            NotificationCenter.default.post(name: .redisKeysRefreshRequested, object: instance)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func updateTTL(_ milliseconds: Int64?) async -> Bool {
        guard let redisKey else { return false }
        isMutating = true
        defer { isMutating = false }
        do {
            _ = try await instance.databaseService.setRedisExpiration(for: redisKey, milliseconds: milliseconds)
            metadata = try await instance.databaseService.redisKeyMetadata(for: redisKey)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func deleteKey() async {
        guard let redisKey else { return }
        isMutating = true
        defer { isMutating = false }
        do {
            _ = try await instance.databaseService.deleteRedisKeys([redisKey], asynchronously: true)
            metadata = RedisKeyMetadata(key: redisKey, type: .none, ttlMilliseconds: nil, memoryUsageBytes: nil, encoding: nil)
            value = RedisValue.none
            NotificationCenter.default.post(name: .redisKeysRefreshRequested, object: instance)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func updateStringDraft(from value: RedisValue) {
        let data: Data?
        switch value {
        case .string(let bytes), .json(let bytes): data = bytes
        default: data = nil
        }
        guard let data else { return }
        let draft = redisDraft(data)
        valueText = draft.text
        valueIsHex = draft.isHex
    }

    private func merge(_ current: RedisValue, with next: RedisValue) -> RedisValue {
        switch (current, next) {
        case let (.hash(entries, _, _), .hash(nextEntries, total, cursor)):
            var seenFields = Set(entries.map(\.field))
            let additions = nextEntries.filter { seenFields.insert($0.field).inserted }
            return .hash(entries: entries + additions, totalCount: total, nextCursor: cursor)
        case let (.list(elements, _, offset), .list(nextElements, total, _)):
            return .list(elements: elements + nextElements, totalCount: total, offset: offset)
        case let (.set(members, _, _), .set(nextMembers, total, cursor)):
            var seenMembers = Set(members)
            let additions = nextMembers.filter { seenMembers.insert($0).inserted }
            return .set(members: members + additions, totalCount: total, nextCursor: cursor)
        case let (.sortedSet(entries, _, offset), .sortedSet(nextEntries, total, _)):
            return .sortedSet(entries: entries + nextEntries, totalCount: total, offset: offset)
        default:
            return next
        }
    }

    private func ttlDescription(_ milliseconds: Int64?) -> String {
        guard let milliseconds else { return "Persistent" }
        if milliseconds < 1_000 { return "TTL \(milliseconds) ms" }
        let seconds = Double(milliseconds) / 1_000
        if seconds < 60 { return "TTL \(seconds.formatted(.number.precision(.fractionLength(0...1)))) s" }
        if seconds < 3_600 { return "TTL \((seconds / 60).formatted(.number.precision(.fractionLength(0...1)))) min" }
        return "TTL \((seconds / 3_600).formatted(.number.precision(.fractionLength(0...1)))) hr"
    }

    private func typeIcon(_ type: RedisKeyType) -> String {
        switch type {
        case .string: "textformat"
        case .hash: "number"
        case .list: "list.bullet"
        case .set: "circle.grid.2x2"
        case .sortedSet: "list.number"
        case .stream: "waveform.path.ecg"
        case .json: "curlybraces"
        case .none, .unknown: "questionmark"
        }
    }
}

private struct RedisDataDraft {
    let text: String
    let isHex: Bool
}

private func redisDraft(_ data: Data) -> RedisDataDraft {
    if let string = String(data: data, encoding: .utf8) {
        return RedisDataDraft(text: string, isHex: false)
    }
    return RedisDataDraft(text: data.map { String(format: "%02x", $0) }.joined(), isHex: true)
}

private func redisDisplay(_ data: Data) -> String {
    let draft = redisDraft(data)
    return draft.isHex ? "0x\(draft.text)" : draft.text
}

private func redisData(_ text: String, isHex: Bool) -> Data {
    if isHex, let data = redisHexData(text) {
        return data
    }
    return Data(text.utf8)
}

private func redisHexData(_ text: String) -> Data? {
    let compact = text
        .replacingOccurrences(of: "0x", with: "", options: [.caseInsensitive, .anchored])
        .filter { !$0.isWhitespace }
    guard compact.count.isMultiple(of: 2), compact.allSatisfy(\.isHexDigit) else { return nil }
    var result = Data(capacity: compact.count / 2)
    var index = compact.startIndex
    while index < compact.endIndex {
        let next = compact.index(index, offsetBy: 2)
        guard let byte = UInt8(compact[index..<next], radix: 16) else { return nil }
        result.append(byte)
        index = next
    }
    return result
}

private struct RedisTwoColumnRow: View {
    let first: String
    let second: String
    var editAction: (() -> Void)?
    var deleteAction: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(first)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(second.isEmpty ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: second.isEmpty ? .infinity : 260, alignment: .leading)
                .textSelection(.enabled)

            if !second.isEmpty {
                Text(second)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

            if let editAction {
                Button(action: editAction) { Image(systemName: "pencil") }
                    .buttonStyle(.borderless)
            }
            if let deleteAction {
                Button(role: .destructive, action: deleteAction) { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 9)
        Divider()
    }
}

private struct RedisEditRequest: Identifiable {
    enum Kind {
        case hashField
        case listElement(index: Int)
        case appendList
        case setMember
        case sortedSetMember
    }

    let id = UUID()
    let kind: Kind
    let title: String
    var first = ""
    var firstIsHex = false
    var firstIsReadOnly = false
    var second = ""
    var secondIsHex = false
}

private struct RedisValueEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let request: RedisEditRequest
    let onSave: (String, Bool, String, Bool) async -> Bool

    @State private var first: String
    @State private var firstIsHex: Bool
    @State private var second: String
    @State private var secondIsHex: Bool
    @State private var isSaving = false

    init(
        request: RedisEditRequest,
        onSave: @escaping (String, Bool, String, Bool) async -> Bool
    ) {
        self.request = request
        self.onSave = onSave
        _first = State(initialValue: request.first)
        _firstIsHex = State(initialValue: request.firstIsHex)
        _second = State(initialValue: request.second)
        _secondIsHex = State(initialValue: request.secondIsHex)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(request.title).font(.title3.weight(.semibold))

            if needsFirstValue {
                RedisDataField(
                    title: firstTitle,
                    text: $first,
                    isHex: $firstIsHex,
                    isReadOnly: request.firstIsReadOnly
                )
            }
            if !request.kind.isSetMember {
                RedisDataField(title: secondTitle, text: $second, isHex: $secondIsHex, isNumeric: needsNumericSecond)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") {
                    Task {
                        isSaving = true
                        if await onSave(first, firstIsHex, second, secondIsHex) {
                            dismiss()
                        }
                        isSaving = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving || !isValid)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var needsFirstValue: Bool {
        switch request.kind {
        case .hashField, .setMember, .sortedSetMember: true
        case .listElement, .appendList: false
        }
    }

    private var needsNumericSecond: Bool {
        if case .sortedSetMember = request.kind { return true }
        return false
    }

    private var firstTitle: String {
        switch request.kind {
        case .hashField: "Field"
        case .setMember, .sortedSetMember: "Member"
        case .listElement, .appendList: ""
        }
    }

    private var secondTitle: String {
        switch request.kind {
        case .sortedSetMember: "Score"
        case .hashField, .listElement, .appendList: "Value"
        case .setMember: "Value (unused)"
        }
    }

    private var isValid: Bool {
        if firstIsHex, redisHexData(first) == nil { return false }
        if secondIsHex, redisHexData(second) == nil { return false }
        if needsNumericSecond, Double(second) == nil { return false }
        return true
    }
}

private extension RedisEditRequest.Kind {
    var isSetMember: Bool {
        if case .setMember = self { return true }
        return false
    }
}

private struct RedisDataField: View {
    let title: String
    @Binding var text: String
    @Binding var isHex: Bool
    var isNumeric = false
    var isReadOnly = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !isNumeric {
                    Toggle("Hex", isOn: $isHex)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(isReadOnly)
                }
            }
            TextField(title, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .disabled(isReadOnly)
        }
    }
}

private struct RedisRenameKeySheet: View {
    @Environment(\.dismiss) private var dismiss
    let onRename: (String, Bool) async -> Bool
    @State private var name: String
    @State private var overwrite = false
    @State private var isSaving = false

    init(initialName: String, onRename: @escaping (String, Bool) async -> Bool) {
        self.onRename = onRename
        _name = State(initialValue: initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Redis Key").font(.title3.weight(.semibold))
            TextField("Key name", text: $name).textFieldStyle(.roundedBorder)
            Toggle("Overwrite an existing key", isOn: $overwrite)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Rename") {
                    Task {
                        isSaving = true
                        if await onRename(name, overwrite) { dismiss() }
                        isSaving = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving || name.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

private struct RedisTTLView: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (Int64?) async -> Bool
    @State private var milliseconds: String
    @State private var persistent: Bool
    @State private var isSaving = false

    init(initialMilliseconds: Int64?, onSave: @escaping (Int64?) async -> Bool) {
        self.onSave = onSave
        _milliseconds = State(initialValue: initialMilliseconds.map(String.init) ?? "")
        _persistent = State(initialValue: initialMilliseconds == nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Key Expiration").font(.title3.weight(.semibold))
            Toggle("Persist without expiration", isOn: $persistent)
            if !persistent {
                TextField("Milliseconds", text: $milliseconds)
                    .textFieldStyle(.roundedBorder)
                Text("Enter a positive TTL in milliseconds.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") {
                    Task {
                        isSaving = true
                        let value = persistent ? nil : Int64(milliseconds)
                        if await onSave(value) { dismiss() }
                        isSaving = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving || (!persistent && (Int64(milliseconds) ?? 0) <= 0))
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

func redisCommandDisplay(_ value: RedisCommandValue, indent: Int = 0) -> String {
    let padding = String(repeating: "  ", count: indent)
    switch value {
    case .null: return "null"
    case .simpleString(let data), .bulkString(let data), .bigNumber(let data):
        return redisDisplay(data)
    case .simpleError(let data), .bulkError(let data):
        return "(error) \(redisDisplay(data))"
    case .verbatimString(let format, let data):
        return format.map { "\($0):\(redisDisplay(data))" } ?? redisDisplay(data)
    case .integer(let value): return String(value)
    case .double(let value): return String(value)
    case .boolean(let value): return String(value)
    case .array(let values), .set(let values), .push(let values):
        return values.enumerated().map {
            "\(padding)\($0.offset + 1)) \(redisCommandDisplay($0.element, indent: indent + 1))"
        }.joined(separator: "\n")
    case .map(let entries), .attribute(let entries):
        return entries.map {
            "\(padding)\(redisCommandDisplay($0.key, indent: indent + 1)): \(redisCommandDisplay($0.value, indent: indent + 1))"
        }.joined(separator: "\n")
    }
}
