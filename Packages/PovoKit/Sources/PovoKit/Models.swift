import Foundation

public enum BucketKind: String, CaseIterable, Codable, Sendable {
    case basic, extra, boost, bonus, plus
    public var label: String {
        switch self {
        case .basic: return "基本"
        case .extra: return "追加"
        case .boost: return "トッピング"
        case .bonus: return "ボーナス"
        case .plus: return "プラス"
        }
    }
}

public struct DataBucket: Codable, Equatable, Sendable, Identifiable {
    public var kind: BucketKind
    public var usedKB: Double
    public var leftKB: Double
    public var planKB: Double?
    public var section: String?
    public var unit: String?
    public var sectionMinValueKB: Double?
    public var id: BucketKind { kind }
    public var isEmpty: Bool { usedKB == 0 && leftKB == 0 }
    public init(kind: BucketKind, usedKB: Double, leftKB: Double, planKB: Double? = nil,
                section: String? = nil, unit: String? = nil, sectionMinValueKB: Double? = nil) {
        self.kind = kind; self.usedKB = usedKB; self.leftKB = leftKB; self.planKB = planKB
        self.section = section; self.unit = unit; self.sectionMinValueKB = sectionMinValueKB
    }
}

public struct PlanUsage: Codable, Equatable, Sendable {
    public var buckets: [DataBucket]
    public var promotionLine1: String?
    public var promotionLine2: String?
    public var totalLeftKB: Double { buckets.reduce(0) { $0 + $1.leftKB } }
    public var totalUsedKB: Double { buckets.reduce(0) { $0 + $1.usedKB } }
    public var remainingFraction: Double? {
        let total = totalLeftKB + totalUsedKB
        guard total.isFinite, total > 0 else { return nil }
        return min(1, max(0, totalLeftKB / total))
    }
    public init(buckets: [DataBucket], promotionLine1: String? = nil, promotionLine2: String? = nil) {
        self.buckets = buckets; self.promotionLine1 = promotionLine1; self.promotionLine2 = promotionLine2
    }
    public static func formatKB(_ kb: Double) -> String {
        guard kb.isFinite else { return "—" }
        if kb >= 1_048_576 { return String(format: "%.2f GB", locale: Locale(identifier: "en_US_POSIX"), kb / 1_048_576) }
        if kb >= 1024 { return String(format: "%.1f MB", locale: Locale(identifier: "en_US_POSIX"), kb / 1024) }
        return String(format: "%.0f KB", locale: Locale(identifier: "en_US_POSIX"), kb)
    }
}

public struct Money: Codable, Equatable, Sendable {
    public var value: Double
    public var prefix: String?
    public var postfix: String?
    public var discount: Double?
    public init(value: Double, prefix: String? = nil, postfix: String? = nil, discount: Double? = nil) {
        self.value = value; self.prefix = prefix; self.postfix = postfix; self.discount = discount
    }
    public var formatted: String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        let amount = formatter.string(from: NSNumber(value: value)) ?? "—"
        if let symbol = prefix?.nilIfBlank {
            return ["円", "圓", "JPY", "yen"].contains(symbol) ? amount + symbol : symbol + amount
        }
        if let suffix = postfix?.nilIfBlank, suffix != "JPY" { return amount + suffix }
        return amount + "円"
    }
}

public enum BillStatus: String, Codable, Sendable {
    case paid, unpaid, upcoming, instant, unknown
    public var label: String {
        switch self {
        case .paid: return "支払い済み"
        case .unpaid: return "未払い"
        case .upcoming: return "請求予定"
        case .instant: return "都度課金"
        case .unknown: return "状態不明"
        }
    }
}

public struct Invoice: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var billID: String?
    public var title: String?
    public var subtitle: String?
    public var status: BillStatus
    public var amount: Money?
    public var time: Date?
    public var hasPDF: Bool
    public init(id: String, billID: String? = nil, title: String? = nil, subtitle: String? = nil,
                status: BillStatus, amount: Money? = nil, time: Date? = nil, hasPDF: Bool = false) {
        self.id = id; self.billID = billID; self.title = title; self.subtitle = subtitle
        self.status = status; self.amount = amount; self.time = time; self.hasPDF = hasPDF
    }
}

public struct BillsDocument: Codable, Equatable, Sendable {
    public var past: [Invoice] = []
    public var upcoming: [Invoice] = []
    public var instantCharges: [Invoice] = []
    public var instantChargesPaid: Money?
    public var upcomingTotal: Money?
    public var all: [Invoice] {
        (upcoming + instantCharges + past).sorted {
            if $0.time == $1.time { return $0.id < $1.id }
            return ($0.time ?? .distantFuture) > ($1.time ?? .distantFuture)
        }
    }
    public init() {}
}

public struct Topping: Codable, Equatable, Sendable {
    public var section: String?
    public var name: String
    public var remaining: String?
    public var expiry: String?
    public var expiryDate: String? { expiry?.components(separatedBy: "\n").first?.nilIfBlank }
    public var expiryRemaining: String? { expiry?.components(separatedBy: "\n").dropFirst().first?.nilIfBlank }
    public init(section: String? = nil, name: String, remaining: String? = nil, expiry: String? = nil) {
        self.section = section; self.name = name; self.remaining = remaining; self.expiry = expiry
    }
}

public struct PurchasedProduct: Codable, Equatable, Sendable {
    public var name: String?
    public var price: String?
    public init(name: String? = nil, price: String? = nil) { self.name = name; self.price = price }
}

public struct Purchase: Codable, Equatable, Sendable {
    public var orderID: String?
    public var status: String?
    public var orderStatus: String?
    public var purchaseDate: String?
    public var products: [PurchasedProduct]
    public var succeeded: Bool { orderStatus?.lowercased() == "success" }
    public init(orderID: String? = nil, status: String? = nil, orderStatus: String? = nil,
                purchaseDate: String? = nil, products: [PurchasedProduct] = []) {
        self.orderID = orderID; self.status = status; self.orderStatus = orderStatus
        self.purchaseDate = purchaseDate; self.products = products
    }
}

public enum WebPageKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case email, payment, contract
    public var id: Self { self }
    public var path: String {
        switch self {
        case .email: return "/profile/email"
        case .payment: return "/manage/payment-details"
        case .contract: return "/manage/order"
        }
    }
    public var label: String {
        switch self {
        case .email: return "メールアドレスの変更"
        case .payment: return "お支払い方法"
        case .contract: return "契約管理"
        }
    }
    public var symbol: String {
        switch self {
        case .email: return "envelope"
        case .payment: return "creditcard"
        case .contract: return "doc.text"
        }
    }
    public static func matching(_ link: String) -> Self? {
        guard let url = URL(string: link), url.host != nil else { return nil }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return allCases.first { $0.path.dropFirst() == path }
    }
}

public struct PovoWebPage: Codable, Equatable, Sendable, Identifiable {
    public var kind: WebPageKind
    public var link: String
    public var exitURL: String?
    public var needsXAuth: Bool
    public var id: WebPageKind { kind }
    public init(kind: WebPageKind, link: String, exitURL: String? = nil, needsXAuth: Bool = false) {
        self.kind = kind; self.link = link; self.exitURL = exitURL; self.needsXAuth = needsXAuth
    }
}

public struct ProfileInfo: Codable, Equatable, Sendable {
    public var paymentMasked: String?
    public var webPages: [PovoWebPage]
    public init(paymentMasked: String? = nil, webPages: [PovoWebPage] = []) {
        self.paymentMasked = paymentMasked; self.webPages = webPages
    }
}

public struct ToppingProduct: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var validity: String?
    public var price: String?
    public var requires3DS: Bool
    public init(id: String, name: String, validity: String? = nil, price: String? = nil, requires3DS: Bool = false) {
        self.id = id; self.name = name; self.validity = validity; self.price = price; self.requires3DS = requires3DS
    }
}

public struct ToppingSection: Codable, Equatable, Sendable {
    public var title: String?
    public var products: [ToppingProduct]
    public init(title: String? = nil, products: [ToppingProduct]) { self.title = title; self.products = products }
}

public struct ToppingOrder: Codable, Equatable, Sendable {
    public var challengeURL: String?
    public var orderRef: String?
    public var paymentRef: String?
    public var needsChallenge: Bool { challengeURL?.nilIfBlank != nil }
    public init(challengeURL: String? = nil, orderRef: String? = nil, paymentRef: String? = nil) {
        self.challengeURL = challengeURL; self.orderRef = orderRef; self.paymentRef = paymentRef
    }
}

public extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
