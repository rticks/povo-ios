import SwiftUI
import PDFKit
import PovoKit

struct InvoiceDocument: Identifiable {
    let id = UUID()
    let url: URL
    let password: String?
    private static var directory: URL { FileManager.default.temporaryDirectory.appendingPathComponent("povo-invoices", isDirectory: true) }
    init(data: Data, password: String?) throws {
        guard data.starts(with: Data("%PDF".utf8)) else { throw AppFailure("取得したファイルがPDFではありません") }
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        url = Self.directory.appendingPathComponent(UUID().uuidString + ".pdf")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        self.password = password
    }
    static func cleanTemporaryFiles() {
        // Only this app's ephemeral invoice directory, never an arbitrary URL.
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "pdf" { try? FileManager.default.removeItem(at: file) }
    }
}

struct InvoiceScreen: View {
    let document: InvoiceDocument
    @Environment(\.dismiss) private var dismiss
    @State private var pdf: PDFDocument?
    @State private var password = ""
    @State private var locked = false
    @State private var failure: String?
    @State private var showPassword = false
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("請求書のパスワードは生年月日（YYYY-MM-DD）です。").font(.caption).foregroundStyle(.secondary)
                    if let registered = document.password {
                        HStack {
                            Text(showPassword ? registered : "••••-••-••").font(.subheadline.monospaced())
                            Button(showPassword ? "隠す" : "表示") { showPassword.toggle() }.font(.caption)
                            Spacer()
                            Button("コピー") {
                                UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: registered]],
                                                             options: [.localOnly: true, .expirationDate: Date(timeIntervalSinceNow: 60)])
                            }.font(.caption)
                        }
                    }
                    if locked {
                        SecureField("PDFのパスワード", text: $password).textFieldStyle(.roundedBorder)
                        Button("PDFを開く") {
                            if pdf?.unlock(withPassword: password) == true { locked = false; failure = nil }
                            else { failure = "パスワードが一致しません" }
                        }
                    }
                    if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
                }.padding()
                Divider()
                if let pdf, !locked { PDFPreview(document: pdf) }
                else { ContentUnavailableView("パスワード保護された請求書", systemImage: "lock.doc") }
            }
            .navigationTitle("請求書 PDF").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    // Shares the original encrypted PDF, not a decrypted copy.
                    ShareLink(item: document.url).accessibilityLabel("PDFを共有")
                }
            }
            .onAppear {
                pdf = PDFDocument(url: document.url)
                if let pdf, pdf.isLocked, let password = document.password { _ = pdf.unlock(withPassword: password) }
                locked = pdf?.isLocked ?? false
                if pdf == nil { failure = "PDFを読み込めませんでした" }
            }
        }
    }
}
private struct PDFPreview: UIViewRepresentable {
    let document: PDFDocument
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView(); view.autoScales = true; view.displayMode = .singlePageContinuous; view.document = document
        return view
    }
    func updateUIView(_ uiView: PDFView, context: Context) { uiView.document = document }
}
