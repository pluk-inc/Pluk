import SwiftUI

struct RedisCommandEditorView: View {
    @Environment(ConnectionInstance.self) private var instance
    let tab: DatabaseTab

    @State private var commandText = "PING"
    @State private var resultText = ""
    @State private var executionSummary = ""
    @State private var isExecuting = false
    @State private var errorMessage: String?
    @State private var pendingAnalysis: RedisCommandAnalysis?
    @State private var showConfirmation = false

    init(tab: DatabaseTab) {
        self.tab = tab
        _commandText = State(initialValue: tab.initialQuery ?? "PING")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label("Redis Command", systemImage: "terminal")
                    .font(.headline)

                Text("DB \(instance.connectedDatabase?.name ?? instance.connection.defaultDatabase ?? "0")")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Menu("Examples") {
                    example("PING")
                    example("DBSIZE")
                    example("SCAN 0 COUNT 100")
                    example("GET my:key")
                    example("HGETALL my:hash")
                    example("XRANGE my:stream - + COUNT 100")
                }

                Button("Run", systemImage: "play.fill") {
                    prepareExecution()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(isExecuting || commandText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            VSplitView {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Command")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextEditor(text: $commandText)
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(.separator, lineWidth: 1)
                        }
                }
                .padding(16)
                .frame(minHeight: 120)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Result")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        if !executionSummary.isEmpty {
                            Text(executionSummary)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        if isExecuting {
                            ProgressView().controlSize(.small)
                        }
                        Button("Clear") {
                            resultText = ""
                            executionSummary = ""
                            errorMessage = nil
                        }
                        .disabled(resultText.isEmpty && errorMessage == nil)
                    }

                    ScrollView([.horizontal, .vertical]) {
                        Text(displayedResult)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(errorMessage == nil ? Color.primary : Color.red)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .padding(10)
                    }
                    .background(.background)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(.separator, lineWidth: 1)
                    }
                }
                .padding(16)
                .frame(minHeight: 180)
            }
        }
        .confirmationDialog(
            pendingAnalysis?.executionPolicy.confirmationKind == .destructive
                ? "Confirm destructive Redis command"
                : "Confirm Redis command",
            isPresented: $showConfirmation,
            titleVisibility: .visible
        ) {
            Button(
                pendingAnalysis?.executionPolicy.confirmationKind == .destructive ? "Run Destructive Command" : "Run Command",
                role: pendingAnalysis?.executionPolicy.confirmationKind == .destructive ? .destructive : nil
            ) {
                guard let analysis = pendingAnalysis else { return }
                Task { await execute(analysis, confirmationGranted: true) }
            }
            Button("Cancel", role: .cancel) {
                pendingAnalysis = nil
            }
        } message: {
            Text(pendingAnalysis?.executionPolicy.message ?? "This command can modify Redis state.")
        }
    }

    private func example(_ command: String) -> some View {
        Button(command) { commandText = command }
    }

    private var displayedResult: String {
        if let errorMessage {
            return "(error) \(errorMessage)"
        }
        return resultText
    }

    private func prepareExecution() {
        errorMessage = nil
        do {
            let analysis = try RedisCommandSafety.analyze(commandText)
            guard analysis.allowsExecution else {
                errorMessage = analysis.executionPolicy.message ?? "This command is unavailable."
                return
            }
            if analysis.requiresConfirmation {
                pendingAnalysis = analysis
                showConfirmation = true
            } else {
                Task { await execute(analysis) }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func execute(
        _ analysis: RedisCommandAnalysis,
        confirmationGranted: Bool = false
    ) async {
        isExecuting = true
        errorMessage = nil
        pendingAnalysis = nil
        defer { isExecuting = false }

        do {
            let result = try await instance.databaseService.executeRedisCommand(
                analysis.transportCommand,
                analysis: analysis,
                confirmationGranted: confirmationGranted
            )
            resultText = redisCommandDisplay(result.value)
            executionSummary = "\(analysis.categoryLabel) · \(result.durationMilliseconds.formatted(.number.precision(.fractionLength(1)))) ms"
        } catch {
            errorMessage = error.localizedDescription
            executionSummary = analysis.categoryLabel
        }
    }
}

private extension RedisCommandAnalysis {
    var categoryLabel: String {
        switch category {
        case .readOnly: "read only"
        case .write: "write"
        case .destructive: "destructive"
        case .administrative: "administrative"
        case .connectionStateful: "connection state"
        case .unknown: "unknown"
        }
    }
}
