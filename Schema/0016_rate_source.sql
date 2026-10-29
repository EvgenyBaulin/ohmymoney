-- The rates table learns a fifth source, `coingecko`, for the price of an own currency that is a
-- coin. Forward only.
--
-- SQLite cannot change a CHECK, so `rates` is rebuilt: a new table with the wider CHECK, every
-- row copied as it is (rowid included), the old table dropped, the new one renamed, the index made again. Nothing
-- refers to `rates` (no foreign key, no trigger, no view), so the rebuild touches no other table.
--
-- One step of data, on purpose and only in this copy: a database of the previous release stored
-- the price of a coin under the mark `cbr`, the only mark that is replaced by the next price. The
-- rows that carry it for a currency whose source is `coingecko` are re-marked `coingecko`. The
-- code of such a currency is never one the bank publishes, so no row of the bank is touched, and
-- the key (date, currency, source) cannot collide: a currency that was never `coingecko` before
-- has no row under that mark.
--
-- `transactions.rate_source` keeps its four marks. It is read by the rows that refer to
-- `transactions` (parts, links, journals), and dropping that table would delete them through
-- their foreign keys, which stay on during an update; an operation therefore stores `cbr` for a
-- price taken from the network (`RateSource.operationMark`).
--
-- Needs SQLite 3.37 or later, as 0004 to 0015 do.

CREATE TABLE rates_new (
  date          TEXT NOT NULL,
  currency      TEXT NOT NULL,
  -- Decimal string, exactly as published, with the nominal kept separately.
  rub_per_unit  TEXT NOT NULL,
  nominal       INTEGER NOT NULL DEFAULT 1,
  source        TEXT NOT NULL CHECK (source IN ('cbr', 'cbr_mirror', 'manual', 'import', 'coingecko')),
  fetched_at    TEXT,
  PRIMARY KEY (date, currency, source)
);

INSERT INTO rates_new (rowid, date, currency, rub_per_unit, nominal, source, fetched_at)
SELECT rowid, date, currency, rub_per_unit, nominal,
       CASE
         WHEN source = 'cbr'
              AND currency IN (SELECT code FROM custom_currencies WHERE rate_source = 'coingecko')
           THEN 'coingecko'
         ELSE source
       END,
       fetched_at
FROM rates
ORDER BY rowid;

DROP TABLE rates;
ALTER TABLE rates_new RENAME TO rates;
CREATE INDEX idx_rates_lookup ON rates(currency, date);
