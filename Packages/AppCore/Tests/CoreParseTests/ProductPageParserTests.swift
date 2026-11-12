import CoreKit
import CoreParse
import Foundation
import Testing

@Suite("Product metadata from a single synthetic page")
struct ProductPageParserTests {
  private let page = URL(string: "https://shop.example/products/item")!

  @Test func openGraphAcceptsAttributeOrderEntitiesAndExactMoney() throws {
    let result = try #require(
      ProductPageParser.parse(
        """
        <meta content='Camera &amp; lens' property='og:title'>
        <meta property="product:price:amount" content="1234.5678">
        <meta content='USD' property='product:price:currency'>
        <meta property='og:image' content='/pictures/camera.jpg'>
        """, pageURL: page))
    #expect(result.name == "Camera & lens")
    #expect(result.priceE4 == AmountE4(raw: 12_345_678))
    #expect(result.currency == CurrencyCode("USD"))
    #expect(result.imageURL?.absoluteString == "https://shop.example/pictures/camera.jpg")
  }

  @Test func productInGraphTakesItsOwnOfferAndIgnoresOtherEntities() throws {
    let result = try #require(
      ProductPageParser.parse(
        """
        <script type="application/ld+json">{"@graph":[
          {"@type":"Organization","name":"Not a product","price":1},
          {"@type":["Thing","Product"],"name":"Desk","image":["../desk.jpg"],
            "offers":{"@type":"Offer","price":"999.99","priceCurrency":"EUR"}}
        ]}</script>
        """, pageURL: page))
    #expect(result.name == "Desk")
    #expect(result.priceE4 == AmountE4(raw: 9_999_900))
    #expect(result.currency == CurrencyCode("EUR"))
    #expect(result.imageURL?.absoluteString == "https://shop.example/desk.jpg")
  }

  @Test func microdataProductAndNestedOffer() throws {
    let result = try #require(
      ProductPageParser.parse(
        """
        <div itemscope itemtype="https://schema.org/Product">
          <span itemprop="name">Red &quot;chair&quot;</span>
          <img itemprop="image" src="/chair.png">
          <div itemprop="offers" itemscope itemtype="https://schema.org/Offer">
            <meta itemprop="price" content="42.10"><meta itemprop="priceCurrency" content="RUB">
          </div>
        </div>
        """, pageURL: page))
    #expect(result.name == "Red \"chair\"")
    #expect(result.priceE4 == AmountE4(raw: 421_000))
    #expect(result.currency == .rub)
  }

  @Test func malformedOrUnrelatedPageDoesNotSupplyGuesses() {
    #expect(
      ProductPageParser.parse("<title>Shop</title><script>broken</script>", pageURL: page) == nil)
    #expect(
      ProductPageParser.parse("<script type='application/ld+json'>{broken}</script>", pageURL: page)
        == nil)
  }

  @Test func invalidMoneyAndUnsafeImageDoNotEraseValidFields() throws {
    let result = try #require(
      ProductPageParser.parse(
        """
        <meta property='og:title' content='Safe'>
        <meta property='product:price:amount' content='-12'>
        <meta property='product:price:currency' content='???'>
        <meta property='og:image' content='javascript:alert(1)'>
        """, pageURL: page))
    #expect(result.name == "Safe")
    #expect(result.priceE4 == nil)
    #expect(result.currency == nil)
    #expect(result.imageURL == nil)
  }

  @Test func priceWithoutCurrencyIsNotAppliedInAnotherCurrency() throws {
    let result = try #require(
      ProductPageParser.parse(
        """
        <meta property='og:title' content='New name'>
        <meta property='product:price:amount' content='10'>
        """, pageURL: page))
    let original = Wish(
      name: "Old", priceE4: AmountE4(whole: 50), currency: .rub,
      url: page.absoluteString, createdOn: DateOnly(year: 2026, month: 11, day: 11))
    let updated = result.applying(to: original)
    #expect(updated.name == "New name")
    #expect(updated.priceE4 == original.priceE4)
    #expect(updated.currency == .rub)
    #expect(updated.url == original.url)
  }

  @Test func numericJSONPricesRemainExactBeyondBinaryIntegerPrecision() throws {
    let result = try #require(
      ProductPageParser.parse(
        """
        <script type='application/ld+json'>{"@type":"Product","name":"Exact",
          "offers":{"price":900719925474.0991,"priceCurrency":"USD"}}</script>
        """, pageURL: page))
    #expect(result.priceE4?.raw == 9_007_199_254_740_991)
  }

  @Test func commentsAndScriptTextCannotSupplyOpenGraphMetadata() {
    let result = ProductPageParser.parse(
      """
      <!-- <meta property='og:title' content='Comment'> -->
      <script>let fake = "<meta property='og:title' content='Script'>";</script>
      """, pageURL: page)
    #expect(result == nil)
  }

  @Test func microdataKeepsNestedTitleTextAndIgnoresBrandNames() throws {
    let result = try #require(
      ProductPageParser.parse(
        """
        <div itemscope itemtype='https://schema.org/Product'>
          <div itemprop='brand' itemscope itemtype='https://schema.org/Brand'>
            <span itemprop='name'>Other name</span>
          </div>
          <h1 itemprop='name'><span>Desk</span> &amp; <b>chair</b></h1>
          <meta itemprop='price' content='10'><meta itemprop='priceCurrency' content='USD'>
        </div>
        <div itemscope itemtype='https://schema.org/Product'><meta itemprop='name' content='Other'></div>
        """, pageURL: page))
    #expect(result.name == "Desk & chair")
  }
}
