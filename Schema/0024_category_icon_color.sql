-- The mark of a category in the list of operations: a symbol and a colour. Forward only.
--
-- Additive only, like 0004 to 0023: two new columns that start empty and no data step. No row is
-- inserted or updated, so every category the update finds reads exactly as it did, and an
-- operation of a category without a mark keeps the round mark of its kind (spending, income,
-- refund, transfer). No CHECK on an added column: adding one checks every other CHECK of the
-- table again, and the old rows leave these columns empty anyway.
--
-- The sync triggers of `categories` already write the key of a changed row to the outbox,
-- whatever column changed, so the new columns travel with the row and need no trigger of
-- their own. They are the owner's choice, so a conflict between two devices shows them.
--
-- Needs SQLite 3.37 or later, as 0004 to 0023 do.

-- The name of an SF Symbol from the short list the app offers (`CategoryIcon`), as text. A name
-- the app does not know — written by a newer build — is kept as it is and drawn as no mark.
-- NULL: no symbol of its own; a subcategory then follows its parent, a category the kind.
ALTER TABLE categories ADD COLUMN icon TEXT;

-- The colour of the mark, as a key of the app's own short list (`CategoryTone`: `accent`,
-- `tone1`…`tone5`, `neutral`), never a hex value: the colour has to follow the theme and
-- «Увеличить контраст». NULL: none of its own, same inheritance as `icon`.
ALTER TABLE categories ADD COLUMN color TEXT;
