import Foundation

/// Postgres for Claude, read only (Tools → DATABASES). meepo runs only its own fixed queries — who am I, the schema —
/// through `psql`, every one in a read-only transaction with a timeout. Writing is stopped by the database itself:
/// Claude and meepo connect as a role that has SELECT and nothing else (`roleSQL`), created once by the owner.
enum Postgres {
    static let role = "claude_ro"
    static let timeout: TimeInterval = 20

    // MARK: Connecting

    /// Where psql lives when it isn't on PATH: Homebrew's keg-only libpq and postgresql@N, and Postgres.app.
    static let kegPaths = ["/opt/homebrew/opt/libpq/bin/psql"]
        + (15...18).reversed().map { "/opt/homebrew/opt/postgresql@\($0)/bin/psql" }
        + ["/Applications/Postgres.app/Contents/Versions/latest/bin/psql"]

    static let notInstalled = Failure(errorDescription: "psql isn't installed. In Terminal: brew install libpq")

    struct URLParts: Equatable {
        /// The URL without its password — safe to pass on a command line or show.
        let url: String
        let password: String?
        let user: String?
        let database: String?
    }

    /// postgres(ql)://user:pass@host:port/db?params → the parts; nil for anything else.
    static func parts(of url: String) -> URLParts? {
        guard var components = URLComponents(string: url.trimmingCharacters(in: .whitespaces)),
              ["postgres", "postgresql"].contains(components.scheme ?? ""), components.host != nil else { return nil }
        let password = components.password.flatMap { $0.removingPercentEncoding ?? $0 }
        components.password = nil
        let database = components.path.split(separator: "/").first.map(String.init)
        return URLParts(url: components.string ?? url, password: password, user: components.user, database: database)
    }

    /// For showing: the password as ***.
    static func masked(_ url: String) -> String {
        url.replacing(#/(://[^:/@]+):[^@]*@/#) { "\($0.1):***@" }
    }

    struct Failure: LocalizedError, Equatable {
        let errorDescription: String?
    }

    /// (executable, arguments, environment additions, timeout) → (status, stdout, stderr). Injected in tests.
    typealias Runner = @Sendable (String, [String], [String: String], TimeInterval) -> (Int32, String, String)

    /// One fixed query, read only, 15 s at most on the server; the password travels in PGPASSWORD, never in argv.
    /// `readOnly: false` is for the role SQL alone — the one write, run by the owner after the user said so.
    static func query(_ sql: String, url: String, psql: String, readOnly: Bool = true, runner: Runner = run) -> Result<String, Failure> {
        guard let parts = parts(of: url) else { return .failure(Failure(errorDescription: "That isn't a postgres:// address.")) }
        var env = ["PGCONNECT_TIMEOUT": "5"]
        if readOnly { env["PGOPTIONS"] = "-c default_transaction_read_only=on -c statement_timeout=15000" }
        if let password = parts.password { env["PGPASSWORD"] = password }
        // -w: never ask for a password — no password gives psql's error, not a prompt nobody can answer.
        let (status, out, err) = runner(psql, ["-X", "-w", "-A", "-t", "-q", "-v", "ON_ERROR_STOP=1", "-d", parts.url, "-c", sql], env, timeout)
        guard status == 0 else {
            let message = err.split(separator: "\n").first.map(String.init) ?? "psql stopped (\(status))"
            return .failure(Failure(errorDescription: message.replacingOccurrences(of: "psql: error: ", with: "")))
        }
        return .success(out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static let run: Runner = { executable, args, env, timeout in
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = args
        process.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return (-1, "", error.localizedDescription) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if process.isRunning { process.terminate() } }
        // stderr is small (one error line); reading stdout to the end first can't deadlock on it.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errors = err.fileHandleForReading.readDataToEndOfFile()
        process.waitForExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self), String(decoding: errors, as: UTF8.self))
    }

    // MARK: Who am I

    /// The connected user, and whether it could change anything: superuser, CREATE on the database, or
    /// INSERT/UPDATE/DELETE/TRUNCATE on any table.
    static let whoAmISQL = """
        SELECT current_user || '|' || (r.rolsuper OR has_database_privilege(current_database(), 'CREATE') OR EXISTS (
          SELECT 1 FROM pg_tables t WHERE t.schemaname NOT IN ('pg_catalog', 'information_schema')
            -- CASE, not AND: only a schema the user may enter is asked about (PostGIS's tiger would raise an error).
            AND CASE WHEN has_schema_privilege(t.schemaname, 'USAGE')
                     THEN has_table_privilege(format('%I.%I', t.schemaname, t.tablename), 'INSERT, UPDATE, DELETE, TRUNCATE')
                     ELSE false END))::text
        FROM pg_roles r WHERE r.rolname = current_user
        """

    struct Identity: Equatable {
        let user: String
        let canWrite: Bool
    }

    static func identity(from output: String) -> Identity? {
        let fields = output.split(separator: "|").map(String.init)
        guard fields.count == 2 else { return nil }
        return Identity(user: fields[0], canWrite: fields[1] == "true")
    }

    // MARK: The read-only role

    /// A password that needs no quoting anywhere: letters and digits.
    static func newPassword() -> String {
        String((0..<24).map { _ in "abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789".randomElement()! })
    }

    /// Creates (or updates) the role that can only read: SELECT on every table in public, now and later ones,
    /// every transaction read only, 15 s per query. Run once, by the owner.
    static func roleSQL(database: String, password: String) -> String {
        """
        DO $$ BEGIN
          IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '\(role)') THEN CREATE ROLE \(role) LOGIN;
          END IF;
        END $$;
        ALTER ROLE \(role) WITH LOGIN PASSWORD '\(password)' NOSUPERUSER NOCREATEDB NOCREATEROLE;
        ALTER ROLE \(role) SET default_transaction_read_only = on;
        ALTER ROLE \(role) SET statement_timeout = '15s';
        GRANT CONNECT ON DATABASE \(quoted(database)) TO \(role);
        GRANT USAGE ON SCHEMA "public" TO \(role);
        GRANT SELECT ON ALL TABLES IN SCHEMA "public" TO \(role);
        ALTER DEFAULT PRIVILEGES IN SCHEMA "public" GRANT SELECT ON TABLES TO \(role);
        """
    }

    /// The owner's address with the role and its password instead.
    static func roleURL(from ownerURL: String, password: String) -> String? {
        guard var components = URLComponents(string: ownerURL) else { return nil }
        components.user = role
        components.password = password
        return components.string
    }

    private static func quoted(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: Schema — one query, then drawn from memory

    struct Column: Codable, Equatable, Hashable {
        let name: String
        let type: String
        let pk: Bool
    }

    struct ForeignKey: Codable, Equatable, Hashable {
        let columns: [String]
        let table: String
    }

    struct Table: Codable, Equatable, Hashable, Identifiable {
        let name: String
        let columns: [Column]
        let fks: [ForeignKey]
        var id: String { name }
    }

    /// Every table outside the system schemas with its columns, primary key and foreign keys, as one JSON array —
    /// one round trip, so even a few hundred tables come back at once. Names are schema-qualified outside "public".
    static let schemaSQL = """
        WITH t AS (
          SELECT c.oid, CASE WHEN n.nspname = 'public' THEN c.relname ELSE n.nspname || '.' || c.relname END AS name
          FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
          WHERE c.relkind IN ('r', 'p') AND n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname NOT LIKE 'pg_toast%'
            AND has_schema_privilege(n.oid, 'USAGE') -- what the role can read, not PostGIS's tiger or topology
        )
        SELECT coalesce(json_agg(json_build_object(
          'name', t.name,
          'columns', (SELECT coalesce(json_agg(json_build_object('name', a.attname, 'type', format_type(a.atttypid, a.atttypmod),
                        'pk', EXISTS (SELECT 1 FROM pg_constraint p WHERE p.conrelid = t.oid AND p.contype = 'p' AND a.attnum = ANY (p.conkey)))
                        ORDER BY a.attnum), '[]')
                      FROM pg_attribute a WHERE a.attrelid = t.oid AND a.attnum > 0 AND NOT a.attisdropped),
          'fks', (SELECT coalesce(json_agg(json_build_object(
                    'columns', (SELECT json_agg(a.attname ORDER BY k.i) FROM unnest(f.conkey) WITH ORDINALITY k(n, i)
                                JOIN pg_attribute a ON a.attrelid = f.conrelid AND a.attnum = k.n),
                    'table', (SELECT r.name FROM t r WHERE r.oid = f.confrelid))), '[]')
                  FROM pg_constraint f WHERE f.conrelid = t.oid AND f.contype = 'f')
        ) ORDER BY t.name), '[]')
        FROM t
        """

    static func tables(fromJSON json: String) -> [Table]? {
        try? JSONDecoder().decode([Table].self, from: Data(json.utf8))
    }

    /// Tables linked with `name`: the ones it points to first, then the ones pointing to it, each once, by name.
    static func neighbours(of name: String, in tables: [Table]) -> [String] {
        let outgoing = (tables.first { $0.name == name }?.fks.map(\.table) ?? []).filter { $0 != name }
        let incoming = tables.filter { $0.name != name && $0.fks.contains { $0.table == name } }.map(\.name)
        var seen = Set<String>()
        return (Array(Set(outgoing)).sorted() + incoming.sorted()).filter { seen.insert($0).inserted }
    }

    /// Most neighbours drawn at once: a users table can have a hundred, and a picture of all of them is slow and unreadable.
    static let neighbourLimit = 16
    /// Columns listed for the table in the middle; neighbours show their keys only.
    static let columnLimit = 14

    /// A table and the ones it links to or is linked from (up to `neighbourLimit`), as a Mermaid ER diagram: small
    /// enough to draw at once. Neighbours show their key columns only; the chosen table up to `columnLimit` columns.
    static func mermaid(around name: String, in tables: [Table]) -> String {
        guard tables.contains(where: { $0.name == name }) else { return "erDiagram" }
        let near = Set(neighbours(of: name, in: tables).prefix(neighbourLimit))
        let shown = tables.filter { $0.name == name || near.contains($0.name) }
        var lines = ["erDiagram"]
        for table in shown {
            let keys = Set(table.fks.flatMap(\.columns))
            let columns = table.name == name
                ? Array(table.columns.prefix(columnLimit))
                : table.columns.filter { $0.pk || keys.contains($0.name) }
            lines.append("  \(entity(table.name)) {")
            for column in columns {
                let mark = column.pk ? " PK" : keys.contains(column.name) ? " FK" : ""
                lines.append("    \(word(column.type)) \(word(column.name))\(mark)")
            }
            if table.name == name, table.columns.count > columnLimit {
                lines.append("    etc \(word("and_\(table.columns.count - columnLimit)_more_columns"))")
            }
            lines.append("  }")
        }
        for table in shown {
            for fk in table.fks where table.name == name ? near.contains(fk.table) : fk.table == name {
                lines.append("  \(entity(fk.table)) ||--o{ \(entity(table.name)) : \"\(fk.columns.joined(separator: ", "))\"")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Mermaid names take letters, digits and _ (entities also -): anything else becomes _. An attribute word must
    /// start with a letter or _, so one starting otherwise gets a leading _.
    private static func entity(_ name: String) -> String { sanitized(name, keeping: "-") }
    private static func word(_ text: String) -> String {
        let clean = sanitized(text, keeping: "_")
        return clean.first.map { $0.isLetter || $0 == "_" } == true ? clean : "_" + clean
    }

    private static func sanitized(_ text: String, keeping extra: Character) -> String {
        String(text.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == extra ? $0 : "_" })
    }

    // MARK: Found on a server

    /// Lists the Postgres containers on a server: name | first network IP | POSTGRES_USER= POSTGRES_DB=. The password
    /// is filtered out on the server — it never travels. Read only (docker ps / inspect).
    static let findOnServerCommand = #"for c in $(docker ps --format '{{.Names}} {{.Image}}' | awk 'tolower($2) ~ /postgres|postgis|timescale/ {print $1}'); do ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$c" | awk '{print $1}'); env=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$c" | grep -E '^POSTGRES_(USER|DB)=' | tr '\n' ' '); echo "$c|$ip|$env"; done"#

    /// A Postgres container on a server: who owns it, which database, where it listens inside the server.
    struct Found: Hashable, Identifiable {
        let container: String
        let user: String
        let database: String
        let ip: String
        var id: String { container }
        /// The address as the server sees it (no password: the role gets its own).
        var url: String { "postgresql://\(user)@\(ip):5432/\(database)" }
    }

    /// Each container line (name | IP | POSTGRES_USER= POSTGRES_DB=) → a Found; lines without an IP are skipped.
    static func found(fromServerListing output: String) -> [Found] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3, fields[1].wholeMatch(of: /[0-9.]{7,15}/) != nil,
                  isSafeName(fields[0]) else { return nil }
            var env: [String: String] = [:]
            for pair in fields[2].split(separator: " ") {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2, isSafeName(parts[1]) { env[parts[0]] = parts[1] }
            }
            let user = env["POSTGRES_USER"] ?? "postgres"
            return Found(container: fields[0], user: user, database: env["POSTGRES_DB"] ?? user, ip: fields[1])
        }
    }

    /// Container, user and database names that go into a shell command unquoted: nothing a shell reads specially.
    static func isSafeName(_ name: String) -> Bool { name.wholeMatch(of: /[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}/) != nil }

    /// Runs `sql` inside the container as its owner over the local socket — no password — the SQL passed as base64,
    /// so no quote in it can reach the shell. The one write meepo makes, and only after the user said so.
    static func createRoleCommand(in found: Found, sql: String) -> String? {
        guard [found.container, found.user, found.database].allSatisfy(isSafeName) else { return nil }
        let encoded = Data(sql.utf8).base64EncodedString()
        return "echo \(encoded) | base64 -d | docker exec -i \(found.container) psql -v ON_ERROR_STOP=1 -q -U \(found.user) -d \(found.database)"
    }

    // MARK: Found in the project

    /// postgres:// addresses in the project's .mcp.json and .env files, each once.
    static func foundURLs(in projectPath: String) -> [String] {
        let root = URL(filePath: projectPath)
        let files = [".mcp.json"] + ((try? FileManager.default.contentsOfDirectory(atPath: projectPath)) ?? [])
            .filter { $0 == ".env" || $0.hasPrefix(".env.") }.sorted()
        var result: [String] = []
        for file in files {
            guard let text = try? String(contentsOf: root.appending(path: file), encoding: .utf8) else { continue }
            for match in text.matches(of: #/postgres(?:ql)?://[^\s"'`]+/#) {
                let url = String(match.output)
                if parts(of: url) != nil, !result.contains(url) { result.append(url) }
            }
        }
        return result
    }

    /// .mcp.json with every occurrence of `oldURL` replaced by `newURL` — Claude's postgres server switches role.
    /// A file with no such address gets a server of its own: "postgres", or `name` beside an existing one (a local
    /// dev database stays as it is). nil when the file isn't JSON meepo can read.
    static func mcpConfig(_ text: String?, replacing oldURL: String?, with newURL: String, name: String = "postgres") -> (text: String, key: String)? {
        var root = (text.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]) ?? [:]
        if text != nil, root.isEmpty, !(text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        var key: String?
        for (server, value) in servers {
            guard var entry = value as? [String: Any], var args = entry["args"] as? [String] else { continue }
            for (index, arg) in args.enumerated() where arg == oldURL {
                args[index] = newURL
                key = server
            }
            entry["args"] = args
            servers[server] = entry
        }
        if key == nil {
            let added = servers[name] == nil ? name : servers["postgres"] == nil ? "postgres" : name + "-2"
            servers[added] = ["command": "npx", "args": ["-y", "@modelcontextprotocol/server-postgres", newURL]] as [String: Any]
            key = added
        }
        root["mcpServers"] = servers
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return (String(decoding: data, as: UTF8.self) + "\n", key!)
    }

    /// .mcp.json without the server `name`; nil when there's no such server or the file isn't JSON meepo can read.
    static func mcpConfig(_ text: String, removing name: String) -> String? {
        guard var root = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              var servers = root["mcpServers"] as? [String: Any], servers.removeValue(forKey: name) != nil else { return nil }
        root["mcpServers"] = servers
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// The .mcp.json server name for a database: "postgres" on this Mac's localhost, else after where it is
    /// ("postgres-main" for a server, "postgres-db-taxinet-kz" for a host).
    static func mcpName(for url: String, server: String?) -> String {
        if let server { return "postgres-" + slug(server) }
        guard let host = URLComponents(string: url)?.host, !["127.0.0.1", "localhost", "::1"].contains(host) else { return "postgres" }
        return "postgres-" + slug(host)
    }

    /// Whether the address is this Mac's own (a local database: no need to ask before each query).
    static func isLocal(_ url: String) -> Bool {
        ["127.0.0.1", "localhost", "::1"].contains(URLComponents(string: url)?.host ?? "")
    }

    private static func slug(_ text: String) -> String {
        String(text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }).split(separator: "-").joined(separator: "-")
    }
}
