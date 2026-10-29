# Changelog

All notable changes to OhMyMoney are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The database schema and the transfer-archive format are versioned separately from the app,
and both move forward only.

## [2.4.0] — 2026-10-29

Documents and Summaries. The database schema is 17; opening the app upgrades the database after a
verified copy, and older data reads as before. The export has 45 files.

### Added

- Attachments: files can be attached to an operation, an asset, a debt or a subscription. Any file
  of any size is kept as it is, without compression; each file is stored once (by its content) in a
  folder next to the database, and copies of the database refer to the files instead of copying
  them. A removed file waits 30 days in a trash; «Keep receipt photos forever» is on by default,
  and a single file can be marked «Keep always». A daily sweep applies the rule and never deletes
  a file that has no owner row. A new settings section «Attachments» holds the rule and the trash.
- The mirror folder receives the files too (it can be switched off), and the transfer archive can
  carry them with the box «With attachments (size)»; an older version of the archive opens without
  them. Files do not travel between devices, only the rows do.
- Warranty and return: the operation has «Warranty until», «Where the original lies» and
  «Can be returned until». The entry line reads «warranty 2y» and «return 14d» (in Russian too).
  «Worth a look» reminds about a return two days before it ends, and about a warranty 30 days before
  and on the last day. The new screen «Warranties» lists things with their terms.
- Receipt by QR: «File → Receipt by QR…» reads the code of a cash receipt from Continuity Camera,
  from a picture dropped on the window or from a file; on iPhone a scanner does it. The amount, the
  date and the time are read; an operation with the same amount within a day is offered to be
  completed (time and photo), otherwise a new operation is made. The items of a receipt are not
  read. A return receipt looks for a return operation.
- Summaries: a card above the tiles of Overview announces a finished period — a week on Monday, a
  month on the 1st, a year on 1 January; each kind can be turned off in «Settings → Planning →
  Summaries». A week has five cards and the question «How was the week?» (five faces; the answer
  lives in the database and the archive, not in CSV). «Did you know» offers a finding out of 25
  checks. A summary saves as a PDF (with hidden amounts it asks «Save with amounts?»), and the
  picture of the year can be shared. The figures agree with «Reports».
- The database schema is 17: tables of attachments and of the answers of the weeks, the warranty
  fields of an operation; the export adds `attachments.csv`. New settings keys in the table
  `settings`: `attachments.keepReceiptsForever`, `attachments.trashDays`, `attachments.mirror`,
  `archive.withAttachments`.

### Known limits

- A new operation from the entry line or from the panel ↓ gets no «Attachments» section until it is
  saved; the section is in the editor of a saved operation.
- Undoing the creation of an operation leaves its attachment rows without an owner; the daily sweep
  removes them.
- The camera of iPhone hands over a JPEG.
- The PDF of a summary is one page without splitting into A4 sheets.
- There is no separate tile «Warranties» in Overview.
- iPhone has no «Summaries» section in settings; the default values apply.

## [2.3.1] — 2026-10-29

Follow-ups to 2.3. The database schema is 16; opening the app upgrades the database after a
verified copy, and older data reads as before.

### Added

- Deposit rates from open sources: a switch «Take rates from open sources» (off by default). When
  it is on, the showcase shows a block «According to the Bank of Russia» with the average maximum
  rate of the ten largest banks (a market guide, not the rate of any bank), compares the sources
  and marks a bank whose rates differ with «rates differ, worth checking». If the rates cannot be
  read, a grey line says so and the built-in list stays as it was.
- Editing a saved operation asks about a card limit or a kept minimum balance, but only when the
  edit itself creates or deepens the excess; the line at the bottom, the form on the right and the
  edit window share one planner of questions.
- A test run can be repeated under six time zones (`scripts/test-zones.sh`), and
  `scripts/check-test-zones.sh` guards the list.

### Changed

- The database schema is 16: the table of rates takes the source «CoinGecko», so the rates of coins
  from 2.3 are marked honestly instead of «Bank of Russia»; the old rows come over unchanged.
- The entry panel shows the label «CoinGecko» next to the rate of a coin.
- Raiffeisenbank is removed from the deposit showcase: it has no deposits.
- Tests no longer depend on the time zone of the Mac: the zone is pinned to UTC (or the one named
  by `OHMYMONEY_TEST_TZ`), and the tests that failed in Asia/Baku, Auckland and Los Angeles are
  fixed.
- Correction to 2.3: the entry form on the right did ask about a limit and a minimum balance for a
  new operation; only the edit of a saved one did not.

### Known limits

- The rates of a bank are not read from a website: banki.ru is closed by protection, and a reader
  for sravni.ru needs the site's permission. The built-in list, your own offers and the guide of the
  Bank of Russia are all there is.
- An operation in a coin keeps the label «Bank of Russia» in the operations table (the table cannot
  hold another one); its rate in the table of rates is marked «CoinGecko».
- A quick move of an operation in the calendar asks no questions.

## [2.3.0] — 2026-10-29

Banks, conditions and deposits. The database schema is 15; opening the app upgrades the database
after a verified copy, and older data reads as before.

### Added

- Credit cards: a credit account always has a card; while the grace period runs it shows as a card
  with a «pay by» reminder, and once a statement date is missed the whole debt is shown in
  «Debts» and on the bank screen (the balance is counted once and the debt is not added to the
  totals); spending past the limit asks a question before it is recorded and puts a red line into
  «Worth a look».
- Bank conditions, typed by hand on an account or a card: free monthly limits for cash, SBP and
  transfers between banks, the condition for free service (spending from, or a balance from), a
  minimum balance (a question before the entry, never a ban), the expiry of a card with a reminder a
  month ahead, «What to rebind», «Forgotten money» (nothing moved for 90 days), and deposit
  insurance (1,400,000 ₽ per bank, marked on the bank screen and in «Capital»).
- A bank screen and the report «To banks for the year» (fees and interest, with a CSV).
- Cash: counting a wallet by bills.
- Deposits: a showcase of deposits (14 banks, rates by date, rates older than 30 days in grey, and
  your own offers) and a note seven days before a deposit ends (not financial advice).
- Cryptocurrency: your own currency with a rate from the network (only the id of the coin is sent;
  it can also be typed by hand; up to four decimals).
- Dividends and coupons as expected income, marked as such, in the calendar and from the card of
  an investment.
- Account colour: 12 colours, an icon, a stripe on the account screen and a dot next to operations.

### Changed

- A credit card without operations can be deleted; the dialog says what disappears with it, and
  «Settings → Accounts» now refuses with an alert.
- Editing a transfer opens in the column or the form on the right instead of a window of its own.
- iPhone: «Overview» follows the design (the card «Safe to spend now» first, then a strip of
  accounts), the choice of a light or dark theme applies, and the theme preview and the choice of
  an accent fit the screen.
- The database schema is 15: conditions of accounts and cards, the expiry of a card, offers of
  deposits and payouts. The export holds 44 files.

### Known limits

- The rates are the built-in list and your own offers; a reader of rates from a website is not
  there yet.
- The rate of a coin from the network is stored with the label of the Bank of Russia.
- The rates of two banks in the showcase are not filled in.
- Editing a saved operation does not ask about a credit limit or a minimum balance (fixed in 2.3.1).

## [2.2.0] — 2026-10-23

Four releases in one: statement import, the plan of the year, questions and commands, and
subscriptions. The database schema is 14; opening the app upgrades the database after a
verified copy.

### Added

- Import of bank statements (CSV and the text of PDF statements): a preview with new, duplicate,
  changed and unreadable rows, a category for what is not sorted yet, matching with entries you
  made by hand, applying with an undo, and a history of imports; a set-up of who you are so that
  transfers between your own accounts are recognised. Photos of receipts come in a later release.
- The plan of the year in Planning: history and seasonality, a forecast of the year, expensive
  months, limit seasons, a buffer with an offer to raise it, annual reserves, event templates
  and budgets, and exceptions to the limit of a month.
- Questions and commands: ask in words, a command palette, and saved views that apply to
  Operations and Analytics.
- Subscriptions: the cost per month and per year, used and unused marks, who uses each one, the
  history of prices, advice on what to cancel, notices, and a calendar of charges.

### Changed

- iPhone and iPad: the entry line is hidden until you tap the round «+» button above the bottom bar
  (bottom right corner on iPad), and no screen opens the keyboard by itself any more.
- The database schema is 14: import fields on operations, saved views, year-plan data, subscription
  data and the arrival day of a transfer. The export holds 42 files.

## [2.1.0] — 2026-10-23

Four releases in one: spending analysis, income and savings, rules and tags, and quick entry.
The database schema is 13; opening the app upgrades the database after a verified copy.

### Added

- Spending analysis: two periods side by side (ready pairs or your own range, with a CSV), «a
  year ago», the price of the weekend, the usual day, a heatmap by hour, favourite places and
  habits, what you spend on people, «leaks», what ate a limit, and the price of a purchase in
  working hours. Two new tiles, «Weekend price» and «Usual day». An operation can be marked
  one-off, singly or in bulk, to stay out of averages and forecasts.
- Income and savings: the savings rate by month, the budget split into needs, wants and
  savings against its target, the share of obligatory spending, the cushion in days, the
  stability of income, a note when spending grows faster than income, the effect of payday, and
  a financial health score with its history. Two new tiles, «Savings rate» and «Financial
  health».
- Rules and tags: rules that fill category, rating, whom it is for, place and tags; a preview
  and an undo for «apply to past operations»; `#tags` in the entry line, tag reports and
  filters; a file to exchange rules (`.ohmymoneyrules`).
- Quick entry: suggestions for places, correcting the last entry, repeating a past day, paste of
  a bank message, a split bar, moving an entry to another day, drafts, notes on a day, and the
  last four digits and details of a card.

### Changed

- The database schema is 13: a one-off flag, the budget basket of a category, card details,
  tags, rules and day notes. The export holds 35 files.

## [2.0.0] — 2026-10-22

OhMyMoney 2.0 is a new application with a new identifier: it runs on the Mac, the iPhone and the
iPad, and it does not update 1.13 — install it next to it and move the data over.

### Added

- The iPhone and iPad app: the same screens as the Mac, a floating navigation bar at the bottom of
  the phone and a bar at the top of the tablet whose number of sections follows the window width.
- Thirty colour themes, each in light and dark, with a preview on your own data; the contrast
  theme takes over when «Increase Contrast» is on.
- Exchange between the Mac and the phone through a folder you choose (iCloud Drive included):
  every device keeps its own local database, changes travel as small files, and a record changed on
  two devices waits in «Conflicts» until you choose. The folder also holds a verified copy of the
  whole database that an empty device can start from.
- Overview tiles as a catalogue: ten tiles for a new person, compact tiles side by side, eighteen
  new tiles and tiles that appear by themselves when their data exists.
- Redrawn screens: Operations, Accounts, Planning, Capital, Goals, Calendar, Debts, Analytics,
  Reports, the entry panel and the ten sections of Settings.

### Changed

- The database schema is 12: bookkeeping tables for the exchange only; recording is off until the
  app turns it on for the real database.

## [1.13.0] — 2026-10-21

Trips and readable backups in one release (the planned 1.12 and 1.13 were joined). Trips: a trip mode with the day's allowance, the summary of a trip, the cards abroad and the
exchange-rate difference.

### Added

- A strip over the window while a trip is on: where, until which day, the currency and the budget,
  and «Spent today / left for the day». A new operation starts in the currency of the trip and
  with its event. The morning after the last day the strip is a card, «Welcome back!», with the
  summary of the trip and an «Extend» button.
- The summary of a trip: what it cost over all of its operations, whatever their dates, by day, by
  category and by currency, against the budget, and what each person who travelled with you still
  owes you.
- «Cards abroad…»: the conversion and ATM fees of each card as the bank's tariff says them, and
  the card that loses least on an example sum.
- «Capital» names the exchange-rate difference of the month and of the year: what the money held
  in foreign currencies gained or lost in rubles only because the rate moved.
- An operation remembers the time zone it was recorded in, and stays on that day and at that time
  after the Mac comes home. Operations recorded before this are read in Moscow.

### Changed

- The entry panel asks «who it is for» once: one «For whom» menu (groups, people, «Add…») that is
  hidden when «Who it is paid for» already names the people; the «Paid for someone» button is kept
  only where that row is not offered, and «Split» reads «Split into parts».
- Database schema 11: nullable columns for the zone of an operation, the currencies of a trip and
  the foreign terms of a card, with no data step.

### Backups you can read (planned as 1.12)

Backups you can read: a name that says what a copy is, a list with what is inside each, a copy of
the day with a readable version beside it, copies that thin out by themselves, and a weekly check
of the database. The database schema is unchanged.

#### Added

- A copy is named by its date, version and reason: `2026-10-06 23.32 · 1.12.0 · after a change.sqlite`.
  Finder sorts the copies by time. The reason is worded in the language of the interface at the
  moment the copy is made. Copies of earlier versions keep their names and are read as before.
- A small description file beside each new copy (`….json`): when it was taken, how many operations
  it holds, the last operation and the balances. Settings → Backups lists every copy from these
  files without opening it, with its size, «Show in Finder» and «Compare with the current»
  (counts, balances, categories, the operations added and vanished, and the changed ones folded
  into one line that opens to «was → became»). Nothing is written.
- A copy of the day, once a day at the first launch of the day or at 03:00 while the app is open.
  It is checked in full. A missed day is not made up for.
- A readable version: beside the copy of the day and the copy made before an update, a folder with
  the CSV files of the export and a `README.txt` in two languages. A copy made before an update is
  read in its own, older schema. The folder stays on this Mac; the folder chosen for copies gets
  the `.sqlite` file alone.
- Thinning: every copy of today, one a day for the last week, one a week for a year, one a month
  after that. A copy is never deleted while a newer one is not verified, a copy that failed its
  check is never deleted, and the copies made before an update are never deleted by themselves;
  the list shows their size and «Delete older than a year…» with a confirmation.
- A warning below 1 GB free where the copies lie (in the settings and as a line of «Worth a look»),
  and «Free up space…», which shows what it would delete — the oldest copies after a change, then
  daily copies older than a year — and deletes exactly that after «Yes».
- A check of the database once a week, quietly, and «Check now»: SQLite's integrity and foreign
  keys, the parts of an operation adding up to its amount, a reconciliation with its balances, a
  transfer between two accounts. A problem is told by a line of «Worth a look»; «Repair…» makes a
  copy first and then removes only the orphan rows that hold nothing of yours.
- «Compare with an archive…»: an archive of the transfer, asking its password when it has one,
  against the database now. Archives and copies of an older schema are read too.
- `guide/database.md` describes every table and column of the database; a test fails when a
  migration adds one and the page forgets it.

#### Changed

- Copies after a change are checked with the quick check (`quick_check`); the full check is for the
  copy of the day and the copy made before an update.
- The count-based rotation (fifty copies and one a day for ninety days) is replaced by the thinning
  above, in the folder of copies and in the chosen folder alike. Only the copy of the day and the
  copy made before an update go to the chosen folder.

## [1.11.0] — 2026-10-20

What if: a window that works out a big purchase, a loan or a loss of income against today's numbers
before anything is spent.

### Added

- **What if…** (the Window menu and a button in Planning): type a purchase, a loan, an early
  repayment, a sum put aside every month or a loss of income, and see month by month how much free
  money is left and when it runs short. Nothing is written until the owner says so.
- **Saved scenarios:** name a scenario, save it, open it from the «Saved» menu and delete it. A
  scenario keeps only its changes and is worked out again from today's numbers every time; saving
  is one step of ⌘Z.
- **«Can I afford it?»** (a button in Planning and a link in the entry panel for an expense above
  30 000): tells whether the purchase can be paid for now, whether a goal moves or the cushion
  drops below its target, and when it will be possible if the owner waits — counted from the
  income less the median of all the habitual spending of the last three full months and the plans
  of the goals.
- **Goals in the owner's order:** drag a goal in Planning to place it; until the first drag the
  nearest by its day comes first. The order is one step of ⌘Z.
- **Record a refinancing…** on the card of a loan: a new loan pays off the old one in one record
  and one step of ⌘Z, with an optional fee.

### Changed

- The database schema is 10 (`0010_scenarios.sql`): the scenarios and the order of the goals.
  The change only adds; the copy before the update is kept as always.

## [1.10.0] — 2026-10-20

The app is now called OhMyMoney, and a round of fixes from the owner's notes.

### Changed

- The app is called **OhMyMoney** in both languages: the display name, «About», the menus, the
  guide, the README and the project itself. The file, the release bundle id and the update feed
  keep their old names until the move to the App Store.
- «Transactions» is split by day only, one section per day with the day's total in the header;
  incomes, expenses, refunds, money back and transfers stand in one list by time.
- ⌃⌘F is «Full Screen» in the View menu and works from any window of the app.
- Choosing another person for an expense now always asks «Will the person pay it back?», and the
  answer about each person is offered again next time.
- Money a person sends back is filed in a «Paid for others» income category the app makes itself
  the first time there is a surplus over the parts they cover.
- A returned thing bought in instalments asks whether the overpayment of the parts still to pay is
  cancelled or stays a debt.
- «About» lists the libraries the app uses with their licences.

### Fixed

- Settings → Accounts opened as an empty window; the window of settings no longer folds its side
  panel and the toggle button is gone.
- The «Open Gosuslugi» link of the credit-history reminder is removed; the reminder stays as text.
- The number of the day in the Overview calendar no longer breaks into two lines.

### Development

- Window tests attach an assistive client before they look up SwiftUI controls: since macOS 27
  SwiftUI builds the accessibility tree only then, and 77 tests had been finding nothing.

## [1.9.1] — 2026-10-14

A new icon, and an app checked by almost twice as many tests.

### Changed

- The icon is a layered Icon Composer icon, with the glass of macOS 26. The Debug build wears the
  same icon with a red «DEBUG» band, and each build carries only its own.

### Fixed

- «Suggest limits…» no longer traps on an amount at the very top of the range.
- When two answers about an early repayment were given on the same day, the next payment offered
  the first of them instead of the last.
- The preview of an instalment plan in the new-debt wizard showed parts a few kopecks off the plan
  it then saved: price and markup are now divided each on its own, as the plan divides them.
- A version string with an empty part («1..2», «1.4.») is no longer read as a version.

### Development

- The tests of the app — 4 247 of them, up from 2 606 — run in several copies of the test host at
  once, each with a bundle id and so a container of its own; the few that need the active app run
  after them, one by one. A full run takes about three minutes instead of twenty-three.
- No test is skipped on the author's Mac: a skipped test fails `make test`, and the performance
  budgets (`make bench`) are part of `make verify`.

## [1.9.0] — 2026-10-13

Credit as the bank keeps it — instalment plans, credit cards with a statement and a grace period,
early repayment, a payoff ladder and the true cost of a loan —; the allocation of an income by
your own rules; self-employment with its tax counted by itself; and an easier app: Transactions
as a screen of the main window, settings with a sidebar and a search, the size of the text, how a
currency is written and currencies of your own. The database schema moves to 9: the update only
adds columns and five tables, and before it the app makes a checked copy of the database
(`-before-migration`).

### Added

- **A new debt, step by step** — Debts → **New debt** asks what it is (a bank loan, a mortgage,
  an education loan of the state programme, instalments, a purchase on credit, a credit card, I
  owe a person, owed to me, a pledge or deposit), then the sum and the day, then the payments with
  only the fields of that kind, and shows **How it will be** — the schedule, the interest or the
  markup in it — before **Save**. A mortgage is a bank loan with a schedule, not a kind of its own.
  **Credit card** makes no debt: it chooses or creates the account of the card and opens its terms.
  Editing a debt keeps the form it had, with the new fields.
- **Instalments** — a purchase paid in parts: 4 payments every two weeks by default, the first on
  the day of the purchase, or once a month. The parts are equal to the kopeck and the remainder
  goes to the last (1,000 in 3 → 333.33, 333.33, 333.34). What the plan costs above the price is
  spent part by part: every payment writes its share of the markup as an expense in the debt's
  subcategory of «Credits», and editing or deleting the payment rewrites or takes it in the same
  step of ⌘Z. A sum the bank's app shows for a due can be typed in and wins over the worked-out
  one. In the ↓ panel, **On credit** offers instalments too.
- **A thing bought in instalments, returned** — the refund asks whether the bank **lowers the
  debt** (the default) or **gives it back to the card**: lowering it, what was already paid off
  the price goes back to the account and the rest comes off the debt, in one step of ⌘Z; a plan
  brought to zero offers to close.
- **«Instalments»** — a line on top of «I owe», «In instalments: 34,000 ₽ · next 2,500 ₽ on
  14 November», and a new Overview tile (Plan group), added from **Edit → Add Tile**.
- **Credit cards** — a credit card stays an account below zero; its terms are in the account
  editor: the limit, the rates on purchases and on cash and transfers, the grace period («a
  statement every month on day N, pay within M days» — 25 by default — or «N days from the first
  purchase»), the minimum payment (a percent of the debt, not below a floor), the fee for cash
  and transfers (a percent plus a fixed sum) and «cash and transfers have no grace period». The
  screen of the card shows **Available X of Y**, **Pay by … : X not to pay interest · minimum
  payment Y**, the statements, and cash and transfers «interest runs at once».
  - A statement not paid in full by its day loses the grace period: interest appears as a grey
    **≈**, counted from the day of each purchase at the purchase rate until it is paid off, oldest
    first, until a statement is paid in full again; cash and transfers without a grace period
    count from the first day at their own rate, with the fee. **Record interest…** writes what the
    statement says (in «Credits → Credit card interest») and replaces the estimate. «≈» is never
    money: not in balances, the free sum, the forecast or Capital.
  - Cash and transfers from a credit card write the bank's fee by themselves, as an expense in
    «Fees» with the transfer: filled in from the terms, seen and editable before it is saved.
  - A card out of the summary adds a grey line «Credit cards to pay (out of the summary)» to the
    free sum; a card in the summary changes nothing there — its minus is already in the money now.
  - A credit card kept both as an account and as a credit-card debt offers **Keep only the
    account**: the debt is deleted (softly), its rate moves into the card's terms; one step of ⌘Z.
- **The main card of an account** — a purchase is made with a card by default: the card named in
  the line, else the card last used at that place, else the account's **main card** (Settings →
  Accounts and «Make main» on the account screen), else its only card. «со счёта» / «from
  account» in the line, or **Card · Account** in the ↓ panel and the form at the side, pays from
  the account with no card.
- **Fees, insurance and the true cost of a loan** — **Fees and insurance…** on a loan: a fee,
  insurance or another cost, once, every month or every year, once-paid ones «included in the
  loan» or not. The card shows the overpay (all payments and costs minus what was received) and
  the **real rate ≈** worked out as the full cost of credit is, and a word when it differs from
  the contract's by more than half a point. A cost paid once is written as an expense on its day
  with the loan; insurance can be given back within 30 days, and «Worth a look» says until when.
- **Early repayment** — a payment on a loan above what its due still asks asks **Lower the
  payment**, **Shorten the term** or **It is a payment ahead** (the last answer for that debt is
  suggested; the first time — the term) and keeps the choice on the journal line; a payment ahead
  closes the next dues, as in 1.8. Interest counts by days; a bank that takes
  early repayments only on a payment day lowers the debt on the next one. **Plan an early
  repayment…** keeps the day and the sum (not money) and «Worth a look» reminds to file the
  application N days before (one by default).
- **Payoff ladder** in Debts — the money above the minimum payments («On average N is left a
  month» suggests it), the **avalanche** (highest rate first, the default) or the **snowball**
  (smallest balance first) with what the avalanche saves, the month you are free of debts, the
  interest on the way and the order; a debt or a credit card can be left out. Worked out anew on
  every look.
- **Debt load** in the Planning hints — the payments of every debt you owe in a month plus 5 % of
  credit card debt, against the median earnings of six full months, with 12 months of history
  and the Bank of Russia's thresholds (50 %, 80 %) as words, not colours.
- **Pledges and deposits** — a debt owed to me with «Due back by», reminded a week before and
  after; **Write off…** turns what was not returned into spending in the category you choose and
  closes it.
- **Remind…** on a debt owed to me — a polite text with the name, the sum, what for and the day,
  edited and copied; your edit becomes the template of the next one.
- **Reminders in «Worth a look»** — the application for an early repayment, a pledge due back,
  insurance that can still be given back, a credit card to pay by its day or a grace period lost,
  and twice a year (1 February and 1 August) the credit history, with a link to Gosuslugi opened
  in the browser; **Done** puts a reminder away on this Mac, and the credit history can be turned
  off in Settings → Planning.
- **Debts written before 1.9** — nothing is worked out anew. After the launch reminders, each open
  debt you owe is asked about once: a loan — its fees and insurance, the full cost of credit, early
  repayment on any day, the days of notice, the ladder; a purchase on credit — whether it is an
  instalment plan; a credit card kept as a debt — keeping only the account. **Save** and **Not
  needed** mark the debt seen, **Later** asks another time.
- **Allocating an income** — after an income in «Earnings» the line says «Recorded. Allocate
  120,000 ₽?» with **Allocate…**, and «Worth a look» keeps the offer for 30 days (**Not now**
  puts it away).
  The sheet fills its lines from your **rules** — N % of the income after the tax of
  self-employment, or a fixed sum, into a goal, to an account or to the safety cushion — and shows
  what only is shown: payments, dues of debts, the tax and what is left of the limits until the
  next expected income. **Unallocated** is what stays, and nothing has to be zero. **Record**
  writes the contributions and transfers in one step of ⌘Z; the income remembers it («Allocated
  70,000 of 120,000»). A goal that is reached gets only what it lacks and asks to drop its rule;
  a raise («N more than usual») can be spread by the rules. Deleting an allocated income asks
  whether to delete its allocation too.
- **Where the money of a goal lies** — a goal can name its account and «Also move the money
  there» when it gets a contribution from the allocation.
- **Two halves of the month** — with an expected income twice a month, the free sum gets a second
  line «Until the 25th: X · Y a day», and «The salary did not come?» when its day passed without
  it. On the 1st, **What is left of September** offers to put the rest of the month on the cushion
  or into a goal.
- **Self-employment** — **I'm self-employed** in Settings → Planning (offered once after a first
  income of the kind or «смз» in the line). The ready categories «Earnings → Self-employment →
  from individuals (4 %) / from organisations (6 %)», or a tax rate on your own income categories.
  The tax counts itself at the Bank of Russia rate of the day, with the deduction (asked once),
  the 100-ruble rule and the due date of the 28th: «tax ≈ 240 ₽ (4 %)» in grey under the amount of
  an income, a grey line «Tax of self-employment ≈ — not your money» in the free sum from the day
  of the income, «Tax for October ≈ X by 28 November» with **Pay…** in Planning (checked against
  «Мой налог»; what the tax office charged differently is shown), the limit of the year with a
  warning from 90 %, a **Self-employment** block in Planning and an Overview tile. The tax paid is
  an expense in «Taxes → Tax of self-employment», which takes no limit. Another rate on an income
  category (the simplified tax, 6 %) gets the tax ≈, the line in the free sum and a payment in
  Planning once a quarter, due the 28th of the month after the quarter — without the deduction or
  the 100-ruble rule.
- **A hint about burnout** — at most once a week in «Worth a look», when small unnecessary
  purchases of a week are well above your usual week; it needs the necessary categories marked
  and can be turned off in Settings → Planning.
- **Currencies of your own** — Settings → Currencies: a code of three Latin capitals that is not
  an ISO code, a name, a symbol and decimals, with rates typed by hand day by day; the Bank of
  Russia is never asked for them, and a day before the first rate has no rate. The line reads the
  code, and the symbol stuck to the number.
- **Text size** — Settings → Appearance: Small, Regular, Large or Extra Large, for every window;
  amounts keep digits of one width.
- **How a currency is written** — Settings → Appearance: Symbol (the default), Code or Name (a
  Russian name only in Russian) on screens, charts and «Why so»; CSV files and the fields you type
  into stay as they were.
- «What's new in 1.9» — six cards; the sample and the demo have a credit card, instalments, an
  early repayment, a pledge, allocation rules, self-employment and a currency of their own.

### Changed

- **Transactions is a screen of the main window** — «Spending» (⌘4) became **Transactions**, the
  full table with its filters, search, inspector and bulk actions; **Columns…** chooses the
  columns, their order and width, **Reset to Defaults** brings back the standard ones. The
  separate Transactions window is gone: ⌘⇧T, ⌘F and the toolbar button open the screen in the main
  window, and the screen keeps its filters while you look elsewhere.
- **Settings** — a sidebar of sections with a search that finds a setting by its caption in either
  language; captions are easier to read; every window opened from the settings (the tutorial, the
  password, cashback rules, a new bank…) opens over them.
- **Currencies** — the limit of 10 currencies is gone: turn on any currency of the Bank of Russia.
- **Capital** — the groups of accounts are folded at first; what you open is kept on this Mac.
- The debt load hint counts as described above, in place of payments against the estimate of the
  month's income.
- The database schema is 9 (`Schema/0009_credit_and_allocation.sql`): new columns of `debts`
  (steps of payments, parts and markup, the full cost of credit, early repayment, the ladder,
  pledges, `terms_reviewed`), `debt_entries.prepay`, the credit card terms and `main_card_id` of
  `payment_methods`, `goals.account_id` and `transfer_on_contribution`, `transfers.external_id`,
  `categories.tax_rate` and `tax_npd`, and the tables `debt_instalments`, `debt_costs`,
  `allocation_rules`, `custom_currencies`; nothing is rewritten and no row is added. The CSV
  export has 31 files: `debt_instalments`, `debt_costs`, `allocation_rules`, `custom_currencies`
  and `settings` (the whole settings table of the database) at the end, the new columns last. The
  transfer archive carries schema 9 and still opens archives of schema 8 and older.

### Fixed

- **The Transactions table could make AppKit reenter its own delegate** — the table was made with
  its rows already in it, and AppKit reported a «reentrant NSTableView» while the window was
  being laid out (in 1.8 too). The table is now made empty and filled once it is on screen.
- **Search ignores «ё»** — «елка» finds «Ёлка» in the operations and the transfers of
  Transactions, as names are compared everywhere else.
- **Find missing operations…** in the reconciliation sheet closes the sheet, which hid the table,
  and what you typed into it comes back when you open it again.

### Upgrading

The update of the database is one way: before it the app makes a checked copy with the suffix
`-before-migration`, which rotation never removes, also in your backup folder. Going back to 1.8
means restoring that copy. A row of `debts`, `payment_methods`, `goals` or `categories` edited by
hand into something its checks forbid stops the update (the database stays at 1.8 and nothing is
changed); the copy and the backup folder keep your data.

A currency of your own is three Latin capitals: USDT is written as, say, `UST`.

## [1.8.1] — 2026-10-12

A fix for a lockout: with «Lock OhMyMoney» on, a window the app opened by itself at launch could hide the way to unlock it.

### Fixed

- **The app could not be unlocked at launch.** When the lock was on and the app opened a window of its own over the
  locked main window — the overdue payments, «The last session did not end» after a forced quit, the guide cards — that
  window was covered too, with no way in, and it kept the unlock of the main window out of reach; a forced quit brought
  «The last session did not end» back on the next launch. Now nothing the app opens by itself appears while it is locked:
  it waits and appears after the unlock, and if the lock comes while such a window is up, it goes away and comes back
  after the unlock, still unanswered. An archive opened from Finder while the app is locked waits for the unlock too.
- **Every window covered by the lock can unlock it.** A sheet or panel open while the app is locked carries its own
  password field (when the app has a password) and «Touch ID or Mac password»; Return, Enter, Esc and Tab can no longer
  press a button of the covered window blind.

## [1.8.0] — 2026-10-12

Every Overview tile, laid out in groups and able to explain its own figure; a shorter and friendlier
Planning screen; a password of its own for the lock; windows without tabs, and closing the main
window quits the app; a tutorial that lights up where to click. The database schema stays at 8 and
nothing in the database changes.

### Added

- **Why so** — click any of the 22 Overview tiles and a sheet takes its figure apart: rows that add
  («+») or take away («−») and the total («=»), which is exactly the figure on the tile, then the
  rule in one sentence. Tiles that have no single figure (limits, payments in 7 days, the last count
  and record, «Worth a look») list their rows. A button opens the place the figure lives —
  the right section of Analytics for the current month, Planning, Debts, Spending, Calendar, Net
  Worth, All Accounts or the reconciliation sheet. The sheet uses the same calculations as the
  tile, and **Hide amounts** masks its money too. VoiceOver offers «Why so» as an action of the tile.
- **Overview groups** — tiles sit in three groups, **Money**, **Plan** and **Analysis**; a click on
  a group's name folds it away (remembered on this Mac only).
- **Edit on the Overview** — the tiles get a dashed outline and stop reacting to clicks; drag a tile
  within its group or into another one, drag a group by its name, hide a tile with «−» (never the
  last one shown), bring a hidden one back from **Add Tile**, then **Done**. A hidden tile keeps its
  place and comes back to it. VoiceOver moves tiles up and down, into another group, and groups up
  and down, with actions.
- **The Planning screen** —
  - a sentence on top, from the same figures as the free sum: «Until 31 October you can spend
    another 42,000 ₽», with the dues of payments and of debts by then, or «the plans ask X more than
    there is»; no sentence before the first count;
  - **Next 14 days** — a ribbon of the coming days, income on the upper lane, payments on the lower,
    a symbol and a count on each day; a click opens the payment or the income (a debt opens Debts,
    several items on a day give a menu);
  - every block is a card with a symbol, a total in its header and a fold; two columns on a wide
    window, one on a narrow one; «Payments and subscriptions» are now two blocks, **Payments** and
    **Subscriptions**;
  - an empty block says what it is for and has a button to add the first one;
  - a **+** button adds a payment, a subscription, an income, a limit, an event or a goal;
  - long blocks (payments, subscriptions, expected income, goals) show the nearest few by date and
    **Show all (N)**; how many is set in Settings → Planning (3, 5, 10 or all; 5 by default), and each
    block can choose its own number in its header;
  - **Edit** on the screen and Settings → Planning → **Planning screen** reorder the blocks by drag
    (and by VoiceOver actions), **Standard order** puts them back.
- **A password for the lock** — turning on **Lock OhMyMoney** asks for Touch ID or the Mac password
  first, then for a password of OhMyMoney typed twice (at least 4 characters). The cover has a password
  field (Return unlocks) and **Touch ID or Mac password** beside it. Five wrong passwords in a row
  pause the field for 30 seconds, and a relaunch neither shortens the pause nor resets the count. **Forgot password?**
  asks for Touch ID or the Mac password and then a new password; «Later — open without a password»
  removes it and leaves Touch ID. Settings → General → Privacy: **Set Password…**, **Change…**,
  **Remove**. Only a PBKDF2 hash of the password is kept, in the login keychain of this Mac — never in
  the database, the archive, the journal or a problem report. A lock turned on in 1.7 without a
  password keeps opening by Touch ID until you set one.
- **A tutorial that shows where to click** — every task of the tutorial is one or two steps; the
  window darkens with a cut-out exactly around the control to press and a caption saying what to do
  and why. A click on the control works as usual and moves to the next step, a click elsewhere is
  held, steps typed into the line move on by **Next** or when the task is done, Esc leaves. **Help →
  Show Where to Click** walks through the line, the fields, the sidebar sections (⌘1–⌘6) and the
  toolbar; cards of the tour and of What's New that name a place have **Show Me Where**. A control
  the window cannot outline (the toolbar, the Settings window) gets a caption in the middle and
  stays clickable. VoiceOver reads each step, Reduce Motion turns off the animation, Increase
  Contrast outlines the cut-out; the form column on the right has the overlay too.
- **What's New in 1.8** — five cards, once after the update.

### Changed

- The Overview shows **every tile** — no more limit of 12. Your order is kept; the tiles you did not
  have are added at the end of their groups. Settings → Appearance → **Overview tiles** shows the
  groups with their tiles: tick to show, drag a tile (also into another group), drag a group by its
  name, **Reset** for the standard layout.
- **No tabs.** Analytics, Transactions and Reports (⌘⇧A, ⌘⇧T, ⌘⇧R) open as windows of their own;
  a second press brings the same window forward. The menus have no tab items. Over a main window in
  full screen they open floating in the same Space and never larger than the screen; they no longer
  go full screen on their own.
- **Closing the main window quits OhMyMoney** — the same way as ⌘Q: the calculation stops, a pending
  backup is written, then the database closes. Closing another window only closes it, unless it is
  the last one. The tutorial and the data sets behave the same.
- The transfer archive's `settings.json` carries two more keys: `overview.layout` (groups and tiles
  in order, hidden ones marked) and `planning.blockOrder`. `overview.tiles` is still written, so an
  older build shows the same tiles; an archive with only `overview.tiles` replaces this Mac's
  layout. Older readers skip the new keys; `formatVersion` stays 1.

### Fixed

- **Show Where to Click** could miss a control marked inside another marked place; nested places are
  outlined each on its own.

### Upgrading

Nothing to do: the database is not updated (schema 8 as in 1.7) and nothing is rewritten. If a build
is signed ad hoc, macOS may ask once whether OhMyMoney may use the keychain when you set the lock
password — allow it.

## [1.7.0] — 2026-10-11

Capital — what you have minus what you owe, month by month — with property valued by hand, and a
safety cushion that tells how many months you would last without income. The database schema
moves to 8: the update only adds columns and two tables, and before it the app makes a checked
copy of the database (`-before-migration`).

### Added

- **Capital** — a sidebar item (⌘6, after Calendar): the net worth in rubles, «↑ 85,000 ₽ since
  the end of September» (an arrow and a sign, no colour of good or bad), then three blocks.
  - **Net worth by month**: the net worth at the end of every full month and now, with «Have» and
    «Owe» beside it, each series its own shape; the range is **12 months** or **All**, kept on
    this Mac only. A month before the first count of any account is not a point.
  - **What it is made of**: «What I have» — accounts in the summary, deposits and savings
    accounts, accounts out of the summary by group, property by kind, money owed to me — and
    «What I owe» — every debt by name, with «of which interest ≈» for a loan that accrues interest.
    Each row shows its share; a click opens the account, the debt card or the property.
  - Nothing is guessed: an account never counted is listed «Not reconciled, not counted», a
    currency without a rate «No rate», property before its first valuation «No valuation».
  - Accounts count at the CBR rate of each month end, archived accounts with their history,
    negative balances as they are. Interest a deposit has accrued but not paid is not counted
    (a grey «+ accrued ≈ …, not counted until paid» on its row). Debts count by their journals up to the day, with the
    interest of a loan that accrues it; a closed or deleted debt counts nothing; parts paid for
    somebody else are not «owed to me».
  - When a credit card is kept both as an account below zero and as a credit-card debt, the
    screen says its money may be taken off twice — a hint, nothing is changed.
- **Property** — **Add property…** on the Capital screen: name, kind (vehicles, real estate,
  equipment, investments, other), currency, value and its day, a note. The property and its first valuation
  are one step of ⌘Z. The row menu: **New valuation…** (a valuation of the same day replaces it),
  **Valuation history** (with delete), **Sold / written off…** (counted through the day before,
  then listed under «Sold»), **Edit…** and **Delete…** — ⌘Z brings the property back with every
  valuation.
- **A safety cushion** — on the Capital screen and as a row above «Goals» in Planning: «Without
  income you would last 3.5 months», the cushion money and the obligatory spending a month, a
  bar to the goal, always with its label.
  - **Accounts and categories…** marks the cushion accounts (every currency of them) and the
    essential spending categories. On the first open the usual ones — groceries, utilities, the
    phone, transport, health, rent — are ticked when you have them, and nothing is saved until
    you save. One step of ⌘Z.
  - The obligatory spending of a month is what was paid on scheduled payments and subscriptions,
    the dues of debts with a schedule (an early repayment is not obligatory) and the spending in
    essential categories; the figure is the median of the last 6 full months (3 to 12, in Settings
    → Planning), never below the payments you are committed to today. With fewer than 3 full
    months it says there is too little data.
  - The account editor has **Money of the safety cushion**, the account screen a «Cushion» badge,
    and Settings → Categories an **Essential spending** menu: as the parent, yes or no (not on
    system categories or income).
- **A cushion goal** — **Goal…**: a cushion of 1 to 24 months of obligatory spending (6 by
  default), optionally by a month, and «put aside X a month until …» or «at the present pace —
  by …». The goal is a setting, not a row of Goals: nothing in the goals, limits or the
  «good» rating changes. One step of ⌘Z, **Remove the goal** included.
- **Keep the cushion out of the free sum** — off by default; in the goal form, in the «Free sum»
  block once an account is marked and in Settings → Planning. On, the free sum leaves out
  today's money of the cushion accounts in the summary and says so in a grey line.
- **Two Overview tiles**, **Capital** and **Safety cushion** (the 21st and 22nd), not among the
  twelve shown by default; add them in Settings → Appearance.
- **The sample and the demo** have a car valued three times, each time for less, a brokerage
  account valued at the end of every month, the savings account kept as the cushion, essential
  spending marked and a cushion goal of six months.
- **What's New in 1.7** — four cards, once after the update.

### Changed

- The database schema is 8 (`Schema/0008_capital.sql`): new columns `payment_methods.cushion`
  and `categories.essential`, new tables `assets` and `asset_valuations`; nothing is rewritten
  and no row is added. The cushion settings live in the `settings` table under `cushion.*`, only
  once set. The CSV export has 26 files: `assets.csv` and `asset_valuations.csv` at the end, the
  new columns last (`essential` empty, `true` or `false`). The transfer archive carries schema 8
  and still opens archives of schema 7 and older.
- The debts you owe now show in one place outside Debts: Capital. The Overview, Analytics and
  the free sum still leave debt balances out.

### Upgrading

The update of the database is one way: before it the app makes a checked copy with the suffix
`-before-migration`, which rotation never removes, also in your backup folder. Going back to 1.6
means restoring that copy. A row of `categories` edited by hand into something its checks forbid
now stops the update (the database stays at 1.6 and nothing is changed); the copy and the backup
folder keep your data.

## [1.6.0] — 2026-10-11

Loans with a grace period and tranches — the state-backed education loan first of all —, the
interest a loan charges inside each payment, and deposits and savings accounts that earn interest.
The database schema moves to 7: the update only adds columns, and before it the app makes a
checked copy of the database (`-before-migration`).

### Added

- **An education loan** in Debts → **+ Debt** → **Education loan (state programme)**: a loan you
  owe at 3 %, a grace period with the payments of the state programme — 40 % of the accrued
  interest in the first year of the loan, 60 % in the second, all of it from the third, counted
  from the first tranche —, the main schedule from a day you set (the form starts with the 1st of the month a year on)
  and the main debt worked out over 180 months. The share of the interest the grace
  payments do not ask for is not forgiven: it joins the debt when the main schedule starts.
- **A schedule for any loan** — the **Schedule** section of a new debt and **Schedule…** on its
  card: a grace period until a day, the grace payment («Interest only», «State programme» or
  «Fixed» with its sum), the main payment typed as the bank says or **Work out over a term** (an
  annuity at the loan's rate). Every change of a schedule is one step of ⌘Z.
- **«How does the bank count a payment?»** is asked when a loan with a rate is created, and the
  loan is not saved without an answer: **Interest first** — the bank charges interest day by day
  on what is owed, and a payment first pays the interest accrued since the payment before — or
  **All to the debt**. Debts made before keep reading as they did.
- **Tranches**: **Add Tranche…** on the card of a loan with a grace period. A tranche is money the
  bank paid for tuition: an expense in «Education» on its day (made at the top when there is
  none), on the loan the way a purchase on credit is — spending once, no money moved on your
  accounts — and the debt grows by it. A day still ahead is a planned tranche: the schedule
  counts it, the debt grows on that day. One write, one step of ⌘Z.
- **The interest inside a payment.** On a loan whose tranches were the expense, a payment is not
  spending except for the interest it pays: beside the payment the app writes that interest as an
  expense in the loan's subcategory of «Loans», moving no money of its own. It follows the payment
  when the payment is edited and goes with it when it is deleted, in the same step of ⌘Z.
- **The loan card** tells the grace period and its payment («Grace period until … · payment ≈ …
  (state programme interest, 40 %)»), the main schedule («From … — … a month»), the tranches
  («Tranches: 2, … in all»), the interest accrued and not paid yet, and in the journal of each
  payment «of it interest ≈ …». «Paid X of Y» measures each due by its own sum.
- **Every planning screen knows the dues of a schedule**: the 7-day payments, the overdue
  payments at launch, the free sum, the plan of the month, the forecast of an account's balance,
  the form of a payment and the debt load — each due at its own sum, a grace due included.
- **Deposits and savings accounts.** In the account editor, **The balance earns interest**: the
  rate in percent a year, the payout — monthly, quarterly or at the end of the term —, its day,
  where it goes (onto the account itself, capitalisation, or to another account), the day it was
  opened and, for a deposit, the day it closes. The first such account brings the income category
  «Interest» (or uses the one you already have) in the same step of ⌘Z.
- **Interest on the account screen**: the rate and the next payout, what was earned since the
  period began, what is due on the pay date and where it goes, for a deposit what is left to the
  end of the term — all estimates, with «≈», worked out on the balance of each day (a day earns
  on the balance it starts with, actual/365 or 366). A payout that does not come five days after
  its pay date asks «Interest … for … did not come?». **Record…** writes the income the bank paid,
  prefilled with the estimate, into the category of interest — interest is income only once you
  record it.
- **Interest in the account forecast**: the forecast of the balance at the end of the month has a
  grey line «Interest ≈ +…» for the payouts still due this month. The free sum does not count
  interest that has not come.
- **Planning → Expected income** shows the interest payouts of the month that have not come, grey and
  read-only, with **Record…**.
- **The sample and the demo** have an education loan with two tranches and paid grace payments,
  and a savings account at 16 % with its first month's interest recorded.
- **What's New in 1.6** — four cards, once after the update.

### Changed

- The database schema is 7 (`Schema/0007_debts_and_deposits.sql`): new columns on `debts`
  (`accrues_interest`, `main_from`, `grace_kind`, `grace_payment_e4`, `repay_months`),
  `debt_entries` (`tranche`) and `payment_methods` (`interest_rate`, `interest_period`,
  `interest_day`, `interest_account_id`, `deposit_opened_on`, `deposit_ends_on`); nothing is
  rewritten. The CSV export keeps 24 files with the new columns last; the transfer archive
  carries schema 7 and still opens archives of schema 6.

### Upgrading

The update of the database is one way: before it the app makes a checked copy with the suffix
`-before-migration`, which rotation never removes, also in your backup folder. Going back to 1.5
means restoring that copy.

## [1.5.0] — 2026-10-11

A spending calendar, hidden amounts and a Touch ID lock, suggested limits, the time and the
cashback in the entry line, and a form at the side that edits what you select. The database
schema stays at 6: nothing is migrated.

### Added

- **A spending calendar** in the sidebar (⌘5) and as an Overview tile, **Calendar**: a month or
  a week, what each day cost — your own expenses, in the default currency at today's rate,
  rounded to the ruble, without reconciliation differences. A day well above a usual one is
  marked «More than usual» (from 1.5 times) or «Much more than usual» (from 3 times), always with
  a symbol and the words; a usual day is the median of the days with spending in the 90 days
  before, and with fewer than 14 such days the calendar says there is too little data. From
  today on, the days show the payments still to pay and the income still expected. A click on a
  day lists its operations. Weeks start on Monday in Russian, on the Mac's first day otherwise.
  The tile is not among the twelve shown by default; add it in Settings → Appearance.
- **Hide Amounts** (⌃⌘H, the eye button in the toolbar, or View → Hide Amounts): every amount of
  money on screens, charts and tiles reads «•••». Counts, percentages and rates stay; the fields
  you type into and the exported files do not change. The choice is kept on this Mac only and is
  not carried by the transfer archive.
- **A Touch ID lock**, off by default: Settings → General → **Lock OhMyMoney**, turned on only after
  Touch ID or the Mac's password confirms it. OhMyMoney then locks when it opens, after 1, 5, 15 or
  60 minutes without a key or a click in it (5 by default), when the Mac sleeps or locks its
  screen, and from View → **Lock OhMyMoney**. A locked window shows no figure and no word of your
  books, only **Unlock**; calculations and backups go on behind it. There is no lock in a data
  set or in the tutorial.
- **Suggest Limits…** in Planning → Limits: the top-level categories without a limit that you
  spent on in at least two of the last three full months, each with a usual month of them (the
  median of the three) or 10 % less, rounded up — to 500 ₽ under 10,000 ₽, to 1,000 ₽ from
  there. A sum you change stays yours; the limits ticked are written at once and one ⌘Z takes
  them all back.
- **The time and the cashback in the entry line.** «pear yesterday at 18:09 325 cashback 9.76»
  or «груша вчера в 18:09 325 кэшбек 9.76» writes an expense of 325 ₽ yesterday at 18:09 with
  9.76 ₽ of cashback; «at 6:09pm», «18:09» and «cashback 3%» are read too (a percentage becomes
  an amount, rounded the way the account rounds its cashback). A time is never the amount. A
  time no clock shows is refused with its reason: «There is no such time: 25:00». Income and
  money back have no cashback: there the words stay in the note.
- **Editing in the form at the side.** With Settings → Input → «Detailed form at the right», one
  operation selected in a list of the main window opens in the form: «Edit operation», with
  **Cancel** and **Save**; one ⌘Z takes the edit back. Several rows, or a transfer, leave the
  form for a new operation.
- In that form a place you choose brings the category and the subcategory of your last
  operation of the same kind there, unless you chose a category yourself.
- The comment of an operation can hold several lines: ⌥Return starts a new one. Lists show it
  on one line, and the CSV export keeps the lines.
- **A transfer right in the ↓ panel and in the form at the side**: choose **Transfer**, and its
  fields — from, to, the amount, the date and time — stand where the fields of an expense stood;
  no separate window opens.
- The tutorial follows your starter set: someone with children is asked to write down something
  for them, someone working — a lunch, a set with loans — to add a loan; a set without
  subscriptions does not ask for one. Without a set the tutorial keeps its ten tasks for
  everyone.
- What's New in 1.5: six cards, once after the update.

### Changed

- The form at the side starts with the kinds of operation alone: the fields come once a kind is
  chosen, and after a save or **Clear** the form goes back to the kinds with the cursor in the
  quick line.
- After a save, the date and time of the form start over at now instead of keeping the last
  ones.
- ↑ and ↓ in Spending move the selection from row to row, also from a row the window selected
  itself (↓ from the entry line).

### Fixed

- The editor at the side of the Operations window no longer sends the window into a layout loop
  on a Mac with a mouse (scroll bars always shown): there the kind of operation and «For whom» are
  menus, so the editor fits its column. The loop was already possible in 1.4.0 in Russian.

- ⌘N in the form at the side puts the cursor in the quick line.
- In the Transactions window, the last rows no longer hide under the selection bar: scrolled to
  the end, the last row stands above it, with the earlier months hidden or shown.

## [1.4.0] — 2026-10-07

A guide and a tutorial, starter sets, Spending in the sidebar, paying for somebody else,
transfers from the entry line, and a quick line in the form at the side. The database schema
stays at 6: nothing is migrated.

### Added

- **A guide.** Seven cards at the first launch say what OhMyMoney is for; arrows and the trackpad
  turn them, **Skip** is always there. After an update, **What's New** shows one card per main
  change, once. Both come back from the Help menu: **Welcome to OhMyMoney** and **What's New**.
- **A tutorial.** Help → **Tutorial** opens OhMyMoney again on a set of practice data of its own; your
  database is not opened and not touched. A strip over the window says «Tutorial · 3 of 10»,
  lists the tasks — write «coffee 300», change a category, find last week's expense, add a
  subscription, count an account, see what is free to spend, transfer from the line, pay for
  somebody, open Spending, look at a currency chart — and frames the place to press. Each task
  notices by itself that it is done, from what the data now holds. **Leave the Tutorial** returns
  to your own data; Help → **Start the Tutorial Over** makes the practice data anew.
- Help → **Show Where to Click** labels the main controls of the screen with their shortcuts;
  Esc or a click closes it. Short tips appear once beside the control that matters; Settings →
  General → **Don't show tips** turns them off.
- **Starter sets.** On the first launch, and later from Settings → General → **Choose a Starter
  Set…**: student, working, freelance or self-employed, family, living alone, with a partner,
  with children — several at once — and whether you have loans and subscriptions, track cashback
  or want a safety cushion. A set adds categories, example limits and Overview tiles; it lists
  everything it will add before it does, never removes or renames anything, does not repeat a
  category that is already there, and its categories and limits come back out with one ⌘Z.
- A new database has **Salary** under **Work**, and **Taxes & fees** with vehicle tax, property
  tax and income tax. An existing database gets them only from a starter set.
- **Spending** in the sidebar (⌘4): every operation by day, newest first, with a search through
  the whole history by words, category or place. Overview now holds its tiles alone; ↓ in the
  empty entry line goes to the newest operation of Spending.
- **A grey «≈» for other currencies.** An expense in dollars shows «≈ 1,240 ₽» beside it in the
  default currency at the Bank of Russia's rate of its day — in Spending, in the ↓ panel and in
  the entry line before Return. A rate of an earlier day is marked «rate of 05.10». Once you type
  the rate or the account was charged in the default currency, the exact amount stands there.
  Display only: no stored amount changes.
- **Currency chart**, a new Overview tile: USD/RUB, EUR/RUB or a pair of your accounts'
  currencies over a week, a month or a year, with the rate now and its change. It reads the
  bank's daily tables the app keeps anyway; nothing else goes to the network.
- **Paying for somebody else.** «For whom» in the ↓ panel: **Me**, **Somebody**, **Half each**,
  **Evenly**. For somebody, **Pays back?** — «Yes — owes me» or «No — a gift, my treat». Under the
  fields it says what comes of it: «Your share is 600 ₽, Masha owes you 600 ₽.». The entry line
  reads «за машу», «пополам с машей», «угостил машу» with the name in any case. A row in the list
  says «for Masha», «half with Masha» or «split 3 ways». It is the parts paid for others you had
  before — what is owed waits in «Owed to me» — so nothing new is stored.
- **A transfer from the entry line.** «transfer 5000 sber tbank» or «перевод 5000 сбер т-банк»
  moves 5,000 from the first account to the second; «from» and «to» («с», «на») say otherwise,
  and an account is found by its own name, its bank's or its card's. The line shows «Transfer:
  Sber → T-Bank, 5,000 ₽» before Return. Two known accounts in one currency are transferred at
  once (one ⌘Z); different currencies or an account the line does not know open the transfer
  sheet with what was read. «перевод маше 500» stays an expense.
- **Expected income** can be deleted (its menu → **Delete…**, with a question and ⌘Z): the income
  already received stays, only the links go. An income that came in whole offers **Close fully**;
  a closed one waits in the block's **Archive** with **Restore**. Two expected incomes may have
  one name; menus tell them apart by amount and date.
- **A quick line in the form at the side.** With Settings → Input → «Detailed form at the
  right», the column begins with a line: Return shows «Will be written: coffee, 300 ₽,
  Groceries, Sber, today» with **Write** and **Change**; nothing is written by the first Return.
  Like the entry line, it files the category from your history.
  **Change** leaves it all in the fields below, Esc throws the line away. Under the line — the
  templates and past operations like it.
- In that form the kind of operation is a set of tiles, all always in sight — expense, income,
  money back, refund and transfer — two to a row; with an odd number the one you use most
  stretches across the column.

### Changed

- The pickers that offer accounts alone — a transfer, a count, moving a selection to another
  account — name them as every other list does: the bank alone for a bank with one account,
  «Bank › Account» for one with several.
- The Analytics and Reports windows cannot be made narrower than their content; showing the
  sidebar again takes its room from the content instead of widening the window.

### Fixed

- An account, card, place or event whose name holds «для» («Карта для поездок») is read whole by
  the entry line; the word no longer starts an unknown person.
- Merging two cards says how many operations and planned payments move to the card that stays,
  not only its cashback rules.
- The Transactions window could grow by the width of its sidebar when the inspector closed;
  its narrowest width is now 560 pt, and the filters come back only when there is room for them.
- A large write with the screen locked or asleep could leave the Transactions window laying
  itself out without end; the bar of a large write no longer holds a system spinner.
- A line with no word the category model had seen, such as «abc 250», was saved into the most
  frequent category without a question. The model may still suggest a category there; it no
  longer fills it in, and Return asks for one.

## [1.3.2] — 2026-10-07

### Fixed

- The entry line read a date with a far-off year: «dinner 2500-10-5» became a dinner on
  5 October 2500. A written year now has to be within the years a two-digit year means
  (today − 79 to today + 20); otherwise the text is no date.
- Currency names that are ordinary words — «драма», «лира», «rub», «buck» — were read as
  currencies wherever they stood. They are currencies only glued to the number or right after it;
  «RUB» in capitals still is anywhere.
- A template chip whose note held something like «100-250» entered no amount; the chip now puts
  its amount where the line reads it back.

## [1.3.1] — 2026-10-07

Fixes found by tests after 1.3.0, a tidy detailed form, merging cards and banks, and rates as
formulas.

### Added

- **Merging cards and banks.** A card can be merged with another card of its account
  (**Merge with…** in its menu): its operations, payments and cashback rules go to the kept card,
  which also takes its names. Banks can be merged too: every account of one goes under the other.
  One step of ⌘Z each; no money moves.
- An exchange rate can be typed as a formula, «95,5/1,02»; what it comes to shows beside the
  field.
- The tiles of Overview are reordered by dragging in Settings → Appearance; the arrows are gone.
- Cashback received before the bank's payout day counts, by default, for the month before:
  cashback for September that comes on 8 October is September's income.

### Changed

- The detailed form at the right of the window is laid out as one tidy column: a label above
  each field, every field the width of the column, buttons that wrap, and **Save** always at the
  bottom.
- Accounts merge only within one bank; to merge accounts of two banks, merge the banks first.
- Every card of Overview is titled by the name of its tile: «Spending forecast to the end of the
  month».

### Fixed

- **Record the difference** did nothing for a count whose difference operation, written by 1.1
  under an id of its own, had been deleted.
- The repair that gives every account a bank at each open failed, or made an empty extra bank,
  when one account was stored in two letter cases, or when an account lost its bank by hand
  after its bank had been renamed.
- A debt journal line edited so that it is no longer a payment kept the mark «no more payments
  this month».
- A debt with less left than its monthly payment asked for the whole monthly payment in the
  month's forecast and plan, in «Payments for 7 days», «Overdue payments» and **Payment…**; a due
  now asks for no more than is left of the debt.
- «No more payments this month» was offered for a payment that pays the debt off.
- A purchase for an event written for a later day lowered the budget the free sum holds back
  for the event, although its money is still on the accounts.
- A debt payment written for a later day took the debt out of the free sum and the debt's next
  payment out of the lists before its day.
- While the ↓ panel was open, a half-typed word could set a field and leave it set: «батон»
  passed through «бат» and was saved in baht, «магнитик» got the shop «Магнит» as its place,
  «авансом» made an expense income. What the line set while typing is now taken back when the
  line no longer says it; what you chose in the panel stays.
- A count beside a day-shaped price turned the price into a date: «croissants 2 pcs 3.10» was
  saved as 2 on 3 October.
- **Plan a payment** for an expense dated ahead could save the payment in a category of the app
  («Don't remember», «Loans»), which the payment form refuses.
- «Add another one?» did not ask after **Mark as paid** in Planning.

## [1.3.0] — 2026-10-07

Banks above accounts and cards, cashback rules that belong to the account, an entry that asks for
what it needs, debt dues closed by money, reconciliations that follow every recompute, and an
Overview whose tiles you choose.

### Upgrading

- The first launch of 1.3.0 migrates the database forward, once (schema 6). The update adds a
  table of banks and columns at the end of existing tables. Every account goes under a bank of
  its name — accounts with the same name under one bank. Cashback rules that every card of an
  account repeated move up to the account; rules on «Loans» are removed, as a debt payment
  never earns cashback. No other stored value changes.
- As before, the app first writes a checked copy `finance-<date and time>-before-migration.sqlite`
  into the backups folder and into `before-migration/` of the backup folder you chose; without a
  checked copy there is no migration.
- The update is one-way: 1.2.x opens neither a migrated database nor an archive written by
  1.3.0. To go back, restore the `-before-migration` copy in 1.2.x; what was entered in 1.3.0 is
  not in it.
- The transfer archive gets `banks.csv`, and `debt_entries.csv` and `payment_methods.csv` new
  columns at the end; `formatVersion` stays 1, the schema in the manifest is 6.

### Added

- **Banks.** Settings → Accounts → **New Bank…** makes a bank, an account and a card in one step
  of ⌘Z. An account is deleted without its bank, a card without its account. In every list a bank
  with one account and one card is just the bank («Sber · Sber» is gone), an account with two
  cards shows «Bank › Card», a bank with several accounts «Bank › Account». The entry line reads
  a bank's name as its first account.
- **Cashback on the account.** Rules belong to the account; a card keeps only what differs. A
  purchase without a card counts by the account's rules. Per account: rounding (whole rubles or
  kopecks; nearest, down or up), when the bank pays («right away» or «by the 10th of next
  month», with a warning when nothing came), and cashback paid as points to another account.
  Cashback no confirmation came for is grey «≈» and part of the estimated income.
- **Entry.** Return without a category does not save — choose one, or «Don't remember»; ↓ and ↑
  go through the suggestions, then the other categories. The ↓ panel reads the line as you type.
  ↓ in the line walks the list of operations from the newest; Tab opens the panel. «Add another
  one?» for the same amount within five minutes; a date after today asks whether to record it as
  is or plan a payment or an income. **Transfer…** in the panel; date and time of a transfer in
  one field. Return saves an edited operation. Settings → Entry offers a detailed form on the
  right of the window instead of the line.
- **Debts and payments.** A debt's due is closed by money: two halves close one due, a payment
  for two closes two, and an underpaid due stays as its remainder everywhere; «No more payments
  this month» closes a due paid in part. A new debt on its payment day asks whether this month's
  payment was made. Income named after a «They owe me» debt is money back; what a person returns
  over their parts goes toward their debt. Deleting the payment that closed a debt offers to
  reopen it. Overdue payments can be skipped, one or all. An expected income can come several
  times a month. A switch for the rest of event budgets in the free sum.
- **Reconciliation.** Every recompute (⌘R and the run at launch) brings the differences of later
  counts up to date; a difference that comes to zero is removed. The history of the
  reconciliation sheet offers **Record the difference** for a count saved without it, and shows
  a remembered answer «before the count?» with **Forget**. The forecast of an account's balance
  counts the losses of reconciliations and spending for others.
- **Accounts and groups.** «Total» in the sidebar opens a screen of every account in the summary.
  The screen of a group and of «Total» lists the payments, subscriptions and expected income of
  its accounts. An account's and a group's screen says when an operation was last added there.
- **Overview tiles.** Up to 12 tiles, chosen and ordered in Settings → Appearance from 18:
  month to date, top categories, good and bad, can save, forecasts of spending, income and the
  balance to the end of the month, limits, payments for 7 days, expected income, owed to me, I
  owe, event, last reconciliation, last operation, both together, worth a look, free money.
- **Windows as tabs.** Analytics, Transactions and Reports open as tabs of the main window, so
  in full screen they stay on its space.
- **About** has a link to support the author.

### Changed

- «By person» in Analytics and Reports no longer shows «No person»: spending that names nobody
  is mine and stays only in the base of the shares.
- «Top categories» leaves «Reconciliation» out.
- People and events in the archive are offered in the Transactions filter after the live ones,
  marked «(archived)».
- Name fields in Settings → Accounts are left-aligned, so a trailing space shows as you type.
- The account sheet of Settings → Accounts is no taller than the Settings window; its form
  scrolls inside.

### Fixed

- Transactions: selecting operations while the inspector was wider or narrower than its usual
  width — after a drag of its divider — could send the window into a layout loop that ended the
  app. The selection bar now floats over the table and no longer changes its layout.
- Moving a balance off an archived account dates the transfer after the latest count of the
  account it goes to, so it never makes up a difference there.

## [1.2.0] — 2026-09-28

Cards and cashback inside accounts, a first reconciliation that is the truth and later
differences that follow the books, and a free sum that no longer spends goal money or forgets an
overdue payment.

### Upgrading

- The first launch of 1.2.0 migrates the database forward, once (schema 5). The update only
  adds: tables for cards and cashback rules, and columns at the end of seven tables. Every live
  account of the kind card gets a card named like it, and the monthly plan of every goal that
  has one starts in the month of the update. No old value changes, and the update itself
  recomputes no reconciliation difference.
- As in 1.1.0, the app first writes a copy `finance-<date and time>-before-migration.sqlite`
  into the backups folder and checks it, and without a checked copy there is no migration. The
  copy now also goes to the backup folder you chose, into its subfolder `before-migration/`,
  which the copy rotation of no version ever touches.
- The update is one-way: 1.1.x opens neither a migrated database nor an archive written by
  1.2.0. To go back, restore the `-before-migration` copy in 1.1.x; what was entered in 1.2.0 is
  not in it.
- Right after the first open, 1.2.0 brings the differences of later reconciliations up to date
  with the operations entered into their windows afterwards, so the «Reconciliation» figures of
  past months in Analytics may change. A difference operation whose amount was retyped by hand
  goes back to the difference.
- A «Reconciliation» income written by a first real count — a count after nothing but the zero
  balances 1.1 wrote for empty fields in **Set Up Your Accounts**, or the first one-total count
  of 1.0.0 — stays exactly as it was, and ignores operations entered into its window, until you
  choose on the **Last reconciliation** card in Overview: **This was the first count — make it
  the starting point** (the income goes, the balance stays; ⌘Z brings it back) or **It is a real
  difference**. The next count of an account 1.1 set up with an empty field is its starting
  point by default.
- 1.1 took a due date that passed unpaid before a reconciliation as paid inside it. 1.2.0 counts
  such a due date as money not yet gone and asks about it at launch: **Taken before the
  reconciliation** closes it when the bank had already taken the money.
- A stored amount formula that the new reading of «1,500k» no longer turns into its amount loses
  the formula; the amount stays.

### Added

- **Cards inside an account.** An account can hold physical and virtual cards. The money and
  the balance stay with the account; a card says what paid. A new account of the kind card or
  account gets a card named like it. Cards are added, renamed, archived, brought back and — while
  nothing names them — deleted on the account screen and in Settings → Accounts, where each
  account lists its cards. The entry line knows a card by its name and its other names — «coffee
  350 black» goes to that card and its account — and the ↓ panel lists each account's cards under
  it; a place brings the card that paid there last, and a refund the card of its purchase. The
  Account column of Transactions shows «Bank · Black», and its filter takes an account with all
  its cards, or one card. Scheduled payments and **Mark as paid** can name a card too, and
  merging accounts moves their cards.
- **Cashback.** Rules on a card, or on an account without cards: «category, subcategory or
  everything else — N %», **always** or **only in a month** — for the bank's categories of that
  month (**Same as Last Month** copies them). A month rule beats an always rule, a subcategory
  beats its category, and «Everything else» applies when nothing else does; a percent keeps up
  to four decimals. The ↓ panel of a purchase shows the cashback to expect («≈ 35.00») and the
  rule that gives it; type an exact amount or a percent over it for this operation, and
  **Remember** turns the percent into a rule — always, or only this month — in a step of undo of
  its own. Expected cashback is an expectation and never income; received cashback is income in
  the cashback category, as before. The two stand side by side: on the account screen for this
  month, and in Analytics — **Turnover and cashback**, card by card, and the new **Cashback by
  month**.
- **Payments and Subscriptions on the account screen**: the scheduled payments paid from the
  account or from its cards, each opening for editing, and **Add Payment…**.
- **The end-of-month balance forecast.** The account screen forecasts each currency's balance at
  the end of the month — the balance now, what is already entered for later days, expected
  income, unpaid payments and debt payments, and day-to-day spending by the account's share —
  with an interval. Analytics → Forecast lists every account's balance at the end of the month,
  the accounts out of the summary apart.
- An expected income can name the account the money comes to («To account»); left empty, it is
  the account of the last income received for it, else the main one.
- **Overdue payments.** At every launch, while a scheduled payment or a debt has an unpaid due
  date in the past, Reminders open with **Overdue payments**: **Mark as paid** records it,
  **Taken before the reconciliation** — offered when the account was reconciled after the due
  date — closes it without an operation and without taking the money off twice, and **Later**
  asks again at the next launch. Until then the free sum counts that money as not yet gone, and
  **Review…** under it opens the list.
- **A scheduled payment can belong to an event.** Its due dates up to the event's end are part
  of the event's budget, so the free sum takes them off once, and the operation that pays it
  carries the event.
- **Foreign-currency goals** can be valued at the rates of the contributions instead of today's
  rate (Settings → Planning).
- **Deleting a debt or a credit** (**Delete…** on its row). It leaves Debts, the reminders, the
  free sum, the forecast and the entry line; the operations that paid it stay and count as they
  did, and the money of its journal stays in the balances. The confirmation says what stays, and
  ⌘Z brings it back.
- **Settings → Entry**: the order of the ↓ panel's fields — drag a field up or down, **Reset**
  for the standard order. Tab follows it, the entry panel and the editor share it, and it
  travels in the transfer archive.
- Return saves from anywhere in the open ↓ panel, once per keystroke; in an open menu Return
  picks the item.
- `250x2` in the entry line multiplies, when the line holds no other amount; a size beside a
  price («board 20x30 1500») stays in the note.
- **Overview**: «Last entry» says when the last operation or transfer was written, and
  «Payments in 7 days» shows about how much a payment in another currency is in the default
  currency at today's rate («≈ 269 ₽»), or «no rate».
- A transfer has a time, not only a date; a time you chose is never asked about the
  reconciliation.
- **Don't ask again for this reconciliation** in every question «Was this before the
  reconciliation?» — of the entry line, the editor, transfers and payments: the answer is used
  silently until the account is reconciled again.
- Negative balances — what a credit card owes the bank — can be typed with a minus wherever a
  balance is typed, and count as negative money in the total and the free sum. **Transfer the
  Balance…** of a card below zero covers the debt from the main account.
- «Worth a second look» offers to move the money 1.1 left on archived accounts, and says «Spent
  a goal's money? Press «Withdraw»» when the goals hold more than the accounts in the summary.

### Changed

- **The first reconciliation of an account and currency is its starting point, never income
  or spending.** Operations dated before it are history: they count in their months and do not
  move the balance. This also holds for the first real count after a zero balance that 1.1 wrote
  for an empty field: in the reconciliation sheet such a row shows **Starting point** switched
  on, with both outcomes in exact money — untick it only if that zero was real; a row left empty
  stays unreconciled.
- **Later reconciliation differences are live.** Add, edit or delete an operation or a transfer
  dated inside a count's window — or let the bank's final rate reprice a foreign purchase there,
  or record money back into it — and its «Reconciliation» difference follows in the same step of
  undo: a purchase entered afterwards makes a missing difference smaller, an income entered
  afterwards makes an extra one smaller, at zero the difference operation goes, and a change of
  sign turns income into spending. «Income by source» no longer shows the same money twice. ⌘Z
  brings a difference back as you left it — its category, comment and rating. The money, day,
  account and debt of a difference operation cannot be edited, it never moves into «Goals» or a
  category of the app, even in a bulk change, and deleting it keeps the count without recording
  its difference.
- The reconciliation sheet saves with a single **Save** when nothing differs; its history says
  which differences were saved without an operation and where starting balances came from.
- An operation dated on a day with several reconciliations of its account is asked about each
  of them in turn.
- An empty «Balance now» in **Set Up Your Accounts** or for a new account means «don't know»: no
  zero balance is written, the account stays unreconciled, and its first count becomes the
  starting point. A typed 0 is 0.
- **Merging accounts is no longer a reconciliation.** The merged account keeps the moment of its
  own latest count, operations after it move money, and the merge pays no due date. The merge
  sheet shows what the merged account holds now.
- **An archived account stays at zero.** An edit or a deletion that would leave money on it, and
  archiving an account that still holds money, ask which live account takes the money and record
  a transfer now, in the same step of undo. Changes that move no money are always allowed — the
  note of such an account's transfer too.
- **Set Up Your Accounts** names the account whose other name clashes with a name. An account
  can no longer be named like a card of another account.
- **The free sum.** «Can spend now» is the money on the accounts in the summary minus what is
  already put into goals (while «Goal money sits on accounts in the summary» is on): goal money
  is no longer spendable. The grey line takes off the part of the goal plans not yet paid in, and
  a contribution over this month's plan counts towards the following months; the goal form says
  the month its plan starts from. An unpaid overdue due date is taken off even when it falls
  before the account's reconciliation; one on the day of the reconciliation waits until it is
  paid, and **Mark as paid** of a due date before a later reconciliation asks whether the money
  left before the count — for a loan as for a scheduled payment.
- A payment closes the earliest unpaid due date — of a debt, and of a scheduled payment within
  its window; **Something else** excludes an operation from every due date of the payment. The
  Debts card marks a payment that is overdue, and **Payment…** is dated now.
- A scheduled payment on an archived account is taken from the main account and says «the
  account is archived — move the payment to another one».
- The first month of accounting no longer counts in the income median when it did not start on
  the 1st.
- The hint of «Keep back the monthly goal plans in «Free to spend»» says what it does: planned
  contributions not yet made by the chosen date are not free money.
- **Money back.** Money returned over what is left of a debt owed to me closes the debt, and the
  rest is income in «Surcharges» — from the entry line, the money-back sheets and the debt's
  **Payment…** alike. Every surplus of money back is income, except fractions of a kopeck. Both
  money-back sheets ask the currency the money came in and the account it came to; for another
  currency they show the rate the part actually cost you, and changing it reprices the purchase.
  When the bank has not published the day's rate yet, the part-by-part sheet asks for the rate
  instead of guessing it. A debt kept in another currency is repaid at a rate of its own. After a
  Bank of Russia refinement, a part the money covers is closed and any surplus is income.
  Recording money back is one step of undo instead of clearing the history.
- Editing a purchase's rate or amount rewrites the rubles of its refunds. A refund's amount
  without a currency code is read in the currency of the chosen purchase, on any screen.
- «Possible duplicate» compares the purchases' own checks, without refunds; a purchase refunded
  in full is never a duplicate.
- «1,500k» is 1,500: a comma before k is a decimal point.
- An impossible date in the line — «31.09», «29.02» of a common year — is refused with the
  reason: «31.09 — there is no such date».
- When the line does not tell the category or the subcategory, Enter opens the ↓ panel on that
  field and marks it instead of saving; the next Return saves as it stands.
- Overview lists each day's operations and transfers in one list by time, newest first; the
  symbol of each row tells its kind, and VoiceOver reads it.
- A place, a person or an event in the archive is no longer offered in entry and the pickers but
  stays in its operations, Analytics and Reports; an archived place also stays in the
  Transactions filter, after the live ones. A place in use can be archived too, and Settings →
  Reference books says what the archive does.
- A new goal with the name of an archived one is not saved: **Bring back** the old one or
  **Delete the old one…** — its contributions stay spending, its subcategory goes to the archive,
  and ⌘Z takes it back. An archived goal can also be deleted from its row in Planning.
- No limit can be set on «Reconciliation» or anything under it; a limit set there in 1.1 still
  counts and can be deleted.
- A transfer fee whose «Fees» sits under an archived parent brings the parent back with it, in
  the same step of undo, and the transfer sheet says when «Fees» is coming back from the archive.
- The report grouped by account is saved as `…-by-account.csv`.
- VoiceOver says whose «…» menu it is on every row of Accounts and Templates.
- The old one-total reconciliation of 1.0.0 is signed «one total, before accounts» on the «Last
  reconciliation» card.
- Undoing a deletion gives the operation back the time it was last changed, so the last manual
  rating of a description stays the one you gave last; undoing the deletion of money back no
  longer marks the purchases it had closed as just changed.
- The average receipt of a place is net of refunds.
- **Data formats.** The export and the transfer archive carry 23 files: `cards` and
  `cashback_rules` join the list, and new columns are appended at the end of `transactions`,
  `scheduled_payments`, `expected_income`, `goals`, `debts`, `reconciliations` and
  `reconciliation_balances`. Archives carry `schemaVersion` 5; `formatVersion` stays 1, and
  `settings.json` also carries the order of the ↓ panel's fields. The README appendix describes
  cards, cashback rules and live reconciliations.

### Fixed

- «Bad» could not be given to an expense while creating it: the quality was the one field of
  the ↓ panel that the keyboard could not set, and a category the model filled in gave the
  operation no quality — a fine filed under «Fines» was saved as «Neutral». The quality is now a
  menu like every other field, and it follows the category the model chose.
- An event could not last one day (26.09–26.09) or two; the end only has to be on or after the
  start, and the date fields always show the event's own days.
- A purchase on credit made on its payment day owed its first payment that same day, a month
  before the instalments start; its first payment is now due a month after the purchase.
- `make migration-dry-run` said only «NSError» when it could not read the file; it now prints
  the error's domain and code, never a path, and says when Full Disk Access for Terminal is the
  likely cause.

### Known limitations

- The first open of 1.2.0 recomputes the differences of later reconciliations whose windows got
  operations entered afterwards, so «Reconciliation» figures of past months may change; an old
  first-count income stays in «Income by source» until you choose on the «Last reconciliation»
  card.
- A loan entered with its original start date but without its earlier payments has an unpaid
  due date for every month before them, and each launch asks about them; **Taken before the
  reconciliation** closes those that fall before a reconciliation of the account.
- Merges made in 1.1 keep their anchor at the merge moment, so **Taken before the
  reconciliation** and «before the reconciliation?» of such an account read the merge moment.
- Money returned over the parts while the same person also owes on a debt is income in
  «Surcharges»; it does not go towards the debt — record that as a debt payment yourself.
- Only money back is split between a debt owed to me and «Surcharges»; an income that names such
  a debt still repays it with its whole amount, as in 1.1.
- Qualities that 1.1 saved without the category the model chose are not repaired; re-rate them
  in Settings → Categories or with a bulk change.
- The day-to-day pace of the account forecast leaves out reconciliation losses and parts paid
  for others, so it is optimistic for cash.
- Money repaid on a deleted «Owed to me» debt is income.
- Adding a second card to an account moves the expected cashback of its earlier operations that
  name no card from the first card's rules to the account's own.

### Internal

- The database's readers are opened again after a migration, so a read right after the update
  sees the columns it added.
- `make sample` and `make demo` show what is new: cards and a virtual one, cashback rules of
  both kinds with a typed amount, a hotel inside a New Year budget, a goal paid ahead of its
  plan, an expected salary on an account, an archived place, a one-day event, a credit card
  below zero and a later count whose difference follows an operation entered after it; the demo
  also has one overdue payment.
- `make test-core`, `make test-db` and `make bench` take `SPM_SCRATCH=<folder>` for a SwiftPM
  build folder of their own; `make migration-dry-run` expects the cards the update gives the
  card accounts.

## [1.1.2] — 2026-09-26

Fixes to 1.1.1. The database schema and the transfer-archive format stay as 1.1.0 left them.

### Fixed

- A change made outside operations — the default currency, the currencies switched on or off,
  a Planning setting, «This is normal» on an anomaly, pinning or archiving a template — got no
  backup of its own: closing the app right after it left the newest copy without that change.
  Every change written to the database now schedules a backup.
- An account's turnover counted a refund taken back to another account in the refund's month,
  as a negative figure on that account; it now follows the purchase, like the other figures.
- «Places» and «Events» of the refund's month listed the purchase's place or event with 0 ₽;
  a refund tied to a purchase now counts only where the purchase does.
- The category model learned a purchase twice when it had a refund tied to it.
- The counters of «Model quality» were written without thousands separators («12345»).
- VoiceOver: the pin of a pinned template now says it unpins, and the «…» menu of every
  category row says whose menu it is.

## [1.1.1] — 2026-09-26

Fixes to 1.1.0. The database schema and the transfer-archive format stay as 1.1.0 left them:
the first launch migrates nothing.

### Changed

- Moments are written to the database cut down to the millisecond instead of rounded to the
  nearest one, in the same text form. What 1.1.0 wrote is kept as it is.
- A copy made before an update, a restore or an import, or a damaged file set aside, never
  takes the name of another: when the name of that second is taken, it gets the next free one.

### Fixed

- An operation, a transfer or a reconciliation entered a moment ago could be missing from a
  balance for a moment: moments are now never stored later than they happened.
- The copy made before the update could be replaced by another copy made in the same second.
- Two copies made before a restore or an import within one second replaced each other.
- Restoring the older of two copies made before the update wrote a third copy of the same data.
- A second **Restore from a Copy** in the window that says the database did not open failed
  when it came within the same second as the first.
- Deleting a transfer of an archived account created money in the total; such a transfer now
  stays until the account is brought back: its sheet refuses it, and a deletion in Transactions
  or Overview leaves it out, deletes the rest and says which transfer stays and why.
- Deleting a selection that included a transfer whose fee had been refunded deleted nothing and
  only said it could not delete, and a transfer whose fee had been closed by money back was
  deleted with that fee; both transfers now stay, with the words of their own sheet, and the
  rest of the selection is deleted.
- An account with money on it could be deleted, and its money left the total; deleting it is
  refused now, and the refusal says what can be done: transfer the balance to another account
  and archive this one — **Transfer the Balance…** is offered beside it — or reconcile it to
  zero without recording the difference and then delete it.
- A transfer fee could create a second «Fees» category after the first was archived; the
  archived one comes back instead, in the same step of undo.
- **Yes, Before the Count** moved a transfer already dated before the count to a second before
  it; the transfer keeps its own time now, as an operation does.
- A template chip saved its amount in the currency of the account whose screen was open, or of
  the account picked in the ↓ panel: a «coffee 250 ₽» chip on a tenge account saved 250 ₸.
- The preview above the entry line could name a currency other than the one the operation was
  saved in; the preview, the chips and saving now take the currency by one rule.
- Money back in another currency than the parts it closed left the surplus a fraction of a
  kopeck off (250.0020 ₽ instead of 250.00 ₽), and closed the part the money ran out on for a
  fraction of a kopeck more than the account received. The surplus is now exactly the rubles
  the parts did not take, at the rate the money came at.
- In **Set Up Your Accounts**, an account named like an archived one was told to bring the
  archived one back in Settings, which Settings refuses while a live account has that name; an
  account already in the database is now asked for another name.

### Internal

- CI runs its later steps after a failed test too, and `make check-ci` fails on a condition that
  reads a step no step of its job declares. A release checks its build number against the
  published feed, and `make release-check` checks a published release — or a candidate, before
  it is published — from the outside.

## [1.1.0] — 2026-09-26

Accounts: what you have now, where it is and in which currency — and the free sum counted from
that money instead of from a single total.

### Upgrading

- The first launch of 1.1.0 migrates the database forward, once. The update only adds tables
  and columns and fills the new ones from what is there: nothing is deleted or overwritten.
  Every payment method becomes an account, every operation keeps its own, and operations that
  had none go to the main account.
- Before it migrates, the app writes a copy `finance-<date and time>-before-migration.sqlite`
  into the backups folder and checks it: the copy opens, passes `integrity_check`, and has as
  many rows in every table as the database. This copy is never pruned — the 50/90 rule of the
  backups leaves it alone and does not count it. Without a checked copy there is no migration:
  the app says why and leaves the database as it was. The migration and the steps that fill the
  new columns run in one transaction, so a failure leaves the database exactly as 1.0.0 had it;
  the next attempt uses the same copy.
- 1.0.0 cannot open a migrated database: it refuses a schema newer than its own. To go back to
  1.0.0, restore the `-before-migration` copy in it — 1.0.0 offers the copies in the window that
  says the database did not open — or put it in place by hand as the README describes. What was
  entered in 1.1.0 is not in that copy.
- After the update the app offers to set up the accounts once (see **Set Up Your Accounts**
  below).
- A transfer archive written by 1.0.0 opens in 1.1.0 and is migrated the same way. An archive
  written by 1.1.0 carries schema 4, and 1.0.0 refuses it.

### Added

- **Accounts.** Payment methods are accounts now: card, cash, account or other. An account
  holds one or more currencies — the first is its main one — and its balance is kept for each
  currency apart. There is always exactly one main account, first in every list and menu; the
  others go alphabetically or in the order you drag them into, and **Sort Alphabetically**
  brings the alphabet back. Accounts can be renamed, merged, archived and brought back, and
  deleted when nothing refers to them.
- **Account groups**, such as «Russia» and «Kazakhstan». A group can be left out of the
  summary (**Count in the overall summary** off): its money is then shown apart, with its own
  total, and stays out of the total, the free sum and Planning, while its income and spending
  still count everywhere — Overview, Analytics, Reports, limits, the forecast.
- **Accounts in the sidebar.** Under the three sections, «Accounts» lists the groups with their
  totals and the accounts with their balances; a foreign currency also shows its rubles.
  An account opens a screen of its own — the balance in every currency, its operations and
  transfers by day, **Transfer**, **Reconcile** and **Edit** — and a group shows its total and
  the history of its accounts. While an account's screen is open, a new operation goes to that
  account.
- **Transfers** between accounts, and between the currencies of one account (an exchange):
  the amount sent and the amount received as the bank shows them, with the rate they imply, and
  an optional fee recorded as an expense of its own. A transfer is a row of its own with ⇄ in
  the day lists, is neither income nor spending, and takes one step of undo.
- **What the account was charged.** An operation in a currency the account does not hold is
  charged in the account's main currency: the ↓ panel prefills the charge at the Bank of
  Russia's rates, and you can type the figure from the statement. Every operation has an
  account — the one typed or picked, otherwise the place's last one, otherwise the main one.
- **Set Up Your Accounts** on the first launch, and once after the update: quick picks of
  Russian and Kazakh banks, cash and any other name, the payment methods the database already
  has, and for each account its currencies, its group and how much is on it now. Those amounts
  are the first reconciliation. **Later** keeps the accounts as they are, the main one included
  — only a database with no account at all gets a «Main account» — and a card in Overview leads
  back to the setup.
- **Reconciliation by account and currency.** One sheet lists every account in every
  currency with the expected balance filled in; you change only the rows that differ. The
  first count of an account and currency is the starting point and compares nothing; later
  ones show the difference in that currency and can record it on that account. A move of the
  exchange rate is never a difference. An operation dated on the day of the latest count and
  entered after it asks whether it happened before the count.
- **Refunds tied to purchases.** A purchase refund is picked from recent purchases that still
  have something left to refund — the whole amount or part of it, one part of a split receipt —
  and counts in the purchase's day and month, as if the purchase had been cheaper, while the
  money reaches the account on the refund's own day. A purchase refunded in full comes to
  exactly zero. A refund without a purchase is still possible.
- **Money back in part.** Say who gives back how much: that person's oldest parts close first,
  a part covered only partly stays open with what is left, and anything above what was owed is
  income in «Surcharges», as before. A short confirmation says what closes and what stays owed;
  the part-by-part sheet is one click away, and a remainder can be written off.
  The entry line takes «money back 1700 from Anya».
- **Default currency** in Settings → Currencies: the currency of everything new — the entry
  line, templates, scheduled payments, expected income, debts, goals, money back. A currency
  typed in the line comes first, then the chosen account's. Totals, limits and reports stay in
  rubles.
- **Goals in any currency.** Progress is counted in the goal's currency; a contribution in
  another currency counts at the rate of its own day.
- **Limits running out.** Planning shows the first limits in one order — over, then close,
  then by the share spent — as many as Settings → Planning says (five by default, or all), and
  **All limits (N)…** opens the rest; the Overview card uses the same order. Click an amount to
  change it in place. Settings → Categories has a limit field in every row that can take one.
- **References.** People, places, accounts and events that nothing refers to can be deleted,
  several at a time; one in use can be merged into another or archived. Every archive —
  references, categories, goals, templates, account groups — can be shown, and its rows brought
  back. Adding an archived name brings it back instead of making a second one. Aliases are
  «Other names», edited as a list.
- **Planning.** A planned one-off expense is a scheduled payment of frequency «Once»: it is
  reminded, counted in the seven-day card, what the cards have to hold and the forecast, and
  paid off with an operation. Event budgets are set right in the Events block. The money
  somebody gives back for a payment made for them can be in another currency; the card shows
  both amounts.

### Changed

- **The free sum starts from the money you have now**: the balances of the accounts in the
  summary, each from its latest reconciliation plus every real movement since, in rubles at
  today's rate. A grey line below subtracts what is still ahead until a date you choose (the
  end of the month by default, up to twelve months ahead): scheduled payments and
  subscriptions not yet paid, what is due on the debts you owe, the money already put into
  goals and the rest of the goal plans, and what is left of event budgets. The daily figure is
  counted from that line. Expected income is shown as still expected and never added. Without
  a reconciliation the block asks for the first one. **Goal money sits on accounts in the
  summary** in Settings → Planning keeps goal savings from being subtracted when that money is
  on an account outside the summary.
- **Fields follow the kind of operation.** Income has no «for whom», place, event, «paid for
  someone» or «on credit»; its account is «To account», an expense's «From account». What 1.0.0
  stored in those fields of income stays in the database and is ignored.
- **«Payment method» is «Account»** everywhere: the ↓ panel, the editor, Transactions,
  Planning, Debts, Analytics («Accounts»), Reports and Settings. The CSV columns keep their
  names.
- **Updates.** The toolbar button and the View-menu item are now **Check for Updates…**: when
  there is no new version Sparkle says so and the app keeps running instead of restarting.
- **Restarting** after a language change, a backup restore or an archive import no longer
  leaves a second icon in the Dock: the new copy opens only after the old one has quit.
- **Appearance.** The accent colours are a row of colour circles. Switching the theme back to
  «System» now changes every window, including Settings. The Settings window can be resized.
- **Categories.** The list is flat, with no header sticking to the top while scrolling; system
  categories can be renamed.
- **Scheduled payments.** One frequency menu (weekly, every 2 weeks, monthly, every 2 months,
  quarterly, every half year, yearly, once, other…), «On the last day of the month» for
  payments, expected income and the debt payment day.
- **Wording.** «Для кого» is «На кого» in Russian; the person who gives money back is «От кого».
- **Numbers.** Every number is written the same way in both languages: comma for thousands, dot
  for the fraction — «1,234.56 ₽», «33.3 %». Typed amounts follow one rule: «1,500» is one
  thousand five hundred, «1500,5» and «1.5» have a fraction; rates keep reading «83,125» as
  83.125. Amount fields rewrite what was typed into that form when you leave them.
- **Data formats.** The export writes 21 CSV files: `account_groups`, `transfers` and
  `reconciliation_balances` join the list, and new columns are appended at the end of
  `transactions`, `transaction_parts`, `payment_methods`, `templates`, `goals`, `debt_entries`
  and `reconciliations`. Archives carry `schemaVersion` 4; `formatVersion` stays 1. The README
  appendix describes accounts, reconciliations and the keys in `external_id`.
- **README** is in Russian.
- For building from source: `make demo` opens the Debug build on a year of demo data drawn
  from a new random seed each time — accounts in several currencies and a group outside the
  summary, transfers with fees in rubles and in dollars, currency exchanges, counts, an account
  merged into another and kept in the archive, refunds tied to purchases, money partly given
  back, a payment due once, a goal in dollars, event budgets. It prints the seed:
  `make demo SEED=<n>` makes the same data again on the same day and in the same interface
  language.

### Fixed

- A scheduled payment paid with an ordinary operation instead of «Mark as paid» was counted
  twice — in the free sum, what the cards have to hold, the reminders and the forecast. A
  matching expense (same category and currency, within 10 % and five days) now counts as the
  payment; you can link it for good or say it is something else.
- Archiving or merging the default payment method could leave none.
- «Buy on credit» could be set on income or a refund and opened an instalment debt.
- Editing a payment due on the 31st moved it to the 30th for good when its next date fell on a
  shorter month.
- The currency caption of a payment method in Settings showed an internal key.
- A number too long to hold was silently read as zero; it is refused now.
- A template chip wrote its amount as «1500.5».

## [1.0.0] — 2026-09-25

The first public version.

### Added

- **Entry.** One line with expressions, in English and Russian at once; the ↓ panel with every
  field; split receipts; paying for somebody else and getting it back; refunds; buying on
  credit; templates; ten currencies at the Bank of Russia's rates; editing and deleting with
  one step of undo.
- **Planning.** Scheduled payments and subscriptions, including those paid for others and what
  each card has to hold; expected income; limits by category, by bad spending and by «for
  whom»; events with budgets; goals; how much is free to spend; suggestions; reconciliation.
- **Debts.** A journal of entries and groups, kinds, shares, payments by the accounting rules,
  transfers, totals and reminders.
- **Analytics and reports.** The month and the year, quality of spending, paid for others, for
  whom, places, events, payment methods, the forecast with its interval, the anomalies and the
  measured quality of the category model. Monthly and yearly tables with shares, exported as
  CSV that `pandas.read_csv` reads with no parameters.
- **Your data on your Mac.** SQLite in the app's container, backups with a mirror of your
  choosing, restore, one encrypted archive that carries everything to another Mac.
- **Two languages**, light and dark, Liquid Glass in the navigation and nowhere else.
- **Updates** through Sparkle in the Direct build, and nothing of the sort in the App Store
  build — which is checked by looking inside the bundle that was built.
- **No telemetry.** The journal carries no amounts, no names and no category titles.
- Appearance: light, dark or the system's, and the accent colour of the app, in Settings.
- Analytics: «By subscriptions for others» is computed from the charges «Mark as paid» wrote,
  instead of announcing a later milestone.
- A gear in the toolbar of the main window: a way into the settings that can be seen without
  opening a menu.
- Categories can be deleted, and the archived ones can be listed and brought back.
- Every picker in the entry panel, the edit sheet and the inspector ends with “Add…”, which
  opens a sheet to create a category, person, place, event or payment method and selects it;
  the “+” buttons beside place and person are gone.

### Changed

- «+» and ⌘N open the entry form instead of focusing a line that already had the focus.
- The difference a reconciliation records goes to a «Reconciliation» category of its own
  rather than into «Don't remember».
- A tag `vX.Y.Z` carries a release all the way: the workflow runs the tests of the application
  too, creates the GitHub release and puts the entry into the feed on Pages. The tag has to
  match `project.yml`, and the build number has to grow past the release before, or the
  release stops. A release published by hand on GitHub creates its tag as well; the workflow
  sees it published and builds nothing.
- A build from source is a separate app, `io.github.EvgenyBaulin.ohmymoney.debug`, with its own
  data, settings and backups and a «DEBUG» band on its icon; it never touches the copy in
  /Applications. `make install` installs the latest published release instead of a local
  build.

### Fixed

- The entry for the update feed carried its `length` twice — once from the script, once from
  Sparkle's `sign_update` — and a feed with it would not have parsed at all. Entries are now
  read back inside the feed before they are written.
- The window of Transactions no longer dies on a double click. The selection bar measured
  itself inside the column the popovers hang on, and the anchor of those popovers read that
  measurement, so every frame of the bar's entrance asked the column to lay out again.
