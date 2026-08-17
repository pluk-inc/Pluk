//
//  QueryHistoryEntry.swift
//  Pluk
//
//  Created by Claude on 1/23/26.
//

import Foundation
import SwiftData

enum QueryType: String, Codable, CaseIterable {
    case select = "SELECT"
    case insert = "INSERT"
    case update = "UPDATE"
    case delete = "DELETE"
    case ddl = "DDL"
    case raw = "RAW"

    var displayName: String {
        rawValue
    }

    var icon: String {
        switch self {
        case .select: return "magnifyingglass"
        case .insert: return "plus.circle"
        case .update: return "pencil"
        case .delete: return "trash"
        case .ddl: return "hammer"
        case .raw: return "terminal"
        }
    }
}

enum QuerySource: String, Codable, CaseIterable {
    case sqlEditor = "sql_editor"
    case redisCommandEditor = "redis_command_editor"
    case documentUpdate = "document_update"
    case documentCreate = "document_create"
    case documentDelete = "document_delete"
    case schemaOperation = "schema_operation"
    case filterQuery = "filter_query"

    var displayName: String {
        switch self {
        case .sqlEditor: return "SQL Editor"
        case .redisCommandEditor: return "Redis Command Editor"
        case .documentUpdate: return "Document Update"
        case .documentCreate: return "Document Create"
        case .documentDelete: return "Document Delete"
        case .schemaOperation: return "Schema Operation"
        case .filterQuery: return "Filter Query"
        }
    }
}

@Model
final class QueryHistoryEntry {
    var entryId: String = UUID().uuidString
    var connectionKeychainId: String
    var encryptedQuery: String?
    var queryType: String
    var querySource: String
    var databaseType: String
    var databaseName: String?
    var schemaName: String?
    var tableName: String?
    var executedAt: Date = Date()
    var executionDurationMs: Int?
    var rowsAffected: Int?
    var wasSuccessful: Bool = true
    var errorMessage: String?
    var wasSanitized: Bool = false
    var redisCommandCategory: String?

    init(
        connectionKeychainId: String,
        encryptedQuery: String?,
        queryType: QueryType,
        querySource: QuerySource,
        databaseType: DatabaseType,
        databaseName: String? = nil,
        schemaName: String? = nil,
        tableName: String? = nil,
        executionDurationMs: Int? = nil,
        rowsAffected: Int? = nil,
        wasSuccessful: Bool = true,
        errorMessage: String? = nil,
        wasSanitized: Bool = false,
        redisCommandCategory: RedisCommandCategory? = nil
    ) {
        self.connectionKeychainId = connectionKeychainId
        self.encryptedQuery = encryptedQuery
        self.queryType = queryType.rawValue
        self.querySource = querySource.rawValue
        self.databaseType = databaseType.rawValue
        self.databaseName = databaseName
        self.schemaName = schemaName
        self.tableName = tableName
        self.executionDurationMs = executionDurationMs
        self.rowsAffected = rowsAffected
        self.wasSuccessful = wasSuccessful
        self.errorMessage = errorMessage
        self.wasSanitized = wasSanitized
        self.redisCommandCategory = redisCommandCategory?.rawValue
    }

    var queryTypeEnum: QueryType {
        QueryType(rawValue: queryType) ?? .raw
    }

    var querySourceEnum: QuerySource {
        QuerySource(rawValue: querySource) ?? .sqlEditor
    }

    var redisCommandCategoryEnum: RedisCommandCategory? {
        redisCommandCategory.flatMap(RedisCommandCategory.init(rawValue:))
    }

    var databaseTypeEnum: DatabaseType? {
        DatabaseType(rawValue: databaseType)
    }

    var formattedDuration: String? {
        guard let duration = executionDurationMs else { return nil }
        if duration < 1000 {
            return "\(duration)ms"
        } else {
            let seconds = Double(duration) / 1000.0
            return seconds.formatted(.number.precision(.fractionLength(2))) + "s"
        }
    }

    var formattedDate: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: executedAt, relativeTo: Date())
    }
}
