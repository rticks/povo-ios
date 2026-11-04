import SwiftUI
import WidgetKit
import AppIntents
import PovoKit

struct PovoAccountEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "povo アカウント"
    static var defaultQuery = PovoAccountQuery()
    var id: String
    var label: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(label)") }
}
struct PovoAccountQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [PovoAccountEntity] {
        WidgetStorage.read().accounts.filter { identifiers.contains($0.id) }.map { PovoAccountEntity(id: $0.id, label: $0.label) }
    }
    func suggestedEntities() async throws -> [PovoAccountEntity] {
        WidgetStorage.read().accounts.map { PovoAccountEntity(id: $0.id, label: $0.label) }
    }
    func defaultResult() async -> PovoAccountEntity? {
        let accounts = WidgetStorage.read().accounts
        guard accounts.count == 1, let account = accounts.first else { return nil }
        return PovoAccountEntity(id: account.id, label: account.label)
    }
}
struct SelectPovoAccount: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "表示する回線"
    static var description = IntentDescription("円形メーターに表示するpovoアカウントを選びます。")
    @Parameter(title: "アカウント") var account: PovoAccountEntity?
}
struct UsageEntry: TimelineEntry {
    var date: Date
    var snapshot: WidgetSnapshot
    var selected: WidgetAccount?
    static var placeholder: UsageEntry {
        var record = AccountRecord(id: "example", profile: AccountProfile(phone: "090-0000-0000"))
        record.usage = PlanUsage(buckets: [DataBucket(kind: .boost, usedKB: 40 * 1_048_576, leftKB: 80 * 1_048_576)])
        record.usageFetchedAt = Date()
        let account = WidgetAccount(record: record)
        return UsageEntry(date: Date(), snapshot: WidgetSnapshot(accounts: [account]), selected: account)
    }
}
struct ListProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry { .placeholder }
    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        completion(context.isPreview ? .placeholder : entry())
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        completion(Timeline(entries: [entry()], policy: .after(Date(timeIntervalSinceNow: 30 * 60))))
    }
    private func entry() -> UsageEntry { UsageEntry(date: Date(), snapshot: WidgetStorage.read(), selected: nil) }
}
struct RingProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> UsageEntry { .placeholder }
    func snapshot(for configuration: SelectPovoAccount, in context: Context) async -> UsageEntry { context.isPreview ? .placeholder : entry(configuration) }
    func timeline(for configuration: SelectPovoAccount, in context: Context) async -> Timeline<UsageEntry> {
        Timeline(entries: [entry(configuration)], policy: .after(Date(timeIntervalSinceNow: 30 * 60)))
    }
    private func entry(_ configuration: SelectPovoAccount) -> UsageEntry {
        let snapshot = WidgetStorage.read()
        let selected: WidgetAccount?
        if let id = configuration.account?.id { selected = snapshot.accounts.first { $0.id == id } }
        else { selected = snapshot.accounts.count == 1 ? snapshot.accounts.first : nil }
        return UsageEntry(date: Date(), snapshot: snapshot, selected: selected)
    }
}

private struct ListWidgetView: View {
    let entry: UsageEntry
    @Environment(\.widgetFamily) private var family
    private var limit: Int { family == .systemLarge ? 7 : family == .systemMedium ? 3 : 2 }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("povo データ残量", systemImage: "simcard.2").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if entry.snapshot.accounts.isEmpty {
                Text("アプリでアカウントを追加し、ウィジェット共有を有効にしてください").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(entry.snapshot.accounts.prefix(limit)) { account in
                Link(destination: WidgetStorage.deepLink(accountID: account.id)) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.label).font(.caption).lineLimit(1).foregroundStyle(.primary)
                            if let time = account.fetchedAt {
                                Text(time, format: .dateTime.month().day().hour().minute()).font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 4)
                        if account.needsLogin { Image(systemName: "exclamationmark.triangle").accessibilityLabel("再ログインが必要") }
                        Text(account.remaining).font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(.primary)
                    }
                }
            }
            if entry.snapshot.accounts.count > limit { Text("ほか \(entry.snapshot.accounts.count - limit) 回線").font(.caption2).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
        }.privacySensitive().widgetURL(WidgetStorage.deepLink())
            .containerBackground(PovoStyle.chartSurface, for: .widget)
    }
}
private struct RingWidgetView: View {
    let entry: UsageEntry
    @Environment(\.widgetFamily) private var family
    var body: some View {
        Group {
            if let account = entry.selected {
                VStack(spacing: 4) {
                    Text(account.label).font(.caption.weight(.medium)).lineLimit(1).minimumScaleFactor(0.7)
                    RemainingRing(fraction: account.fraction, remaining: account.remaining,
                                  total: account.leftKB.flatMap { left in account.usedKB.map { PlanUsage.formatKB(left + $0) } } ?? "未取得")
                    if let date = account.fetchedAt {
                        Text("\(date.formatted(.dateTime.month().day().hour().minute())) 時点").font(.system(size: 9)).foregroundStyle(.secondary)
                    } else { Text("未取得").font(.caption2).foregroundStyle(.secondary) }
                    if account.needsLogin { Text("再ログインが必要").font(.caption2).foregroundStyle(.secondary) }
                }.widgetURL(WidgetStorage.deepLink(accountID: account.id))
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "simcard").font(.title2)
                    Text("回線を選択").font(.headline)
                    Text("長押し → ウィジェットを編集").font(.caption).multilineTextAlignment(.center).foregroundStyle(.secondary)
                }.widgetURL(WidgetStorage.deepLink())
            }
        }.privacySensitive().containerBackground(PovoStyle.chartSurface, for: .widget)
    }
}

struct PovoListWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PovoUsageList", provider: ListProvider()) { ListWidgetView(entry: $0) }
            .configurationDisplayName("povo 残量一覧").description("複数回線のデータ残量と取得日時を並べて表示します。")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
struct PovoRingWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "PovoUsageRing", intent: SelectPovoAccount.self, provider: RingProvider()) { RingWidgetView(entry: $0) }
            .configurationDisplayName("povo 残量メーター").description("選択した1回線の残量を円形メーターで表示します。")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}
@main
struct PovoWidgets: WidgetBundle {
    var body: some Widget { PovoListWidget(); PovoRingWidget() }
}
