-- Someone else's card: an account of money that is not the owner's. Forward only.
--
-- Additive only, like 0004 to 0021: three new columns that start empty, and no data step. No row
-- is inserted or updated, so every account the update finds reads exactly as it did: the owner's
-- own. No CHECK on an added column: adding one checks every other CHECK of the table again. No
-- foreign key either: a person or a category deleted (and brought back by ⌘Z) leaves the account
-- as it was, and a reference to one that is gone reads as none.
--
-- The `kind` of the table keeps its CHECK (`card`, `cash`, `account`, `other`): someone else's
-- card is a card, cash or an account like any other, marked by `borrowed`.
--
-- The sync triggers of `payment_methods` already write the key of a changed row to the outbox, so
-- the new columns travel with the row and need no trigger of their own.
--
-- Needs SQLite 3.37 or later, as 0004 to 0021 do.

-- `borrowed`: the money of the account is someone else's — a parent's card, a partner's, a
-- company card. Its spending is the owner's spending; its balance is not his money: it has none,
-- no count, no place in any total. 0 or NULL: the owner's own account; 1: someone else's.
ALTER TABLE payment_methods ADD COLUMN borrowed INTEGER;
-- Whose money it is: a person of the reference book (`people.id`); NULL: not said.
ALTER TABLE payment_methods ADD COLUMN borrowed_person_id TEXT;
-- The income category a transfer from the card to an account of the owner is written in
-- (`categories.id`); NULL: the default one.
ALTER TABLE payment_methods ADD COLUMN borrowed_income_category_id TEXT;
