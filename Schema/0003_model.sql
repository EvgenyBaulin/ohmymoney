-- The category model learns from corrections, and an anomaly can be hidden even when it
-- is not about one operation.

-- A correction is about one part, so the features can be rebuilt from the operation instead
-- of being duplicated here. `confidence_bp` is what the model was sure of when it offered
-- what it offered — kept so «Качество модели» can say how sure it is when it is wrong.
ALTER TABLE category_feedback ADD COLUMN part_id TEXT REFERENCES transaction_parts(id) ON DELETE CASCADE;
ALTER TABLE category_feedback ADD COLUMN confidence_bp INTEGER;
CREATE INDEX idx_category_feedback_part ON category_feedback(part_id);

-- Four of the seven anomaly rules are not about one operation but about a category and a
-- week, a person, an event or a subscription. The subject is the rest of the anomaly's
-- identity, so «это нормально» hides that anomaly and not every anomaly of its rule.
ALTER TABLE anomaly_dismissals ADD COLUMN subject TEXT;
CREATE UNIQUE INDEX idx_anomaly_dismissals_key ON anomaly_dismissals(rule, COALESCE(subject, ''));
