-- Place marks: the spots the owner marks on the map to be reminded, when near one, of the best
-- way to pay there. Forward only.
--
-- Additive only, like 0004 to 0030: one new table, no column added to an older table and no data
-- step. The table starts empty.
--
-- The table belongs to this device alone. It has no triggers of the exchange, so a mark never
-- enters the journal of changes; the starting set a new device is given and every copy made for
-- someone else have it emptied; the CSV export does not list it. The transfer archive and the
-- backups carry the whole file, as they do `identity_items`, so a restore brings the marks back.
--
-- Coordinates are whole numbers of 1e-7 degree (`*_e7`): latitude -900000000...900000000,
-- longitude -1800000000...1800000000. `radius_m` is the distance from the point at which the
-- phone announces the place, 50...1000 metres. `place_id` is the place of the books the mark
-- stands for and `category_id` what the owner buys there; both are plain ids (no foreign key:
-- the place or the category may be deleted without a word to the mark, which then simply reads
-- as having none). `enabled` 0/1: a mark switched off is kept but not watched.
--
-- Needs SQLite 3.37 or later, as 0004 to 0030 do.

CREATE TABLE place_marks (
  id           TEXT PRIMARY KEY,
  name         TEXT NOT NULL CHECK (length(trim(name)) > 0),
  latitude_e7  INTEGER NOT NULL CHECK (latitude_e7 BETWEEN -900000000 AND 900000000),
  longitude_e7 INTEGER NOT NULL CHECK (longitude_e7 BETWEEN -1800000000 AND 1800000000),
  radius_m     INTEGER NOT NULL DEFAULT 150 CHECK (radius_m BETWEEN 50 AND 1000),
  place_id     TEXT,
  category_id  TEXT,
  enabled      INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1))
);
