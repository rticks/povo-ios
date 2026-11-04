import XCTest
@testable import PovoKit

final class ParserTests: XCTestCase {
    func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }
    func testAllFiveBucketsOnZeroAccount() throws {
        let usage = try XCTUnwrap(UsageParser.parse(fixture("account-usage-plan-get")))
        XCTAssertEqual(usage.buckets.count, 5)
        XCTAssertEqual(usage.totalLeftKB, 0)
        XCTAssertNil(usage.remainingFraction)
        XCTAssertNil(usage.buckets.first { $0.kind == .boost }?.planKB)
        XCTAssertEqual(usage.buckets.first { $0.kind == .basic }?.planKB, 0)
    }
    func testFractionalKilobytesAndBinaryUnits() throws {
        let usage = try XCTUnwrap(UsageParser.parse(fixture("account-usage-plan-get.plan-account")))
        XCTAssertEqual(usage.totalLeftKB, 62_914_560.37109375, accuracy: 0.000001)
        XCTAssertEqual(usage.totalUsedKB, 62_914_560.62890625, accuracy: 0.000001)
        XCTAssertEqual(PlanUsage.formatKB(usage.totalLeftKB), "60.00 GB")
        XCTAssertEqual(PlanUsage.formatKB(1024), "1.0 MB")
        XCTAssertEqual(PlanUsage.formatKB(12), "12 KB")
    }
    func testUsageEnvelopesAndMalformedPayloads() {
        let raw = #"{"result":{"data":{"boost":{"left":"1024.5","used":1}}}}"#
        XCTAssertEqual(UsageParser.parse(raw)?.totalLeftKB, 1024.5)
        for raw in ["", "oops", "[]", #"{"unexpected":true}"#] { XCTAssertNil(UsageParser.parse(raw)) }
        XCTAssertEqual(UsageParser.parse(#"{"basic":{"left":true}}"#)?.totalLeftKB, 0)
    }
    func testBillingFixtureAndUniqueRowIdentity() throws {
        let bills = try XCTUnwrap(BillsParser.parse(fixture("layout-bills-info")))
        XCTAssertEqual(bills.past.count, 6)
        XCTAssertEqual(bills.upcoming.count, 3)
        XCTAssertEqual(Set(bills.all.map(\.id)).count, bills.all.count)
        let first = try XCTUnwrap(bills.past.first)
        XCTAssertEqual(first.billID, "REG0000000000000")
        XCTAssertEqual(first.status, .paid)
        XCTAssertEqual(first.amount?.formatted, "180円")
        XCTAssertEqual(first.time?.timeIntervalSince1970, 1_785_509_999)
        XCTAssertTrue(first.hasPDF)
        XCTAssertTrue(bills.upcoming.allSatisfy { $0.billID == nil && !$0.hasPDF && $0.status == .upcoming })
        XCTAssertTrue(bills.instantCharges.isEmpty)
        XCTAssertEqual(bills.instantChargesPaid?.value, 0)
    }
    func testSecondBillingFixtureAndNewestFirst() throws {
        let bills = try XCTUnwrap(BillsParser.parse(fixture("layout-bills-info.plan-account")))
        XCTAssertFalse(bills.all.isEmpty)
        let dates = bills.all.compactMap(\.time)
        XCTAssertEqual(dates, dates.sorted(by: >))
    }
    func testBillingUnknownPreservesCacheButEmptyIsReal() {
        XCTAssertNil(BillsParser.parse(#"{"unexpected":true}"#))
        XCTAssertNil(BillsParser.parse("bad"))
        XCTAssertNotNil(BillsParser.parse(#"{"past_bills":{"list":[]}}"#))
        let bills = BillsParser.parse(#"{"result":{"past_bills":{"list":[{"type":"UNPAID","time":1700000000,"total":{"value":"1234.5","prefix":"¥"}}]}}}"#)
        XCTAssertEqual(bills?.past.first?.status, .unpaid)
        XCTAssertEqual(bills?.past.first?.time?.timeIntervalSince1970, 1_700_000_000)
        XCTAssertEqual(bills?.past.first?.amount?.formatted, "¥1,234.5")
    }
    func testMoneyDecorationAndGrouping() {
        XCTAssertEqual(Money(value: 21100, prefix: "円", postfix: "JPY").formatted, "21,100円")
        XCTAssertEqual(Money(value: 100, prefix: "¥").formatted, "¥100")
        XCTAssertEqual(Money(value: 100, postfix: "JPY").formatted, "100円")
        XCTAssertEqual(Money(value: 100, prefix: "yen").formatted, "100yen")
    }
    func testSubscribedToppingsKeepDisplayStrings() throws {
        let toppings = try XCTUnwrap(QuiltParser.toppings(fixture("quilt-user-plan-details-v2")))
        XCTAssertEqual(toppings.count, 1)
        XCTAssertEqual(toppings[0].remaining, "60.00GB / 120.00GB")
        XCTAssertEqual(toppings[0].section, "データ")
        XCTAssertEqual(toppings[0].expiryRemaining, "残り 999 日間")
    }
    func testPurchaseHistoryKeepsEveryProduct() throws {
        let purchases = try XCTUnwrap(QuiltParser.purchases(fixture("quilt-order-history")))
        XCTAssertEqual(purchases.count, 1)
        XCTAssertTrue(purchases[0].succeeded)
        XCTAssertEqual(purchases[0].products[0].price, "12,345円")
    }
    func testMalformedQuiltIsNotAnEmptyDocument() {
        XCTAssertNil(QuiltParser.toppings("bad"))
        XCTAssertNil(QuiltParser.purchases(#"{"unexpected":true}"#))
        XCTAssertEqual(QuiltParser.toppings(#"{"widgets":[]}"#), [])
    }
    func testCataloguePopupAndBlankFallback() throws {
        let raw = #"""
        {"widgets":[{"components":[{"type":"addon-section","data":{"sectionHeader":{"title":"データ"},"items":[
          {"data":{"id":"tile","name":{"title":"短い名前"},"price":{"title":"100円"}},"action":{"data":{"product_popup":{"id":"sku","title":"長い名前","price":"27,500円 -> 25,100円","is_3ds_topping":true}}}},
          {"data":{"id":"fallback","name":{"title":"使い放題"},"validity":{"title":"2時間 40回分"},"price":{"title":"3,600円*"}},"action":{"data":{"product_popup":{"title":"","price":""}}}}
        ]}},{"type":"addon-section","data":{"items":[{"data":{"title":"免責"}}]}}]}]}
        """#
        let sections = try XCTUnwrap(QuiltParser.catalogue(raw))
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].products[0].id, "sku")
        XCTAssertEqual(sections[0].products[0].name, "長い名前")
        XCTAssertEqual(sections[0].products[0].price, "27,500円 -> 25,100円")
        XCTAssertTrue(sections[0].products[0].requires3DS)
        XCTAssertEqual(sections[0].products[1].name, "使い放題")
        XCTAssertEqual(sections[0].products[1].price, "3,600円*")
    }
    func testProfileUsesExactPathsAndOwnActionsOnly() throws {
        let raw = #"""
        {"widgets":[{"components":[
          {"type":"tile-credit-card","data":{"description":"xxxx-1234"},"action":{"type":"web_view","data":{"web_view":{"link":"https://shop.povo.jp/manage/payment-details?native=1","needs_xauth":true}}}},
          {"type":"tile-nav-right","action":{"type":"web_view","data":{"web_view":{"link":"https://shop.povo.jp/manage/order","exit_url":"/manageOrderClose"}}}},
          {"action":{"type":"web_view","data":{"web_view":{"link":"https://shop.povo.jp/manage/order-history"}}}},
          {"data":{"help":{"action":{"type":"web_view","data":{"web_view":{"link":"https://shop.povo.jp/profile/email"}}}}}}
        ]}]}
        """#
        let profile = try XCTUnwrap(QuiltParser.profile(raw))
        XCTAssertEqual(profile.paymentMasked, "xxxx-1234")
        XCTAssertEqual(profile.webPages.map(\.kind), [.payment, .contract])
        XCTAssertTrue(profile.webPages[0].needsXAuth)
    }
    func testOrdersCannotTurnArbitraryJSONIntoSuccess() throws {
        let order = try XCTUnwrap(QuiltParser.order(#"{"success":true,"result":{"challenge_url":"https://bank.example.invalid/3ds","order_ref":"123","p_ref":"456"}}"#))
        XCTAssertTrue(order.needsChallenge)
        XCTAssertEqual(order.orderRef, "123")
        XCTAssertFalse(try XCTUnwrap(QuiltParser.order(#"{"result":{"order_ref":"1","challenge_url":""}}"#)).needsChallenge)
        for raw in ["bad", "{}", #"{"result":{}}"#, #"{"success":false,"result":{"order_ref":"1"}}"#] { XCTAssertNil(QuiltParser.order(raw)) }
    }
}
