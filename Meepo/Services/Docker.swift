import Foundation

/// Docker upkeep (SPEC module 11): where Docker's disk space went, what is safe to clear, and each project's
/// saved data. Named volumes are projects' data (a database), never junk: nothing clears them in bulk.
enum Docker {
    /// A container from `docker system df -v` or `docker ps` — both print the same fields.
    struct Container: Equatable, Sendable {
        let id: String
        let name: String
        let labels: [String: String]
        /// Volume names and host folders it mounts.
        let mounts: [String]
        let isRunning: Bool
        /// "127.0.0.1:5433->5432/tcp, [::]:5599->5432/tcp"
        let ports: String
        var composeProject: String? { labels["com.docker.compose.project"] }
        var workingDir: String? { labels["com.docker.compose.project.working_dir"] }
    }

    struct Volume: Equatable, Identifiable, Sendable {
        let name: String
        let labels: [String: String]
        /// Containers using it, stopped ones too; nil when Docker didn't say — then it counts as used.
        let links: Int?
        let bytes: Int64
        var id: String { name }
        /// Made for a container without a name (a Dockerfile's VOLUME); left behind when the container goes.
        var isAnonymous: Bool { labels["com.docker.volume.anonymous"] != nil }
    }

    /// One project's saved data: its volumes.
    struct Owner: Identifiable, Equatable, Sendable {
        let title: String
        /// A meepo project, not just a compose name or a container.
        let isProject: Bool
        var volumes: [Volume]
        var id: String { title }
        var bytes: Int64 { volumes.reduce(0) { $0 + $1.bytes } }
    }

    /// What the DOCKER tab shows.
    struct Space: Equatable, Sendable {
        var total: Int64 = 0
        /// "postgres:16-alpine"; images no container (running or stopped) uses.
        var unusedImages: [String] = []
        /// Docker's own estimate of what removing them frees.
        var imagesBytes: Int64 = 0
        /// Unnamed volumes no container uses.
        var leftoverVolumes: [Volume] = []
        var buildCacheBytes: Int64 = 0
        /// Every other volume, by project, biggest first.
        var owners: [Owner] = []
        /// Container names per volume, "(stopped)" marked.
        var usedBy: [String: [String]] = [:]

        var leftoverBytes: Int64 { leftoverVolumes.reduce(0) { $0 + $1.bytes } }
        var safeBytes: Int64 { imagesBytes + leftoverBytes + buildCacheBytes }

        /// What Clear runs, in order: only images and build cache nothing uses, and the leftover volumes by name —
        /// never `volume prune`, which before Docker API 1.42 removes named volumes too.
        var clearCommands: [[String]] {
            var commands: [[String]] = []
            if !unusedImages.isEmpty { commands.append(["image", "prune", "-a", "-f"]) }
            if !leftoverVolumes.isEmpty { commands.append(["volume", "rm"] + leftoverVolumes.map(\.name)) }
            if buildCacheBytes > 0 { commands.append(["builder", "prune", "-a", "-f"]) }
            return commands
        }
    }

    /// `docker system df --format '{{json .}}'` (totals) and `docker system df -v --format '{{json .}}'` (each
    /// image, container and volume) → what is safe to clear and whose the rest is.
    static func space(summary: String, verbose: String, projects: [Project]) -> Space {
        var space = Space()
        var reclaimable: [String: Int64] = [:]
        for line in summary.split(separator: "\n") {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = json["Type"] as? String else { continue }
            space.total += bytes(json["Size"] as? String ?? "")
            reclaimable[type] = bytes(json["Reclaimable"] as? String ?? "")
        }
        let all = (try? JSONSerialization.jsonObject(with: Data(verbose.utf8)) as? [String: Any]) ?? [:]
        let containers = (all["Containers"] as? [[String: Any]] ?? []).compactMap(container)
        space.unusedImages = (all["Images"] as? [[String: Any]] ?? []).compactMap { image in
            // A dangling image a container still runs isn't free to take ("Containers" counts stopped ones too).
            guard Int(image["Containers"] as? String ?? "") == 0 else { return nil }
            let repository = image["Repository"] as? String ?? "<none>"
            let tag = image["Tag"] as? String ?? "<none>"
            return repository == "<none>" ? "unnamed image" : tag == "<none>" ? repository : "\(repository):\(tag)"
        }
        space.imagesBytes = space.unusedImages.isEmpty ? 0 : reclaimable["Images"] ?? 0
        space.buildCacheBytes = reclaimable["Build Cache"] ?? 0

        let volumes = (all["Volumes"] as? [[String: Any]] ?? []).compactMap { json -> Volume? in
            guard let name = json["Name"] as? String else { return nil }
            return Volume(name: name, labels: labels(json["Labels"] as? String ?? ""),
                          links: Int(json["Links"] as? String ?? ""), bytes: bytes(json["Size"] as? String ?? ""))
        }
        var owners: [String: Owner] = [:]
        for volume in volumes {
            if volume.isAnonymous && volume.links == 0 {
                space.leftoverVolumes.append(volume)
                continue
            }
            let users = containers.filter { $0.mounts.contains(volume.name) }
            if !users.isEmpty { space.usedBy[volume.name] = users.map { $0.isRunning ? $0.name : "\($0.name) (stopped)" } }
            let compose = users.lazy.compactMap(\.composeProject).first ?? volume.labels["com.docker.compose.project"]
            let workingDir = users.lazy.compactMap(\.workingDir).first
                ?? containers.first { compose != nil && $0.composeProject == compose }?.workingDir
            let project = owner(workingDir: workingDir, compose: compose, projects: projects)
            let title = project?.name ?? compose ?? users.first?.name ?? "Other volumes"
            owners[title, default: Owner(title: title, isProject: project != nil, volumes: [])].volumes.append(volume)
        }
        space.owners = owners.values.map { owner in
            var sorted = owner
            sorted.volumes.sort { $0.bytes > $1.bytes }
            return sorted
        }
        .sorted { ($0.bytes, $1.title) > ($1.bytes, $0.title) }
        return space
    }

    /// Whose a compose project is: the meepo project holding its folder (the deepest, so a worktree beats its
    /// checkout), else the project named like it — compose names a project after its folder.
    static func owner(workingDir: String?, compose: String?, projects: [Project]) -> Project? {
        if let dir = workingDir,
           let project = projects.filter({ dir == $0.path || dir.hasPrefix($0.path + "/") }).max(by: { $0.path.count < $1.path.count }) {
            return project
        }
        guard let compose else { return nil }
        return projects.first { composeName(of: $0) == compose }
    }

    /// Delete one volume by its name — only when no container uses it, running or stopped.
    static func deleteArgs(for volume: Volume) -> [String]? {
        volume.links == 0 ? ["volume", "rm", volume.name] : nil
    }

    /// `docker ps --format '{{json .}}'`, one container per line.
    static func parseContainers(_ output: String) -> [Container] {
        output.split(separator: "\n").compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]).flatMap(container)
        }
    }

    private static func container(_ json: [String: Any]) -> Container? {
        guard let name = json["Names"] as? String else { return nil }
        let mounts = (json["Mounts"] as? String ?? "").split(separator: ",").map(String.init)
        return Container(id: json["ID"] as? String ?? name, name: name, labels: labels(json["Labels"] as? String ?? ""),
                         mounts: mounts, isRunning: json["State"] as? String == "running", ports: json["Ports"] as? String ?? "")
    }

    /// "a=1,b=/x/one.yml,/x/two.yml" → a: 1, b: "/x/one.yml,/x/two.yml": a value can hold commas (compose lists its
    /// files that way), so a piece that doesn't start with a key belongs to the value before it.
    static func labels(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var last: String?
        for piece in text.split(separator: ",", omittingEmptySubsequences: false) {
            if let equals = piece.firstIndex(of: "="), piece[..<equals].wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9._\/-]*/) != nil {
                let key = String(piece[..<equals])
                result[key] = String(piece[piece.index(after: equals)...])
                last = key
            } else if let key = last {
                result[key, default: ""] += "," + piece
            }
        }
        return result
    }

    /// Docker's sizes: "113.3GB", "13.15kB", "393B", "19.53GB (92%)"; "N/A" and the rest are 0.
    static func bytes(_ text: String) -> Int64 {
        guard let match = text.prefixMatch(of: /\s*([0-9.]+)\s*([kKMGTP]?i?B)/), let value = Double(match.1) else { return 0 }
        let units: [String: Double] = ["B": 1, "kB": 1e3, "KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12, "PB": 1e15,
                                       "KiB": 1024, "MiB": 1_048_576, "GiB": 1_073_741_824, "TiB": 1_099_511_627_776]
        return Int64(value * (units[String(match.2)] ?? 0))
    }

    /// "393 B", "39.9 MB", "19.5 GB", "146 GB" — decimal, like Docker; the same in every locale.
    static func size(_ bytes: Int64) -> String {
        guard bytes >= 1000 else { return "\(max(bytes, 0)) B" }
        var value = Double(bytes)
        var unit = 0
        let units = ["B", "kB", "MB", "GB", "TB", "PB"]
        while value >= 999.95, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        return String(format: value < 99.95 ? "%.1f %@" : "%.0f %@", value, units[unit])
    }

    /// Compose names a project after its folder: lowercased, only [a-z0-9_-].
    static func composeName(of project: Project) -> String {
        URL(filePath: project.path).lastPathComponent.lowercased()
            .replacingOccurrences(of: "[^a-z0-9_-]", with: "", options: .regularExpression)
    }

    /// Host ports a container publishes: "0.0.0.0:8000-8002->8000-8002/tcp, [::]:5599->5432/tcp" → 8000, 8001,
    /// 8002, 5599. Exposed-only ports ("6379/tcp") aren't reachable from this Mac, and UDP isn't a TCP port.
    static func publishedPorts(_ text: String) -> [Int] {
        var result: [Int] = []
        for mapping in text.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            guard mapping.hasSuffix("/tcp"), let arrow = mapping.range(of: "->"),
                  let host = mapping[..<arrow.lowerBound].split(separator: ":").last else { continue }
            let bounds = host.split(separator: "-").compactMap { Int($0) }
            guard let low = bounds.first, let high = bounds.last, low <= high, high - low < 1000 else { continue }
            for port in low...high where !result.contains(port) { result.append(port) }
        }
        return result
    }

    /// Blocking; call off the main thread. nil when docker isn't there, isn't running, or refused.
    static func run(_ docker: String, _ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(filePath: docker)
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitForExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
