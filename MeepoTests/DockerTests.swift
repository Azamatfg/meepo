import XCTest
@testable import Meepo

/// Fixtures cut from a real `docker system df` / `docker system df -v --format '{{json .}}'` (Docker 28.5, API 1.51,
/// 2026-09-27): what is safe to clear and whose the rest is.
final class DockerTests: XCTestCase {
    static let summary = """
        {"Active":"5","Reclaimable":"19.53GB (92%)","Size":"21.19GB","TotalCount":"85","Type":"Images"}
        {"Active":"8","Reclaimable":"0B (0%)","Size":"33.22MB","TotalCount":"8","Type":"Containers"}
        {"Active":"5","Reclaimable":"123.2GB (99%)","Size":"124.4GB","TotalCount":"44","Type":"Local Volumes"}
        {"Active":"0","Reclaimable":"39.92MB","Size":"39.92MB","TotalCount":"54","Type":"Build Cache"}
        """

    static let verbose = #"""
        {"Images":[
          {"Containers":"0","ID":"sha256:721873c34ceb","Repository":"postgres","Tag":"16-alpine","Size":"411MB","UniqueSize":"410.7MB"},
          {"Containers":"2","ID":"sha256:cf78e76683b9","Repository":"<none>","Tag":"<none>","Size":"411MB","UniqueSize":"401.4MB"},
          {"Containers":"2","ID":"sha256:298e5b3bc566","Repository":"redis","Tag":"latest","Size":"231MB","UniqueSize":"121.5MB"}],
         "Containers":[
          {"ID":"50af9188e33e","Names":"fleety-admin-db-dev","State":"running","Mounts":"admin-panel_admin_db_data_dev","Ports":"127.0.0.1:5433->5432/tcp",
           "Labels":"com.docker.compose.project.config_files=/Users/Azamat/taxinet/admin-panel/docker-compose.dev.yml,/Users/Azamat/taxinet/admin-panel/docker-compose.override.yml,com.docker.compose.project.working_dir=/Users/Azamat/taxinet/admin-panel,com.docker.compose.project=admin-panel,com.docker.compose.service=admin-db-dev,desktop.docker.io/ports/5432/tcp=127.0.0.1:5433"},
          {"ID":"cf55ca3a9700","Names":"fleety-sqlcheck","State":"running","Labels":"","Ports":"0.0.0.0:5599->5432/tcp, [::]:5599->5432/tcp",
           "Mounts":"4ecf076509022a42a69ad03ca8db9864e6942249dce08e385e78bac736ca423b"},
          {"ID":"afe0c97d88e0","Names":"payouts_db","State":"exited","Mounts":"taxi-kolesa_db_data","Ports":"",
           "Labels":"com.docker.compose.project=taxi-kolesa,com.docker.compose.service=db"}],
         "Volumes":[
          {"Name":"admin-panel_admin_db_data_dev","Links":"1","Size":"99.92MB","Labels":"com.docker.compose.project=admin-panel,com.docker.compose.volume=admin_db_data_dev"},
          {"Name":"regional-taxi_nominatim-flatnode","Links":"0","Size":"113.3GB","Labels":"com.docker.compose.project=regional-taxi,com.docker.compose.volume=nominatim-flatnode"},
          {"Name":"mds-kz_pgdata","Links":"0","Size":"118.2MB","Labels":"com.docker.compose.version=2.40.3,com.docker.compose.volume=pgdata,com.docker.compose.project=mds-kz"},
          {"Name":"nominatim-kz","Links":"0","Size":"6.942GB","Labels":""},
          {"Name":"taxi-kolesa_db_data","Links":"1","Size":"100.5MB","Labels":"com.docker.compose.project=taxi-kolesa,com.docker.compose.volume=db_data"},
          {"Name":"60972995ff744d0e7d50589c43a3a7a225253e8b0000000000000000000000","Links":"0","Size":"49.62MB","Labels":"com.docker.volume.anonymous="},
          {"Name":"a27d3d61e977df945b93b56de4245f1b6c2c5fcc0000000000000000000000","Links":"0","Size":"409.4kB","Labels":"com.docker.volume.anonymous="},
          {"Name":"4ecf076509022a42a69ad03ca8db9864e6942249dce08e385e78bac736ca423b","Links":"1","Size":"986.8MB","Labels":"com.docker.volume.anonymous="},
          {"Name":"5a217c6ae3e841b9a412f3b30b8a92e074d29b670000000000000000000000","Links":"N/A","Size":"78.41MB","Labels":"com.docker.volume.anonymous="}],
         "BuildCache":[]}
        """#

    static let projects = [
        Project(id: 4, name: "taxinet", path: "/Users/Azamat/taxinet", remote: nil, color: nil),
        Project(id: 6, name: "taxi-kolesa", path: "/Users/Azamat/Desktop/taxi kolesa project/backend/taxi-kolesa", remote: nil, color: nil),
    ]

    private var space: Docker.Space { Docker.space(summary: Self.summary, verbose: Self.verbose, projects: Self.projects) }

    func testAnImageAContainerStillRunsIsNotClearableEvenWithoutAName() {
        // The old "Dangling images" button freed 0 B: the one dangling image ran fleety's containers.
        XCTAssertEqual(space.unusedImages, ["postgres:16-alpine"])
        XCTAssertEqual(space.imagesBytes, 19_530_000_000, "Docker's own estimate")
        XCTAssertEqual(space.total, 21_190_000_000 + 33_220_000 + 124_400_000_000 + 39_920_000)

        // Docker counts shared layers of used images as reclaimable; with nothing unused there is nothing to clear.
        let allUsed = Self.verbose.replacingOccurrences(of: #"{"Containers":"0""#, with: #"{"Containers":"1""#)
        let used = Docker.space(summary: Self.summary, verbose: allUsed, projects: [])
        XCTAssertEqual(used.imagesBytes, 0)
        XCTAssertFalse(used.clearCommands.contains(["image", "prune", "-a", "-f"]))
    }

    func testANamedVolumeIsNeverSafeToClear() {
        XCTAssertEqual(space.leftoverVolumes.map { String($0.name.prefix(8)) }, ["60972995", "a27d3d61"],
                       "only unnamed volumes no container uses; one in use or of unknown use stays")
        XCTAssertEqual(space.leftoverBytes, 49_620_000 + 409_400)
        let words = space.clearCommands.flatMap { $0 }
        for named in ["regional-taxi_nominatim-flatnode", "mds-kz_pgdata", "nominatim-kz", "admin-panel_admin_db_data_dev"] {
            XCTAssertFalse(words.contains(named), named)
        }
        XCTAssertFalse(space.clearCommands.contains { $0.starts(with: ["volume", "prune"]) }, "before API 1.42 it takes named volumes too")
        XCTAssertEqual(space.clearCommands.map { Array($0.prefix(2)) }, [["image", "prune"], ["volume", "rm"], ["builder", "prune"]])
        XCTAssertEqual(space.safeBytes, 19_530_000_000 + 49_620_000 + 409_400 + 39_920_000)
    }

    func testAVolumeAContainerUsesCantBeDeleted() {
        let byName = Dictionary(uniqueKeysWithValues: space.owners.flatMap(\.volumes).map { ($0.name, $0) })
        XCTAssertNil(Docker.deleteArgs(for: byName["admin-panel_admin_db_data_dev"]!), "a running container uses it")
        XCTAssertNil(Docker.deleteArgs(for: byName["taxi-kolesa_db_data"]!), "a stopped container counts too")
        XCTAssertNil(Docker.deleteArgs(for: byName["5a217c6ae3e841b9a412f3b30b8a92e074d29b670000000000000000000000"]!),
                     "Docker didn't say: counts as used")
        XCTAssertEqual(Docker.deleteArgs(for: byName["regional-taxi_nominatim-flatnode"]!),
                       ["volume", "rm", "regional-taxi_nominatim-flatnode"], "by its exact name")
        XCTAssertEqual(space.usedBy["taxi-kolesa_db_data"], ["payouts_db (stopped)"])
    }

    func testSavedDataGoesToItsProject() {
        let owners = Dictionary(uniqueKeysWithValues: space.owners.map { ($0.title, $0) })
        // admin-panel's compose folder is inside taxinet: found by the container's working_dir label.
        XCTAssertEqual(owners["taxinet"]?.volumes.map(\.name), ["admin-panel_admin_db_data_dev"])
        XCTAssertEqual(owners["taxinet"]?.isProject, true)
        // No working_dir without a running one: the compose name is the project's folder name.
        XCTAssertEqual(owners["taxi-kolesa"]?.isProject, true)
        XCTAssertEqual(owners["regional-taxi"]?.isProject, false, "not a meepo project: shown by its compose name")
        XCTAssertEqual(owners["fleety-sqlcheck"]?.volumes.count, 1, "no compose project: the container that uses it")
        XCTAssertEqual(owners["Other volumes"]?.volumes.map(\.name), ["nominatim-kz", "5a217c6ae3e841b9a412f3b30b8a92e074d29b670000000000000000000000"])
        XCTAssertEqual(space.owners.first?.title, "regional-taxi", "biggest first")
    }

    func testLabelsKeepCommasInsideAValue() {
        let labels = Docker.labels("a.b=1,com.docker.compose.project.config_files=/x/one.yml,/x/two.yml,desktop.docker.io/ports/5432/tcp=127.0.0.1:5433,empty=")
        XCTAssertEqual(labels["com.docker.compose.project.config_files"], "/x/one.yml,/x/two.yml")
        XCTAssertEqual(labels["desktop.docker.io/ports/5432/tcp"], "127.0.0.1:5433")
        XCTAssertEqual(labels["empty"], "")
        XCTAssertEqual(labels.count, 4)
    }

    func testSizes() {
        XCTAssertEqual(Docker.bytes("19.53GB (92%)"), 19_530_000_000)
        XCTAssertEqual(Docker.bytes("13.15kB"), 13_150)
        XCTAssertEqual(Docker.bytes("393B"), 393)
        XCTAssertEqual(Docker.bytes("1.5MiB"), 1_572_864)
        XCTAssertEqual(Docker.bytes("N/A"), 0)
        XCTAssertEqual(Docker.size(145_663_140_000), "146 GB")
        XCTAssertEqual(Docker.size(20_560_000_000), "20.6 GB")
        XCTAssertEqual(Docker.size(1_025_505_386), "1.0 GB")
        XCTAssertEqual(Docker.size(999_960_000), "1.0 GB")
        XCTAssertEqual(Docker.size(39_920_000), "39.9 MB")
        XCTAssertEqual(Docker.size(393), "393 B")
    }

    func testComposeNameIsTheFolderName() {
        XCTAssertEqual(Docker.composeName(of: Self.projects[1]), "taxi-kolesa")
        XCTAssertEqual(Docker.owner(workingDir: nil, compose: "taxi-kolesa", projects: Self.projects)?.id, 6)
        XCTAssertEqual(Docker.owner(workingDir: "/Users/Azamat/taxinet/admin-panel", compose: "admin-panel", projects: Self.projects)?.id, 4)
        XCTAssertNil(Docker.owner(workingDir: "/Users/Azamat/taxinetwork", compose: nil, projects: Self.projects), "a prefix isn't a folder")
    }
}
