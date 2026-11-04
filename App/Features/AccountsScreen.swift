import SwiftUI
import PovoKit

struct AccountsScreen: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var preferences: PreferencesStore
    @State private var adding = false
    @State private var path: [String] = []
    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if model.accounts.isEmpty {
                    ContentUnavailableView {
                        Label("回線を、ひとつの場所に。", systemImage: "simcard.2")
                    } description: {
                        Text("povo2.0 の複数アカウントをまとめて管理します。\nご自身のアカウントを追加してください。")
                    } actions: {
                        Button("アカウントを追加", systemImage: "plus") { adding = true }
                            .buttonStyle(.borderedProminent).accessibilityIdentifier("add-first-account")
                    }
                } else {
                    List {
                        Section {
                            HStack(alignment: .center, spacing: 14) {
                                Image(systemName: "simcard.2.fill").font(.title2).foregroundStyle(PovoStyle.brandInk)
                                    .padding(12).background(PovoStyle.brand, in: RoundedRectangle(cornerRadius: 14))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("あなたの povo").font(.headline)
                                    Text("\(model.accounts.count) 回線をまとめて管理").font(.subheadline).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if model.refreshingAll { ProgressView().accessibilityLabel("一括更新中") }
                            }.padding(.vertical, 6)
                        }
                        Section {
                            ForEach(model.accounts) { account in
                                NavigationLink(value: account.id) {
                                    AccountSummary(account: account, anchor: preferences.value.suspensionEnabled ? preferences.anchors[account.id] : nil,
                                                   refreshing: model.refreshing.contains(account.id))
                                }.accessibilityIdentifier("account-\(account.id)")
                            }
                        } header: { Text("データ残量") } footer: {
                            Text("取得時点の残量です。下に引いて更新できます。非公式クライアントのため、重要なお手続きは公式の案内もご確認ください。")
                        }
                    }
                    .refreshable { _ = await model.refreshAll() }
                }
            }
            .navigationTitle("povo マネージャー")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { Task { _ = await model.refreshAll() } } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(model.refreshingAll || model.accounts.isEmpty).accessibilityLabel("すべて更新")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("アカウントを追加")
                }
            }
            .navigationDestination(for: String.self) { id in AccountDetailScreen(accountID: id) }
            .sheet(isPresented: $adding) { LoginScreen() }
            .onChange(of: model.selectedAccountID) { _, id in
                if let id, path.last != id, model.accounts.contains(where: { $0.id == id }) { path = [id] }
            }
            .onChange(of: path) { _, path in
                if model.selectedAccountID != path.last { model.selectedAccountID = path.last }
            }
        }
    }
}

private struct AccountSummary: View {
    let account: AccountRecord
    let anchor: SuspensionAnchor?
    let refreshing: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.label).font(.headline).foregroundStyle(.primary)
                    if let email = account.profile.email, email != account.label {
                        Text(email).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if refreshing { ProgressView().controlSize(.small) }
            }
            HStack(alignment: .firstTextBaseline) {
                Text(account.usage.map { PlanUsage.formatKB($0.totalLeftKB) } ?? "未取得")
                    .font(.system(.title, design: .rounded, weight: .semibold)).foregroundStyle(.primary)
                Spacer()
                if let date = account.usageFetchedAt {
                    Text(date, style: .relative).font(.caption).foregroundStyle(.secondary)
                    Text("前の取得値").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let usage = account.usage {
                UsageMeter(fraction: usage.remainingFraction, label: "使用 \(PlanUsage.formatKB(usage.totalUsedKB))")
            }
            if account.needsLogin {
                Label("再ログインが必要です", systemImage: "person.crop.circle.badge.exclamationmark").font(.caption).foregroundStyle(.red)
            } else if let error = account.lastError {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            if let forecast = anchor?.forecast() {
                Label(forecast.overdue ? "利用停止の予定日を過ぎています" : "利用停止まで \(forecast.daysLeft) 日",
                      systemImage: "calendar.badge.exclamationmark")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 10)
    }
}

struct UsageHero: View {
    let account: AccountRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("データ残量").font(.subheadline).foregroundStyle(.secondary)
            Text(account.usage.map { PlanUsage.formatKB($0.totalLeftKB) } ?? "未取得")
                .font(.system(size: 48, weight: .semibold, design: .default)).minimumScaleFactor(0.55).lineLimit(1)
                .accessibilityIdentifier("usage-value")
            if let usage = account.usage {
                UsageMeter(fraction: usage.remainingFraction,
                           label: "使用 \(PlanUsage.formatKB(usage.totalUsedKB)) ／ 使用＋残量 \(PlanUsage.formatKB(usage.totalLeftKB + usage.totalUsedKB))")
                if let time = account.usageFetchedAt {
                    Text("\(time.formatted(date: .abbreviated, time: .shortened)) 時点")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                // Text/table twin: every reported bucket, including zeroes.
                ForEach(usage.buckets) { bucket in
                    HStack {
                        Text(bucket.kind.label).foregroundStyle(.secondary)
                        Spacer()
                        Text(PlanUsage.formatKB(bucket.leftKB)).monospacedDigit()
                    }.font(.subheadline).accessibilityElement(children: .combine)
                }
                if let promotion = [usage.promotionLine1, usage.promotionLine2].compactMap({ $0 }).joined(separator: " ").nilIfBlank {
                    Text(promotion).font(.caption).foregroundStyle(.secondary)
                }
            }
        }.padding(.vertical, 8).listRowBackground(PovoStyle.chartSurface)
    }
}
