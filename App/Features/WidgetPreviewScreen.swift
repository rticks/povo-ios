import SwiftUI
import PovoKit

struct WidgetPreviewScreen: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedID = ""
    private var selected: AccountRecord? { model.accounts.first { $0.id == selectedID } ?? model.accounts.first }
    var body: some View {
        List {
            Section("表示する回線") {
                Picker("アカウント", selection: $selectedID) {
                    ForEach(model.accounts) { Text($0.label).tag($0.id) }
                }
            }
            Section("円形メーターの表示例") {
                if let account = selected {
                    VStack(spacing: 12) {
                        Text(account.label).font(.headline)
                        RemainingRing(fraction: account.usage?.remainingFraction,
                                      remaining: account.usage.map { PlanUsage.formatKB($0.totalLeftKB) } ?? "未取得",
                                      total: account.usage.map { PlanUsage.formatKB($0.totalUsedKB + $0.totalLeftKB) } ?? "未取得")
                            .frame(width: 180, height: 180)
                        if let date = account.usageFetchedAt { Text(date.formatted(date: .abbreviated, time: .shortened) + " 時点").font(.caption).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity).padding(.vertical, 10)
                } else { Text("アカウント未登録").foregroundStyle(.secondary) }
            }.listRowBackground(PovoStyle.chartSurface)
            Section("一覧の表示例") {
                ForEach(model.accounts) { account in
                    HStack { Text(account.label).font(.subheadline); Spacer(); Text(account.usage.map { PlanUsage.formatKB($0.totalLeftKB) } ?? "未取得").monospacedDigit() }
                }
            }
            Section { Text("実際のウィジェットはホーム画面を長押しして追加します。円形メーターの回線選択は「ウィジェットを編集」から行ってください。表示はアプリの最後の取得値で、ウィジェット自身はAPIにアクセスしません。")
                    .font(.caption).foregroundStyle(.secondary) }
        }
        .navigationTitle("ウィジェットのプレビュー").navigationBarTitleDisplayMode(.inline)
        .onAppear { selectedID = model.accounts.first?.id ?? "" }
    }
}
