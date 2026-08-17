import Foundation
import OSLog

private let dockerDiscoveryLogger = Logger(subsystem: "doc.pluk", category: "DockerDiscovery")

struct DockerDatabaseCandidate: Identifiable, Hashable, Sendable {
    let id: String
    let containerName: String
    let imageName: String
    let databaseType: DatabaseType
    let host: String
    let port: String
    let username: String?
    let password: String?
    let databaseName: String?
    let isRunning: Bool
    let createdAt: Date?
    let startedAt: Date?

    var displayName: String {
        containerName.isEmpty ? imageName : containerName
    }

    var isReadyToConnect: Bool {
        switch databaseType {
        case .postgres, .mysql:
            return !(username ?? "").isEmpty && !(password ?? "").isEmpty
        case .mongodb:
            return true
        case .redis:
            return (username ?? "").isEmpty || !(password ?? "").isEmpty
        case .convex, .supabase, .sqlite:
            return false
        }
    }

    var connectionName: String {
        let raw = displayName
        var stripped = raw

        if let lastSep = stripped.lastIndex(where: { $0 == "-" || $0 == "_" }) {
            let trailing = stripped[stripped.index(after: lastSep)...]
            if !trailing.isEmpty, trailing.allSatisfy(\.isNumber) {
                stripped = String(stripped[..<lastSep])
            }
        }

        let services: [String]
        switch databaseType {
        case .postgres: services = ["postgresql", "postgres", "pg"]
        case .mysql: services = ["mariadb", "mysql"]
        case .mongodb: services = ["mongodb", "mongo"]
        case .redis: services = ["redis", "valkey"]
        case .convex, .supabase, .sqlite: services = []
        }

        for service in services {
            for separator in ["-", "_"] {
                let suffix = "\(separator)\(service)"
                if stripped.lowercased().hasSuffix(suffix) {
                    stripped = String(stripped.dropLast(suffix.count))
                    break
                }
            }
        }

        return stripped.isEmpty ? raw : stripped
    }

    var connectionURI: String {
        switch databaseType {
        case .mongodb:
            guard let username, !username.isEmpty, let password, !password.isEmpty else {
                return "mongodb://\(host):\(port)"
            }
            let encodedUsername = username.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? username
            let encodedPassword = password.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? password
            return "mongodb://\(encodedUsername):\(encodedPassword)@\(host):\(port)"
        case .postgres:
            return buildSQLURI(scheme: "postgresql", defaultDatabase: "postgres")
        case .mysql:
            return buildSQLURI(scheme: "mysql", defaultDatabase: "")
        case .redis:
            return buildRedisURI()
        case .convex, .supabase, .sqlite:
            return ""
        }
    }

    private func buildRedisURI() -> String {
        var uri = "redis://"
        if let username, !username.isEmpty {
            uri += username.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? username
            if let password, !password.isEmpty {
                uri += ":\(password.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? password)"
            }
            uri += "@"
        } else if let password, !password.isEmpty {
            uri += ":\(password.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? password)@"
        }
        uri += "\(host):\(port)/\(databaseName ?? "0")"
        return uri
    }

    private func buildSQLURI(scheme: String, defaultDatabase: String) -> String {
        var uri = "\(scheme)://"
        if let username, !username.isEmpty {
            uri += username.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? username
            if let password, !password.isEmpty {
                uri += ":\(password.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? password)"
            }
            uri += "@"
        }
        uri += "\(host):\(port)"
        let database = databaseName ?? defaultDatabase
        if !database.isEmpty {
            uri += "/\(database.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? database)"
        }
        return uri
    }
}

private struct DockerInspectContainer: Decodable {
    let id: String
    let name: String?
    let created: String?
    let config: DockerInspectConfig?
    let state: DockerInspectState?
    let networkSettings: DockerInspectNetworkSettings?
    let hostConfig: DockerInspectHostConfig?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case created = "Created"
        case config = "Config"
        case state = "State"
        case networkSettings = "NetworkSettings"
        case hostConfig = "HostConfig"
    }
}

private struct DockerInspectConfig: Decodable {
    let image: String?
    let env: [String]?

    enum CodingKeys: String, CodingKey {
        case image = "Image"
        case env = "Env"
    }
}

private struct DockerInspectState: Decodable {
    let running: Bool?
    let startedAt: String?

    enum CodingKeys: String, CodingKey {
        case running = "Running"
        case startedAt = "StartedAt"
    }
}

private struct DockerInspectNetworkSettings: Decodable {
    let ports: [String: [DockerInspectPortBinding]?]?

    enum CodingKeys: String, CodingKey {
        case ports = "Ports"
    }
}

private struct DockerInspectHostConfig: Decodable {
    let portBindings: [String: [DockerInspectPortBinding]?]?

    enum CodingKeys: String, CodingKey {
        case portBindings = "PortBindings"
    }
}

private struct DockerInspectPortBinding: Decodable {
    let hostPort: String?

    enum CodingKeys: String, CodingKey {
        case hostPort = "HostPort"
    }
}

enum DockerContainerDiscoveryError: Error, LocalizedError {
    case dockerUnavailable
    case sandboxPermissionDenied

    var errorDescription: String? {
        switch self {
        case .dockerUnavailable:
            return "Docker is not available or is not running."
        case .sandboxPermissionDenied:
            return "Docker socket access is blocked by the macOS sandbox."
        }
    }
}

struct DockerContainerDiscoveryService: Sendable {
    func discoverDatabaseContainers() async throws -> [DockerDatabaseCandidate] {
        let idsOutput = try await runDocker(arguments: ["ps", "-a", "--format", "{{.ID}}"])
        let containerIDs = idsOutput
            .split(whereSeparator: \.isNewline)
            .map(String.init)

        guard !containerIDs.isEmpty else {
            return []
        }

        let inspectOutput = try await runDocker(arguments: ["inspect"] + containerIDs)
        guard let data = inspectOutput.data(using: .utf8),
              let containers = try? Foundation.JSONDecoder().decode([DockerInspectContainer].self, from: data) else {
            dockerDiscoveryLogger.error("Failed to decode docker inspect output")
            return []
        }

        return containers.compactMap(makeCandidate(from:))
    }

    private func runDocker(arguments: [String]) async throws -> String {
        guard let dockerExecutableURL else {
            dockerDiscoveryLogger.error("Docker executable not found in supported paths")
            throw DockerContainerDiscoveryError.dockerUnavailable
        }

        let environment = dockerProcessEnvironment(for: dockerExecutableURL)

        return try await Task.detached(priority: .userInitiated) {
            try runDockerSynchronously(
                executableURL: dockerExecutableURL,
                arguments: arguments,
                environment: environment
            )
        }.value
    }

    private nonisolated func runDockerSynchronously(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]
    ) throws -> String {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appending(path: "pluk-docker-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let outputURL = temporaryDirectory.appending(path: "stdout")
        let errorURL = temporaryDirectory.appending(path: "stderr")
        try Data().write(to: outputURL)
        try Data().write(to: errorURL)

        let outputHandle = try FileHandle(forWritingTo: outputURL)
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        defer {
            try? outputHandle.close()
            try? errorHandle.close()
        }
        process.standardOutput = outputHandle
        process.standardError = errorHandle

        do {
            try process.run()
        } catch {
            dockerDiscoveryLogger.error("Failed to start docker process: \(error.localizedDescription, privacy: .public)")
            throw DockerContainerDiscoveryError.dockerUnavailable
        }

        process.waitUntilExit()

        if process.terminationStatus == 0 {
            let stdout = (try? Data(contentsOf: outputURL)) ?? Data()
            return String(data: stdout, encoding: .utf8) ?? ""
        }
        let stderr = (try? Data(contentsOf: errorURL)) ?? Data()
        let message = String(data: stderr, encoding: .utf8) ?? ""
        dockerDiscoveryLogger.error("Docker command failed status=\(process.terminationStatus, privacy: .public) stderr=\(message.trimmingCharacters(in: .whitespacesAndNewlines), privacy: .public)")
        if message.localizedStandardContains("permission denied")
            && message.localizedStandardContains("docker.sock") {
            throw DockerContainerDiscoveryError.sandboxPermissionDenied
        }
        if message.localizedStandardContains("failed to connect to the docker API")
            || message.localizedStandardContains("cannot connect to the docker daemon")
            || message.localizedStandardContains("is the docker daemon running") {
            throw DockerContainerDiscoveryError.dockerUnavailable
        }
        throw NSError(
            domain: "DockerContainerDiscoveryService",
            code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    private var dockerExecutableURL: URL? {
        let candidates = [
            "/opt/homebrew/bin/docker",
            "/usr/local/bin/docker",
            "/Applications/Docker.app/Contents/Resources/bin/docker"
        ]

        return candidates
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    private func dockerProcessEnvironment(for executableURL: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        guard let dockerHost = dockerHost(for: executableURL, environment: environment) else { return environment }
        environment["DOCKER_HOST"] = dockerHost
        return environment
    }

    private func dockerHost(for executableURL: URL, environment: [String: String]) -> String? {
        if let dockerHost = environment["DOCKER_HOST"], !dockerHost.isEmpty {
            return dockerHost
        }

        if let contextDockerHost = activeContextDockerHost(
            executableURL: executableURL,
            environment: environment
        ) {
            return contextDockerHost
        }

        let socketPath = "/var/run/docker.sock"
        if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: socketPath), !destination.isEmpty {
            return "unix://\(destination)"
        }
        if FileManager.default.fileExists(atPath: socketPath) {
            return "unix://\(socketPath)"
        }
        return nil
    }

    private func activeContextDockerHost(
        executableURL: URL,
        environment: [String: String]
    ) -> String? {
        guard let output = try? runDockerSynchronously(
            executableURL: executableURL,
            arguments: ["context", "inspect", "--format", "{{.Endpoints.docker.Host}}"],
            environment: environment
        ) else {
            return nil
        }

        let dockerHost = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dockerHost.isEmpty, dockerHost != "<no value>" else {
            return nil
        }

        return dockerHost
    }

    private func makeCandidate(from container: DockerInspectContainer) -> DockerDatabaseCandidate? {
        let id = container.id
        let name = (container.name ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !name.isEmpty else {
            return nil
        }
        let image = container.config?.image ?? ""
        let env = parseEnvironment(container.config?.env)
        let isRunning = container.state?.running ?? false
        let createdAt = parseDockerDate(container.created)
        let startedAt = parseDockerDate(container.state?.startedAt)

        let networkPorts = container.networkSettings?.ports ?? [:]
        let hostBindings = container.hostConfig?.portBindings ?? [:]
        let ports = networkPorts.values.contains(where: { ($0 ?? []).isEmpty == false })
            ? networkPorts
            : hostBindings

        guard let databaseType = detectDatabaseType(name: name, image: image, ports: ports),
              let hostPort = mappedHostPort(for: databaseType, ports: ports) else {
            return nil
        }

        return DockerDatabaseCandidate(
            id: id,
            containerName: name,
            imageName: image,
            databaseType: databaseType,
            host: "localhost",
            port: hostPort,
            username: username(for: databaseType, env: env),
            password: password(for: databaseType, env: env),
            databaseName: databaseName(for: databaseType, env: env),
            isRunning: isRunning,
            createdAt: createdAt,
            startedAt: startedAt
        )
    }

    private func parseDockerDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty, !value.hasPrefix("0001-") else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private func parseEnvironment(_ values: [String]?) -> [String: String] {
        guard let values else { return [:] }
        return values.reduce(into: [:]) { result, value in
            guard let separator = value.firstIndex(of: "=") else { return }
            let key = String(value[..<separator])
            let envValue = String(value[value.index(after: separator)...])
            result[key] = envValue
        }
    }

    private func detectDatabaseType(
        name: String,
        image: String,
        ports: [String: [DockerInspectPortBinding]?]
    ) -> DatabaseType? {
        Self.detectedDatabaseType(
            name: name,
            image: image,
            exposedPorts: Set(ports.keys)
        )
    }

    nonisolated static func detectedDatabaseType(
        name: String,
        image: String,
        exposedPorts: Set<String>
    ) -> DatabaseType? {
        let imageTokens = image
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        let nameTokens = name
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        let tokens = Set(imageTokens + nameTokens)
        let excludedTokens: Set<String> = ["exporter", "pgadmin", "postgrest", "adminer"]
        if !tokens.isDisjoint(with: excludedTokens) {
            return nil
        }

        if exposedPorts.contains(where: { $0.hasPrefix("5432/") })
            || tokens.contains("postgres")
            || tokens.contains("postgresql") {
            return .postgres
        }
        if exposedPorts.contains(where: { $0.hasPrefix("3306/") })
            || tokens.contains("mysql")
            || tokens.contains("mariadb") {
            return .mysql
        }
        if exposedPorts.contains(where: { $0.hasPrefix("27017/") })
            || tokens.contains("mongo")
            || tokens.contains("mongodb") {
            return .mongodb
        }
        if exposedPorts.contains(where: { $0.hasPrefix("6379/") })
            || tokens.contains("redis")
            || tokens.contains("valkey") {
            return .redis
        }
        return nil
    }

    private func mappedHostPort(
        for databaseType: DatabaseType,
        ports: [String: [DockerInspectPortBinding]?]
    ) -> String? {
        let containerPort: String
        switch databaseType {
        case .postgres:
            containerPort = "5432/tcp"
        case .mysql:
            containerPort = "3306/tcp"
        case .mongodb:
            containerPort = "27017/tcp"
        case .redis:
            containerPort = "6379/tcp"
        case .convex, .supabase, .sqlite:
            return nil
        }

        guard let mappings = ports[containerPort] ?? nil,
              let firstMapping = mappings.first,
              let hostPort = firstMapping.hostPort,
              !hostPort.isEmpty else {
            return nil
        }
        return hostPort
    }

    private func username(for databaseType: DatabaseType, env: [String: String]) -> String? {
        switch databaseType {
        case .postgres:
            return env["POSTGRES_USER"] ?? "postgres"
        case .mysql:
            return env["MYSQL_USER"] ?? "root"
        case .mongodb:
            return env["MONGO_INITDB_ROOT_USERNAME"]
        case .redis:
            return env["REDIS_USER"]
        case .convex, .supabase, .sqlite:
            return nil
        }
    }

    private func password(for databaseType: DatabaseType, env: [String: String]) -> String? {
        switch databaseType {
        case .postgres:
            return env["POSTGRES_PASSWORD"]
        case .mysql:
            return env["MYSQL_PASSWORD"] ?? env["MYSQL_ROOT_PASSWORD"]
        case .mongodb:
            return env["MONGO_INITDB_ROOT_PASSWORD"]
        case .redis:
            return env["REDIS_PASSWORD"] ?? env["REDISCLI_AUTH"]
        case .convex, .supabase, .sqlite:
            return nil
        }
    }

    private func databaseName(for databaseType: DatabaseType, env: [String: String]) -> String? {
        switch databaseType {
        case .postgres:
            return env["POSTGRES_DB"] ?? env["POSTGRES_USER"] ?? "postgres"
        case .mysql:
            return env["MYSQL_DATABASE"]
        case .mongodb:
            return nil
        case .redis:
            return env["REDIS_DATABASE"] ?? "0"
        case .convex, .supabase, .sqlite:
            return nil
        }
    }
}
