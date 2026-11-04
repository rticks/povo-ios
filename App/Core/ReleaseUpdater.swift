import Foundation
import PovoKit

struct AvailableUpdate: Sendable {
    let version: String
    let notes: String?
    let downloadURL: URL
}

enum ReleaseUpdater {
    static var repository: String { Bundle.main.object(forInfoDictionaryKey: "PovoUpdateRepository") as? String ?? "rticks/povo-ios" }
    static var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0" }
    static var actionsURL: URL { URL(string: "https://github.com/\(repository)/actions")! }
    static var releasesURL: URL { URL(string: "https://github.com/\(repository)/releases")! }
    static func check() async throws -> AvailableUpdate? {
        guard repository.range(of: "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", options: .regularExpression) != nil else { throw AppFailure("更新先の設定が正しくありません") }
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("povo-ios/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AppFailure("GitHubの応答を読み取れません") }
        if http.statusCode == 404 { throw AppFailure("リリースが未公開、またはリポジトリが非公開です。GitHubにログインしたブラウザでActionsの成果物を取得してください。アプリにGitHubトークンは埋め込みません。") }
        if http.statusCode == 403 || http.statusCode == 429 { throw AppFailure("GitHubのAPI制限に達しました。しばらく待ってください。") }
        guard (200...299).contains(http.statusCode) else { throw AppFailure("GitHubがHTTP \(http.statusCode)を返しました") }
        struct Asset: Decodable { var name: String; var browser_download_url: URL }
        struct Release: Decodable { var tag_name: String; var body: String?; var assets: [Asset] }
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard ReleaseVersion.isNewer(release.tag_name, than: currentVersion) else { return nil }
        guard let asset = release.assets.first(where: { $0.name.lowercased().hasSuffix(".ipa") }),
              asset.browser_download_url.scheme == "https", asset.browser_download_url.host == "github.com",
              asset.browser_download_url.path.hasPrefix("/\(repository)/releases/download/") else {
            throw AppFailure("新しいリリースにIPAが添付されていません")
        }
        return AvailableUpdate(version: release.tag_name, notes: release.body, downloadURL: asset.browser_download_url)
    }
    static func download(_ update: AvailableUpdate) async throws -> URL {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: update.downloadURL); request.timeoutInterval = 120
        let (temporary, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw AppFailure("IPAのダウンロードに失敗しました") }
        let handle = try FileHandle(forReadingFrom: temporary)
        defer { try? handle.close() }
        guard try handle.read(upToCount: 2) == Data([0x50, 0x4B]) else { throw AppFailure("取得したファイルがIPAではありません") }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("povo-update-\(UUID().uuidString).ipa")
        try FileManager.default.moveItem(at: temporary, to: destination)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: destination.path)
        return destination
    }
}
