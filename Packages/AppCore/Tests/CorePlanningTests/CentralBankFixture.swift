import Foundation

/// A shortened copy of the real answer of
/// https://www.cbr.ru/statistics/avgprocstav/ (fetched on 2026-10-29 with the plain
/// «OhMyMoney» user agent; the page is UTF-8, 200, and carries the table of decades the Bank of
/// Russia publishes). Only the first rows and the last one of the table are kept, and the chart
/// script and the page frame are cut out.
enum CentralBankFixture {
  static let page = """
    <div class="table-wrapper">
      <div class="table">
        <table class="data">
          <tr>
            <th>Декада</th>
            <th>Ставка, %</th>
          </tr>
          <tr>
            <td>II.10.2026</td>
            <td>13,0550</td>
          </tr>
          <tr>
            <td>I.10.2026</td>
            <td>13,0550</td>
          </tr>
          <tr>
            <td>III.09.2026</td>
            <td>13,0550</td>
          </tr>
          <tr>
            <td>II.09.2026</td>
            <td>13,0050</td>
          </tr>
          <tr>
            <td>II.12.2024</td>
            <td>22,2790</td>
          </tr>
        </table>
      </div>
    </div>
    """
}
