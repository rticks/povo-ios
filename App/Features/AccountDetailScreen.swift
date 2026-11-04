import SwiftUI
import PovoKit

struct AccountDetailScreen: View {
    let accountID: String
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var preferences: PreferencesStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    @State private var reauth = false
    @State private var editingAnchor = false
    @State private var web: WebSessionContext?
    @State private var invoice: InvoiceDocument?
    @State private var opening = false
    private var account: AccountRecord? { model.accounts.first { $0.id == accountID } }
    var body: some View {
        Group {
            if let account {
                List {
                    Section { UsageHero(account: account) }
                    if let error = account.lastError {
                        Section {
                            Label(error, systemImage: "exclamationmark.triangle").font(.subheadline)
                            if account.needsLogin { Button("再ログイン") { reauth = true }.accessibilityIdentifier("reauthenticate") }
                        }
                    }
                    Section {
                        NavigationLink { ToppingStoreScreen(accountID: accountID) } label: {
                            Label("トッピングを購入", systemImage: "cart.badge.plus")
                        }.accessibilityIdentifier("open-topping-store")
                    }
                    Section("契約中のトッピング") {
                        if account.toppings.isEmpty { Text("取得済みのトッピングはありません").foregroundStyle(.secondary) }
                        ForEach(Array(account.toppings.enumerated()), id: \.offset) { _, topping in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(topping.name).font(.headline)
                                if let remaining = topping.remaining { Text("残量 \(remaining)").font(.subheadline) }
                                if let expiry = topping.expiry { Text(expiry).font(.caption).foregroundStyle(.secondary) }
                            }.padding(.vertical, 5)
                        }
                    }
                    Section("契約情報") {
                        info("名義", account.profile.name)
                        info("電話番号", account.profile.phone)
                        info("メール", account.profile.email)
                        info("プラン", account.profile.planName)
                        info("状態", account.profile.status)
                        info("開通日", account.profile.activationDate)
                        info("お支払い方法", account.profileInfo?.paymentMasked)
                        info("回線番号 (SIN)", account.profile.sin)
                    }
                    if preferences.value.suspensionEnabled {
                        Section {
                            Button { editingAnchor = true } label: {
                                SuspensionSummary(anchor: preferences.anchors[accountID])
                            }.buttonStyle(.plain).accessibilityIdentifier("edit-suspension")
                        } header: { Text("180日ルール") } footer: {
                            Text("停止日は手入力した有効期限に基づく目安です。期間内の従量通話料とSMS送信料の合計が税込660円を超える場合の適用除外は判定していません。povoからの通知を優先してください。")
                        }
                    }
                    if let pages = account.profileInfo?.webPages, !pages.isEmpty {
                        Section("povo の公式ページ") {
                            ForEach(pages) { page in
                                Button { Task { await openWeb(page) } } label: { Label(page.kind.label, systemImage: page.kind.symbol) }
                                    .disabled(opening)
                            }
                        }
                    }
                    Section("請求タイムライン") {
                        if let bills = account.bills, !bills.all.isEmpty {
                            ForEach(bills.all) { bill in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(bill.title ?? "請求").font(.subheadline.weight(.medium))
                                        Spacer()
                                        if let amount = bill.amount { Text(amount.formatted).font(.subheadline.weight(.semibold)).monospacedDigit() }
                                    }
                                    Text(bill.status.label).font(.caption).foregroundStyle(.secondary)
                                    if let subtitle = bill.subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                                    if let date = bill.time { Text(date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary) }
                                    if bill.hasPDF, let id = bill.billID {
                                        Button("請求書 PDF を開く", systemImage: "doc.richtext") { Task { await openPDF(id) } }.disabled(opening)
                                    }
                                }.padding(.vertical, 5)
                            }
                        } else { Text("取得済みの請求はありません").foregroundStyle(.secondary) }
                    }
                    Section("購入履歴") {
                        if account.purchases.isEmpty { Text("取得済みの購入履歴はありません").foregroundStyle(.secondary) }
                        ForEach(Array(account.purchases.enumerated()), id: \.offset) { _, purchase in
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(purchase.products.enumerated()), id: \.offset) { _, product in
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(product.name ?? "商品名不明"); Spacer()
                                        if let price = product.price { Text(price).monospacedDigit() }
                                    }.font(.subheadline)
                                }
                                Text([purchase.status, purchase.purchaseDate].compactMap { $0 }.joined(separator: " ・ "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 5)
                        }
                    }
                    Section {
                        Button("このアプリからアカウントを削除", role: .destructive) { confirmDelete = true }
                    } footer: { Text("削除しても povo 側の契約は解約されません。") }
                }
                .refreshable { await model.refresh(accountID) }
            } else { ContentUnavailableView("アカウントがありません", systemImage: "simcard") }
        }
        .navigationTitle(account?.label ?? "回線の詳細").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if model.refreshing.contains(accountID) || opening { ProgressView() }
                else { Button { Task { await model.refresh(accountID) } } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("この回線を更新") }
            }
        }
        .confirmationDialog("このアプリからアカウントを削除しますか？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("アカウントと起算日を削除", role: .destructive) {
                Task {
                    do { try await model.remove(accountID); dismiss() }
                    catch { model.message = AppFailure.describing(error).message }
                }
            }
        } message: { Text("認証情報、キャッシュ、手入力した起算日を削除します。povo 側の契約には影響しません。") }
        .sheet(isPresented: $reauth) { LoginScreen(replacing: accountID) }
        .sheet(isPresented: $editingAnchor) { SuspensionEditor(accountID: accountID) }
        .sheet(item: $web) { context in
            PovoWebScreen(context: context, repository: model.repository) {
                web = nil; Task { await model.refresh(accountID) }
            }
        }
        .sheet(item: $invoice, onDismiss: { InvoiceDocument.cleanTemporaryFiles() }) { document in InvoiceScreen(document: document) }
    }
    @ViewBuilder private func info(_ label: String, _ value: String?) -> some View {
        if let value = value?.nilIfBlank { LabeledContent(label) { Text(value).textSelection(.enabled).multilineTextAlignment(.trailing) } }
    }
    private func openWeb(_ page: PovoWebPage) async {
        opening = true; defer { opening = false }
        do {
            if page.needsXAuth {
                let session = try await model.repository.webSession(accountID)
                web = WebSessionContext(accountID: accountID, page: page, token: session.token, deviceID: session.deviceID, generation: session.generation)
            } else {
                web = WebSessionContext(accountID: accountID, page: page, token: nil, deviceID: nil, generation: nil)
            }
        } catch { model.message = AppFailure.describing(error).message; await model.reload() }
    }
    private func openPDF(_ billID: String) async {
        opening = true; defer { opening = false }
        do {
            let data = try await model.repository.pdf(accountID, billID: billID)
            invoice = try InvoiceDocument(data: data, password: account?.profile.birthDate)
        } catch { model.message = AppFailure.describing(error).message; await model.reload() }
    }
}

struct SuspensionSummary: View {
    let anchor: SuspensionAnchor?
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("利用停止まで", systemImage: "calendar.badge.exclamationmark").font(.subheadline).foregroundStyle(.secondary)
            if let forecast = anchor?.forecast() {
                Text(forecast.overdue ? "予定日を過ぎています（\(-forecast.daysLeft)日）" : "残り \(forecast.daysLeft) 日")
                    .font(.title2.weight(.semibold))
                Text("\(forecast.suspendsOn) 以降、順次利用停止").font(.subheadline)
                Text("有効期限 \(forecast.expiry) ／ 契約解除の目安 \(forecast.terminatesOn)").font(.caption).foregroundStyle(.secondary)
                Text("起算日を編集").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("起算日は未設定です").font(.headline)
                Text("最後の有料トッピングの購入日と有効期間を登録").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading)
    }
}
