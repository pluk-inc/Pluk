<h1 align="center">Pluk</h1>

<p align="center">
  <img src="assets/logo.png" width="128" alt="Pluk logo" />
</p>

<p align="center">
  A fast, native macOS workspace for your databases.
</p>

<p align="center"><img alt="Platform" src="https://img.shields.io/badge/platform-macOS%2015%2B-blue" />&nbsp;<img alt="Swift" src="https://img.shields.io/badge/swift-6.0-orange" />&nbsp;<img alt="License" src="https://img.shields.io/badge/license-AGPL--3.0-green" />&nbsp;<img alt="Latest release" src="https://img.shields.io/github/v/release/pluk-inc/Pluk" /></p>

<p align="center">
  <a href="https://github.com/pluk-inc/Pluk/releases/latest">Download</a>
  &nbsp;·&nbsp;
  <a href="https://pluk.sh">Website</a>
  &nbsp;·&nbsp;
  <a href="https://github.com/pluk-inc/Pluk/issues/new/choose">Report an issue</a>
</p>

---

> Connect PostgreSQL, MySQL, MariaDB, MongoDB, Redis, SQLite, or Convex and work with the data in one focused Mac app — no Electron, no browser tabs, no context switching.

## Installation

Download the latest signed DMG from [Releases](https://github.com/pluk-inc/Pluk/releases/latest), open it, and drag Pluk to Applications.

Pluk requires macOS 15 or later and runs on Apple Silicon and Intel Macs.

## A native home for your data

<p align="center">
  <img src="assets/workspace.png" width="900" alt="Pluk workspace with recent connections and notebooks" />
</p>

<p align="center">
  <em>Keep connections, notebooks, local files, and Docker databases together in one workspace.</em>
</p>

<p align="center">
  <img src="assets/data-grid.png" width="900" alt="Browsing a PostgreSQL table in Pluk" />
</p>

<p align="center">
  <em>Browse, sort, filter, and edit real data in a fast native grid.</em>
</p>

<p align="center">
  <img src="assets/query-editor.png" width="900" alt="Pluk SQL query editor" />
</p>

<p align="center">
  <em>Open a query beside the active schema, write SQL with autocomplete, and keep the results in a tab.</em>
</p>

<p align="center">
  <img src="assets/table-assistant.png" width="900" alt="Pluk table assistant summarizing active data" />
</p>

<p align="center">
  <em>Ask about the table in front of you — Pluk already has the database, schema, and rows in context.</em>
</p>

<p align="center">
  <img src="assets/notebook-assistant.png" width="900" alt="Pluk assistant building a notebook dashboard" />
</p>

<p align="center">
  <em>Turn a question into queries, metrics, and charts while the assistant builds alongside you.</em>
</p>

<p align="center">
  <img src="assets/dashboard.png" width="900" alt="A finished analytics dashboard in Pluk" />
</p>

<p align="center">
  <em>Publish the result as a focused native dashboard.</em>
</p>

## Features

- **Native macOS interface** — AppKit and SwiftUI throughout, with real windows, tabs, sheets, keyboard navigation, and platform-standard controls.
- **Seven database families** — PostgreSQL, MySQL, MariaDB, MongoDB, Redis, SQLite, and Convex in one connection model.
- **Editable data grid** — browse, filter, sort, copy, paste, and edit rows directly, with dedicated views for larger values.
- **Query workspace** — SQL editing, autocomplete, multiple result sets, history, schema-aware execution, and saved notebooks.
- **Schema tools** — inspect columns and indexes, create tables and databases, and make schema changes without leaving the app.
- **Notebook dashboards** — combine queries, values, text, and charts in a flexible native canvas.
- **Context-aware assistant** — chat about the open table or notebook and review generated writes before they run.
- **Real-world connections** — SSH tunnels, SSL certificates, URI import, local SQLite files, and Docker container discovery.
- **Secure local handling** — Keychain-backed secrets, encrypted query history, and no Pluk telemetry in unconfigured community builds.

## Supported databases

| Database | What Pluk supports |
| --- | --- |
| PostgreSQL | Tables, schemas, SQL, JSON, SSL, SSH tunnels |
| MySQL and MariaDB | Tables, SQL, SSL, SSH tunnels |
| MongoDB | Collections, documents, filters, aggregation |
| Redis | Cursor-based key browsing, core data structures, TTLs, and commands |
| SQLite | Local database files and SQL |
| Convex | Projects, deployments, documents, and queries |

### Redis connections

Pluk accepts `redis://` and `rediss://` URLs, including password-only or ACL
username/password authentication and a logical database index such as `/2`.
TLS connections use full certificate and hostname verification. Saved passwords
are separated from connection metadata and stored in the macOS Keychain.

The key browser uses cursor-based `SCAN` pages and never uses `KEYS`. Strings,
hashes, lists, sets, sorted sets, streams, and RedisJSON values can be inspected;
streams are read-only and show a bounded first page in this version, while large
string and RedisJSON values currently load in full. RedisJSON appears only when
the module is installed. Pluk currently requires Redis 6 or later (or a
compatible Valkey server) because the client negotiates RESP3. The underlying
client guarantees Redis compatibility through 7.2.4; newer Redis releases may
work but should be validated for production use. Cluster, Sentinel, and Redis
over SSH tunnels are not supported yet.

## Building from source

You need macOS 15 or later and Xcode 26 or later with Swift 6 support.

```sh
git clone https://github.com/pluk-inc/Pluk.git
cd Pluk
open Pluk.xcodeproj
```

Build and run the shared `Collection` scheme. Swift Package Manager resolves the pinned dependencies on the first build.

If signing fails, select your own development team in Xcode or build locally with code signing disabled. Never commit personal signing configuration.

### Community builds

The database client builds without access to Pluk's hosted services. When `pluk/Secrets.xcconfig` is absent, PostHog, Sentry, WorkOS sign-in, Convex OAuth, and funded Bedrock AI are not configured. Manual Convex connections remain available.

Maintainers can copy `pluk/Secrets.xcconfig.example` to the ignored `pluk/Secrets.xcconfig` for official builds. Those values are embedded in the app binary and must not be treated as server-side secrets.

See [DATA_COLLECTION.md](DATA_COLLECTION.md) for the service and telemetry boundary.

## Project layout

```text
pluk/                 Main macOS app source and resources
plukTests/            Unit tests
plukUITests/          UI test target
BSON/                 Vendored BSON package
Pluk.xcodeproj/       Shared Xcode project, scheme, and package pins
scripts/              Release and rollback automation
```

## Contributing

Pull requests are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md), keep changes focused, and test user-facing behavior in the running app before submitting.

Please report vulnerabilities privately as described in [SECURITY.md](SECURITY.md). Third-party software and attribution are documented in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## License

Pluk's source code is available under the [GNU Affero General Public License v3.0](LICENSE).

The source license does not grant permission to use the Pluk name, logo, icon, or visual identity for another product. Forks and redistributed builds must follow the [Pluk Trademark Policy](TRADEMARKS.md).
