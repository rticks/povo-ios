import Foundation
import CoreFoundation

// The wire format is server-driven, not a stable Codable schema. Unknown tiles
// are ignored, but a missing document is never reported as a zero reading.
private typealias Object = [String: Any]
private enum J {
    static func parse(_ raw: String) -> Object? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? Object
    }
    static func object(_ parent: Object?, _ keys: String...) -> Object? {
        keys.lazy.compactMap { parent?[$0] as? Object }.first
    }
    static func array(_ parent: Object?, _ keys: String...) -> [Any]? {
        keys.lazy.compactMap { parent?[$0] as? [Any] }.first
    }
    static func text(_ parent: Object?, _ keys: String...) -> String? {
        keys.lazy.compactMap { (parent?[$0] as? String)?.nilIfBlank }.first
    }
    static func number(_ parent: Object?, _ keys: String...) -> Double? {
        for key in keys {
            if let n = parent?[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite {
                return n.doubleValue
            }
            if let text = parent?[key] as? String, let n = Double(text), n.isFinite { return n }
        }
        return nil
    }
    static func bool(_ parent: Object?, _ keys: String...) -> Bool? {
        for key in keys {
            if let n = parent?[key] as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
            if let s = parent?[key] as? String {
                if s == "true" { return true }; if s == "false" { return false }
            }
        }
        return nil
    }
    static func unwrap(_ root: Object?, stoppingAt keys: [String]) -> Object? {
        guard var current = root else { return nil }
        for _ in 0..<4 {
            if keys.contains(where: { current[$0] != nil }) { break }
            guard let next = object(current, "result", "data") else { break }
            current = next
        }
        return current
    }
    static func money(_ parent: Object?, _ keys: String...) -> Money? {
        guard let node = keys.lazy.compactMap({ parent?[$0] as? Object }).first,
              let value = number(node, "value", "amount") else { return nil }
        return Money(value: value, prefix: text(node, "prefix"), postfix: text(node, "postfix"), discount: number(node, "discount"))
    }
    static func date(_ parent: Object?, _ keys: String...) -> Date? {
        guard let value = keys.lazy.compactMap({ number(parent, $0) }).first else { return nil }
        return Date(timeIntervalSince1970: value > 100_000_000_000 ? value / 1000 : value)
    }
}

public enum UsageParser {
    public static func parse(_ raw: String) -> PlanUsage? {
        guard let root = J.unwrap(J.parse(raw), stoppingAt: BucketKind.allCases.map(\.rawValue)) else { return nil }
        let buckets = BucketKind.allCases.compactMap { kind -> DataBucket? in
            guard let node = root[kind.rawValue] as? Object else { return nil }
            return DataBucket(kind: kind, usedKB: J.number(node, "used", "used_kb") ?? 0,
                              leftKB: J.number(node, "left", "remaining") ?? 0, planKB: J.number(node, "plan_kb"),
                              section: J.text(node, "section"), unit: J.text(node, "unit", "unit_type"),
                              sectionMinValueKB: J.number(node, "section_min_value"))
        }
        guard !buckets.isEmpty else { return nil }
        let promotion = J.object(root, "promotion_text")
        return PlanUsage(buckets: buckets, promotionLine1: J.text(promotion, "line1"), promotionLine2: J.text(promotion, "line2"))
    }
}

public enum BillsParser {
    public static func parse(_ raw: String) -> BillsDocument? {
        guard let root = J.unwrap(J.parse(raw), stoppingAt: ["past_bills", "upcoming_bill", "instant_charges"]),
              ["past_bills", "upcoming_bill", "instant_charges"].contains(where: { root[$0] is Object }) else { return nil }
        var doc = BillsDocument()
        func entries(_ section: String, status: BillStatus) -> [Invoice] {
            (J.array(J.object(root, section), "list") ?? []).enumerated().compactMap { index, element in
                guard let node = element as? Object else { return nil }
                let actual: BillStatus
                if status == .unknown {
                    actual = J.text(node, "type").map { $0.uppercased() == "PAID" ? .paid : .unpaid } ?? .unknown
                } else { actual = status }
                let pdf = (J.array(node, "actions") ?? []).contains { J.text($0 as? Object, "type") == "pdf" }
                let billID = status == .upcoming ? nil : J.text(node, "billId", "bill_id", "id")
                // Position is part of identity: redacted fixtures (and some
                // server documents) repeat a bill id in multiple rows.
                return Invoice(id: "\(section)-\(index)-\(billID ?? "entry")", billID: billID,
                               title: status == .upcoming ? J.text(node, "label", "title") : J.text(node, "title", "label", "name"),
                               subtitle: J.text(node, "subtitle", "subtitleSuffix", "subtitle_suffix", "description"), status: actual,
                               amount: status == .instant ? J.money(node, "price", "paid", "amount", "total") : J.money(node, "total", "amount", "price"),
                               time: J.date(node, "time", "date", "created_at"), hasPDF: pdf && billID != nil && status != .upcoming)
            }
        }
        doc.past = entries("past_bills", status: .unknown)
        doc.upcoming = entries("upcoming_bill", status: .upcoming)
        doc.instantCharges = entries("instant_charges", status: .instant)
        doc.instantChargesPaid = J.money(J.object(root, "instant_charges"), "paid")
        doc.upcomingTotal = J.money(J.object(root, "upcoming_bill"), "total")
        return doc
    }
}

public enum QuiltParser {
    private static func components(_ raw: String) -> [Object]? {
        guard let root = J.unwrap(J.parse(raw), stoppingAt: ["widgets", "pageWidgets"]),
              let widgets = J.array(root, "widgets", "pageWidgets") else { return nil }
        return widgets.compactMap { $0 as? Object }.flatMap {
            (J.array($0, "components", "items") ?? []).compactMap { $0 as? Object }
        }
    }
    public static func toppings(_ raw: String) -> [Topping]? {
        guard let components = components(raw) else { return nil }
        var section: String?
        var result: [Topping] = []
        for component in components {
            guard let type = J.text(component, "type") else { continue }
            let data = J.object(component, "data") ?? component
            if type.hasSuffix("plan-header") { section = J.text(data, "title") }
            if type.hasSuffix("plan-detail"), let name = J.text(J.object(data, "name"), "title") ?? J.text(data, "title") {
                result.append(Topping(section: section, name: name, remaining: J.text(J.object(data, "remaining"), "value"),
                                      expiry: J.text(J.object(data, "expiry"), "value")))
            }
        }
        return result
    }
    public static func purchases(_ raw: String) -> [Purchase]? {
        components(raw)?.compactMap { component in
            guard J.text(component, "type")?.contains("status-card") == true else { return nil }
            let data = J.object(component, "data") ?? component
            let products = (J.array(data, "products") ?? []).compactMap { $0 as? Object }.map {
                PurchasedProduct(name: J.text($0, "product_name", "name", "title"), price: J.text($0, "price"))
            }
            return Purchase(orderID: J.text(data, "order_id", "orderId"), status: J.text(data, "status"),
                            orderStatus: J.text(data, "order_status", "orderStatus"),
                            purchaseDate: J.text(data, "purchase_date", "order_date", "date"), products: products)
        }
    }
    public static func profile(_ raw: String) -> ProfileInfo? {
        guard let components = components(raw) else { return nil }
        let card = components.first { J.text($0, "type") == "tile-credit-card" }
        let masked = J.text(J.object(card, "data") ?? card, "description")
        var pages: [PovoWebPage] = []
        for component in components {
            guard let action = J.object(component, "action"), J.text(action, "type") == "web_view",
                  let web = J.object(J.object(action, "data"), "web_view", "webView"),
                  let link = J.text(web, "link", "url"), let kind = WebPageKind.matching(link),
                  !pages.contains(where: { $0.kind == kind }) else { continue }
            pages.append(PovoWebPage(kind: kind, link: link, exitURL: J.text(web, "exit_url", "exitUrl"),
                                     needsXAuth: J.bool(web, "needs_xauth", "needsXauth") ?? false))
        }
        return ProfileInfo(paymentMasked: masked, webPages: pages)
    }
    public static func catalogue(_ raw: String) -> [ToppingSection]? {
        components(raw)?.compactMap { component in
            guard J.text(component, "type") == "addon-section", let data = J.object(component, "data") else { return nil }
            let products: [ToppingProduct] = (J.array(data, "items") ?? []).compactMap { element in
                guard let item = element as? Object else { return nil }
                let tile = J.object(item, "data")
                let popup = J.object(J.object(J.object(item, "action"), "data"), "product_popup", "productPopup")
                guard let id = J.text(popup, "id") ?? J.text(tile, "id"),
                      let name = J.text(popup, "title") ?? J.text(J.object(tile, "name"), "title") else { return nil }
                return ToppingProduct(id: id, name: name, validity: J.text(J.object(tile, "validity"), "title"),
                                      price: J.text(popup, "price") ?? J.text(J.object(tile, "price"), "title"),
                                      requires3DS: J.bool(popup, "is_3ds_topping", "is3dsTopping") ?? false)
            }
            guard !products.isEmpty else { return nil }
            return ToppingSection(title: J.text(J.object(data, "sectionHeader"), "title"), products: products)
        }
    }
    public static func order(_ raw: String) -> ToppingOrder? {
        guard let root = J.parse(raw), J.bool(root, "success") != false else { return nil }
        let result = J.object(root, "result") ?? root
        let challenge = J.text(result, "challenge_url", "challengeUrl")
        let ref = J.text(result, "order_ref", "orderRef", "order_id", "orderId")
        // An arbitrary valid JSON object is NOT proof of a completed purchase.
        guard challenge != nil || ref != nil else { return nil }
        return ToppingOrder(challengeURL: challenge, orderRef: ref, paymentRef: J.text(result, "p_ref", "pRef"))
    }
}
