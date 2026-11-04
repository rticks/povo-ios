import SwiftUI
import PovoKit

struct SuspensionEditor: View {
    let accountID: String
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var preferences: PreferencesStore
    @Environment(\.dismiss) private var dismiss
    @State private var purchase = Date()
    @State private var expiry = Date()
    @State private var duration = ""
    @State private var useDate = false
    @State private var deleting = false
    private var purchaseDay: CalendarDay { CalendarDay(date: purchase) }
    private var expiryText: String? {
        if useDate { return CalendarDay(date: expiry).description }
        return Int(duration).flatMap { Suspension.expiry(purchasedOn: purchaseDay.description, durationDays: $0) }
    }
    private var forecast: SuspensionForecast? { expiryText.flatMap { Suspension.forecast(expiry: $0) } }
    private var valid: Bool { forecast.map { $0.expiry >= purchaseDay } ?? false }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("最後に購入した有料トッピングを入力してください。APIは期限切れのトッピングを返さないため、自動推定しません。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    DatePicker("最終購入日", selection: $purchase, displayedComponents: .date)
                    Picker("有効期間の入力", selection: $useDate) {
                        Text("日数で").tag(false); Text("日付で").tag(true)
                    }.pickerStyle(.segmented)
                    if useDate { DatePicker("有効期限", selection: $expiry, displayedComponents: .date) }
                    else {
                        TextField("有効期間（日間）例：365", text: $duration).keyboardType(.numberPad)
                            .accessibilityIdentifier("suspension-duration")
                        Text("1〜3650日。商品名に書かれた有効期間を入力します。購入日＋日数が有効期限です。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("保存する内容の確認") {
                    if let forecast, valid {
                        LabeledContent("有効期限", value: forecast.expiry.description)
                        LabeledContent("停止予定日", value: forecast.suspendsOn.description)
                        LabeledContent("残り日数", value: "\(forecast.daysLeft) 日")
                    } else { Text("有効な期間を入力してください。有効期限は購入日以降の日付が必要です。").font(.subheadline).foregroundStyle(.secondary) }
                }
                Section {
                    Text("有料トッピングの有効期限の翌日から180日間、その翌日以降が順次停止の目安です。通話・SMSの660円超の例外は計算しません。停止後30日で契約解除の可能性があります。正式な期限はpovoの案内を確認してください。")
                        .font(.caption).foregroundStyle(.secondary)
                    if preferences.anchors[accountID] != nil {
                        Button("起算日を削除", role: .destructive) { deleting = true }
                    }
                }
            }
            .navigationTitle("利用停止の起算日").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("やめる") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        guard valid, let expiryText else { return }
                        model.setAnchor(SuspensionAnchor(purchaseDate: purchaseDay.description,
                                                         durationDays: useDate ? nil : Int(duration), expiryDate: expiryText), for: accountID)
                        dismiss()
                    }.disabled(!valid).accessibilityIdentifier("save-suspension")
                }
            }
            .onAppear {
                if let existing = preferences.anchors[accountID] {
                    purchase = CalendarDay(existing.purchaseDate)?.localDate() ?? Date()
                    expiry = CalendarDay(existing.expiryDate)?.localDate() ?? Date()
                    duration = existing.durationDays.map(String.init) ?? ""
                    useDate = existing.durationDays == nil
                }
            }
            .confirmationDialog("手入力した起算日を削除しますか？", isPresented: $deleting, titleVisibility: .visible) {
                Button("削除", role: .destructive) { model.setAnchor(nil, for: accountID); dismiss() }
            }
        }
    }
}
