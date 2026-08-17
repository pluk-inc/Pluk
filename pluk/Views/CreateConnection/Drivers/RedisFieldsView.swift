//
//  RedisFieldsView.swift
//  Pluk
//

import SwiftUI

struct RedisFieldsView: View {
    @Binding var hostname: String
    @Binding var port: String
    @Binding var username: String
    @Binding var password: String
    @Binding var databaseIndex: String
    @Binding var sslMode: String
    let importError: String?
    let onImportURI: (String) -> Void

    @State private var showURIImportPopover = false

    private var usesTLS: Binding<Bool> {
        Binding(
            get: { sslMode == "require" },
            set: { sslMode = $0 ? "require" : "disable" }
        )
    }

    var body: some View {
        Group {
            Section {
                LabeledContent("Host") {
                    HStack(spacing: 4) {
                        TextField("", text: $hostname, prompt: Text("localhost"))
                            .multilineTextAlignment(.trailing)
                            .labelsHidden()
                            .frame(width: 180)

                        Text(":")
                            .foregroundStyle(.tertiary)

                        TextField("", text: $port, prompt: Text("6379"))
                            .multilineTextAlignment(.trailing)
                            .labelsHidden()
                            .frame(width: 50)
                    }
                }

                TextField(
                    "Database Index",
                    text: $databaseIndex,
                    prompt: Text("0")
                )
            } header: {
                HStack {
                    Text("Connection")
                    Spacer()
                    Button("Import from URI") {
                        showURIImportPopover.toggle()
                    }
                    .popover(isPresented: $showURIImportPopover, arrowEdge: .top) {
                        URIImportPopover(
                            placeholder: "redis://username:password@host:6379/0"
                        ) { uri in
                            onImportURI(uri)
                            showURIImportPopover = false
                        }
                    }
                }
                .padding(.trailing, -8)
            } footer: {
                if let importError {
                    Text(importError)
                        .foregroundStyle(.red)
                }
            }

            Section("Authentication (Optional)") {
                TextField("Username", text: $username, prompt: Text("default"))
                SecureField("Password", text: $password, prompt: Text("password"))
            }

            Section("Security") {
                Toggle("Use TLS (rediss://)", isOn: usesTLS)
            }
        }
        .onAppear {
            if sslMode != "disable" && sslMode != "require" {
                sslMode = "disable"
            }
        }
    }
}
