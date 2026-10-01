// GitHubSyncTransport.swift
// M7: GitHub private-repository provisioning and non-force Git-tree commits matching Android.

import Foundation

public struct GitHubSyncTransport: SyncTransport {
    public let owner: String
    public let repository: String
    public let path: String
    private let token: String
    private let http: SyncHTTP
    public var targetID: String { "github:\(owner)/\(repository)/\(path)" }
    private var root: String { "repos/\(owner)/\(repository)" }

    public init(owner: String, repository: String = "NeriPlayer-Backup", path: String = "backup.json",
                token: String, http: SyncHTTP = SyncHTTP()) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard !owner.isEmpty, !repository.isEmpty, !token.isEmpty, !token.contains(where: { $0.isWhitespace }),
              [owner, repository].allSatisfy({ $0.unicodeScalars.allSatisfy(allowed.contains) && $0 != "." && $0 != ".." }),
              !path.hasPrefix("/"), !path.split(separator: "/").contains(".."), !path.isEmpty else { throw SyncError.invalidConfiguration }
        self.owner = owner; self.repository = repository; self.path = path; self.token = token; self.http = http
    }

    public func createPrivateRepository() async throws {
        let user = try await json("user")
        guard user.text("login").lowercased() == owner.lowercased() else { throw SyncError.invalidConfiguration }
        _ = try await json("user/repos", method: "POST", body: SyncRecord([
            "name": .string(repository), "private": .bool(true), "auto_init": .bool(true),
            "description": .string("NeriPlayer decentralized metadata backup")]))
    }

    public func fetch() async throws -> SyncRemoteSnapshot {
        let repo = try await json(root)
        let branch = repo.text("default_branch", default: "main")
        let ref = try await json(root + "/git/ref/heads/" + branch)
        guard case .object(let object) = ref.fields["object"], case .string(let head) = object["sha"] else {
            throw SyncError.invalidSnapshot
        }
        var snapshots: [SyncSnapshot] = []
        var storagePaths: [String] = []
        for candidate in Array(Set([path, "backup-raw.bin", "backup.bin"])).sorted() {
            var components = URLComponents(url: endpoint(root + "/contents/" + candidate), resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "ref", value: head)]
            guard let url = components?.url else { throw SyncError.invalidConfiguration }
            var request = authenticated(url)
            request.setValue("application/vnd.github.raw+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await http.send(request)
            if response.statusCode == 404 { continue }
            try SyncHTTP.check(response)
            snapshots.append(try SyncSnapshotCodec.decode(data))
            storagePaths.append(candidate)
        }
        let merged = snapshots.reduce(nil as SyncSnapshot?) { previous, snapshot in
            previous.map { SyncMergeEngine.merge(local: $0, remote: snapshot).snapshot } ?? snapshot
        }
        return SyncRemoteSnapshot(data: try merged.map(SyncSnapshotCodec.encode), version: head,
                                  context: branch, storagePaths: storagePaths)
    }

    public func upload(_ data: Data, replacing remote: SyncRemoteSnapshot) async throws -> String? {
        guard let head = remote.version, let branch = remote.context, !data.isEmpty,
              data.count <= SyncSnapshotCodec.jsonLimit else { throw SyncError.unsafeRemoteVersion }
        let commit = try await json(root + "/git/commits/" + head)
        guard case .object(let tree) = commit.fields["tree"], case .string(let treeSHA) = tree["sha"] else {
            throw SyncError.invalidSnapshot
        }
        let blob = try await json(root + "/git/blobs", method: "POST", body: SyncRecord([
            "content": .string(data.base64EncodedString()), "encoding": .string("base64")]))
        let entry = SyncRecord(["path": .string(path), "mode": .string("100644"), "type": .string("blob"), "sha": .string(blob.text("sha"))])
        var treeBody = SyncRecord(["base_tree": .string(treeSHA)])
        let deletions = remote.storagePaths.filter { $0 != path }.map {
            SyncRecord(["path": .string($0), "mode": .string("100644"), "type": .string("blob"), "sha": .null])
        }
        treeBody.set("tree", [entry] + deletions)
        let updatedTree = try await json(root + "/git/trees", method: "POST", body: treeBody)
        let updatedCommit = try await json(root + "/git/commits", method: "POST", body: SyncRecord([
            "message": .string("NeriPlayer metadata sync (macOS)"), "tree": .string(updatedTree.text("sha")),
            "parents": .array([.string(head)])]))
        let newHead = updatedCommit.text("sha")
        guard !newHead.isEmpty else { throw SyncError.invalidSnapshot }
        _ = try await json(root + "/git/refs/heads/" + branch, method: "PATCH", body: SyncRecord([
            "sha": .string(newHead), "force": .bool(false)]))
        return newHead
    }

    private func endpoint(_ path: String) -> URL {
        URL(string: "https://api.github.com").map { $0.appendingPathComponent(path) } ?? URL(fileURLWithPath: "/invalid-sync-api")
    }
    private func authenticated(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("NeriPlayer-macOS", forHTTPHeaderField: "User-Agent")
        return request
    }
    private func json(_ path: String, method: String = "GET", body: SyncRecord? = nil) async throws -> SyncRecord {
        var request = authenticated(endpoint(path)); request.httpMethod = method
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await http.send(request)
        try SyncHTTP.check(response)
        do { return try JSONDecoder().decode(SyncRecord.self, from: data) } catch { throw SyncError.invalidSnapshot }
    }
}
