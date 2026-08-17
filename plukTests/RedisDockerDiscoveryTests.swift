import Foundation
import Testing
@testable import Pluk

struct RedisDockerDiscoveryTests {
    @Test
    func detectsRedisAndValkeyButNotExporterSidecars() {
        #expect(
            DockerContainerDiscoveryService.detectedDatabaseType(
                name: "cache",
                image: "redis:7-alpine",
                exposedPorts: ["6379/tcp"]
            ) == .redis
        )
        #expect(
            DockerContainerDiscoveryService.detectedDatabaseType(
                name: "session-valkey-1",
                image: "valkey/valkey:8",
                exposedPorts: []
            ) == .redis
        )
        #expect(
            DockerContainerDiscoveryService.detectedDatabaseType(
                name: "redis-exporter",
                image: "oliver006/redis_exporter:latest",
                exposedPorts: ["9121/tcp"]
            ) == nil
        )
    }

    @Test
    func buildsPasswordOnlyRedisCandidateURIWithoutRequiringCredentials() {
        let candidate = DockerDatabaseCandidate(
            id: "container-id",
            containerName: "project-redis-1",
            imageName: "redis:7",
            databaseType: .redis,
            host: "localhost",
            port: "6380",
            username: nil,
            password: "p@ss/word",
            databaseName: "2",
            isRunning: true,
            createdAt: nil,
            startedAt: nil
        )

        #expect(candidate.isReadyToConnect)
        #expect(candidate.connectionName == "project")
        #expect(candidate.connectionURI == "redis://:p%40ss%2Fword@localhost:6380/2")
    }

    @Test
    func requiresAPasswordWhenDockerDiscoveryFindsAnACLUsername() {
        let candidate = DockerDatabaseCandidate(
            id: "container-id",
            containerName: "project-redis-1",
            imageName: "redis:7",
            databaseType: .redis,
            host: "localhost",
            port: "6379",
            username: "cache-user",
            password: nil,
            databaseName: "0",
            isRunning: true,
            createdAt: nil,
            startedAt: nil
        )

        #expect(!candidate.isReadyToConnect)
    }

    @Test
    func acceptsPasswordlessRedisCandidates() {
        let candidate = DockerDatabaseCandidate(
            id: "container-id",
            containerName: "project-redis-1",
            imageName: "redis:7",
            databaseType: .redis,
            host: "localhost",
            port: "6379",
            username: nil,
            password: nil,
            databaseName: "0",
            isRunning: true,
            createdAt: nil,
            startedAt: nil
        )

        #expect(candidate.isReadyToConnect)
    }
}
