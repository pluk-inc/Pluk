//
//  DatabaseTab.swift
//  Collection
//
//  Created by Fauzaan on 1/22/25.
//

import Foundation
import SwiftUI
import MongoKitten

@Observable
@MainActor
final class DatabaseTab: Identifiable, Equatable, Transferable {
    nonisolated let id: UUID
    var name: String
    var type: TabType
    var queryState: QueryState
    var documents: [Document] = []
    var hasSchemaDeviation: Bool = false
    var filterColumn: String?
    var filterValue: String?
    var forceFetch: Bool = false
    var databaseSchema: String?
    var viewMode: ViewMode = .content

    // Per-tab selection state (transient, not persisted)
    var selectedRowData: [String: QueryRowInfo]?
    var selectedRawRowData: DatabaseRawRow?
    var selectedRowIndex: Int?
    var selectedColumnOrder: [String]?

    // Initial query for SQL Editor tabs (transient, not persisted)
    var initialQuery: String?
    // Execute initialQuery as soon as the editor mounts (transient, not persisted)
    var autoRunInitialQuery: Bool = false

    // Function editor metadata (transient, not persisted)
    var functionOid: String?
    var functionSchema: String?
    var originalFunctionDefinition: String?

    // Redis key metadata (transient, not persisted). Redis keys are binary,
    // so the display name is never used as the command argument.
    var redisKeyData: Data?

    // CodingKeys to exclude transient properties from Codable
    enum CodingKeys: String, CodingKey {
        case id, name, type, queryState, documents, hasSchemaDeviation
        case filterColumn, filterValue, forceFetch, databaseSchema, viewMode
    }

    init(name: String, type: TabType, queryState: QueryState, filterColumn: String? = nil, filterValue: String? = nil, forceFetch: Bool = false, databaseSchema: String? = nil) {
        self.id = UUID()
        self.name = name
        self.type = type
        self.queryState = queryState
        self.hasSchemaDeviation = false
        self.filterColumn = filterColumn
        self.filterValue = filterValue
        self.forceFetch = forceFetch
        self.databaseSchema = databaseSchema
    }

    // Custom Codable implementation to exclude transient selection state
    @MainActor
    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        type = try container.decode(TabType.self, forKey: .type)
        queryState = try container.decode(QueryState.self, forKey: .queryState)
        documents = try container.decode([Document].self, forKey: .documents)
        hasSchemaDeviation = try container.decode(Bool.self, forKey: .hasSchemaDeviation)
        filterColumn = try container.decodeIfPresent(String.self, forKey: .filterColumn)
        filterValue = try container.decodeIfPresent(String.self, forKey: .filterValue)
        forceFetch = try container.decode(Bool.self, forKey: .forceFetch)
        databaseSchema = try container.decodeIfPresent(String.self, forKey: .databaseSchema)
        viewMode = try container.decode(ViewMode.self, forKey: .viewMode)
        // Transient properties are not decoded - they start as nil
    }

    @MainActor
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(type, forKey: .type)
        try container.encode(queryState, forKey: .queryState)
        try container.encode(documents, forKey: .documents)
        try container.encode(hasSchemaDeviation, forKey: .hasSchemaDeviation)
        try container.encodeIfPresent(filterColumn, forKey: .filterColumn)
        try container.encodeIfPresent(filterValue, forKey: .filterValue)
        try container.encode(forceFetch, forKey: .forceFetch)
        try container.encodeIfPresent(databaseSchema, forKey: .databaseSchema)
        try container.encode(viewMode, forKey: .viewMode)
        // Transient properties (selectedRowData, selectedRowIndex) are not encoded
    }
    
    nonisolated static func == (lhs: DatabaseTab, rhs: DatabaseTab) -> Bool {
        lhs.id == rhs.id
    }
    
    enum TabType: Equatable, Codable {
        case browse
        case aggregate
        case schema
        case indexes
        case sqlEditor
        case canvas
        case functionEditor
        case redisKey
        case redisCommand
    }

    enum ViewMode: Int, Equatable, Codable {
        case content = 0
        case schema
        case definition

        var color: Color {
            switch self {
            case .content: return .orange
            case .schema: return .purple
            case .definition: return .blue
            }
        }
    }

    enum QueryState: Equatable, Codable {
        case idle
        case loading
        case error(String)
        case results([Document])
        
        // Custom coding implementation for QueryState
        enum CodingKeys: String, CodingKey {
            case type, error, results
        }
        
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .idle:
                try container.encode("idle", forKey: .type)
            case .loading:
                try container.encode("loading", forKey: .type)
            case .error(let message):
                try container.encode("error", forKey: .type)
                try container.encode(message, forKey: .error)
            case .results(let documents):
                try container.encode("results", forKey: .type)
                try container.encode(documents, forKey: .results)
            }
        }
        
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "idle":
                self = .idle
            case "loading":
                self = .loading
            case "error":
                let message = try container.decode(String.self, forKey: .error)
                self = .error(message)
            case "results":
                let documents = try container.decode([Document].self, forKey: .results)
                self = .results(documents)
            default:
                throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown type")
            }
        }
    }
    
    nonisolated static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: \.id.uuidString)
    }
}

extension DatabaseTab: @MainActor Codable {}

enum QueryState: Equatable, Codable {
    case idle
    case loading
    case error(String)
    case results([Document])
    
    enum CodingKeys: String, CodingKey {
        case type, error
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .idle:
            try container.encode("idle", forKey: .type)
        case .loading:
            try container.encode("loading", forKey: .type)
        case .error(let message):
            try container.encode("error", forKey: .type)
            try container.encode(message, forKey: .error)
        case .results:
            // Don't encode documents, just the state
            try container.encode("results", forKey: .type)
        }
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "idle":
            self = .idle
        case "loading":
            self = .loading
        case "error":
            let message = try container.decode(String.self, forKey: .error)
            self = .error(message)
        case "results":
            // Initialize with empty results when decoding
            self = .results([])
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown type")
        }
    }
}
