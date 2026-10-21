-- Logical retained-content ledger includes canonical payload UTF-8, private notes,
-- and a conservative 1024 bytes per report for receipt/index metadata.
CREATE TABLE storage_usage (
  singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
  retained_bytes INTEGER NOT NULL DEFAULT 0 CHECK (retained_bytes BETWEEN 0 AND 104857600)
) STRICT;
INSERT INTO storage_usage(singleton) VALUES (1);

CREATE TABLE daily_global (
  day TEXT PRIMARY KEY,
  accepted INTEGER NOT NULL CHECK (accepted BETWEEN 1 AND 100)
) STRICT;
CREATE TABLE daily_network (
  day TEXT NOT NULL,
  network_hash TEXT NOT NULL,
  accepted INTEGER NOT NULL CHECK (accepted BETWEEN 1 AND 10),
  PRIMARY KEY(day, network_hash)
) STRICT;

CREATE TABLE feedback (
  ticket_id TEXT PRIMARY KEY,
  submission_id TEXT NOT NULL UNIQUE,
  payload_hash TEXT NOT NULL,
  received_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('bug', 'feature')),
  title TEXT NOT NULL,
  message TEXT NOT NULL,
  app_json TEXT NOT NULL CHECK (json_valid(app_json)),
  diagnostics TEXT CHECK (diagnostics IS NULL OR json_valid(diagnostics)),
  status TEXT NOT NULL DEFAULT 'new' CHECK (status IN ('new','in_progress','resolved','declined')),
  notes TEXT NOT NULL DEFAULT '',
  updated_at TEXT NOT NULL,
  payload_bytes INTEGER NOT NULL CHECK (payload_bytes > 0),
  day TEXT,
  network_hash TEXT,
  CHECK (kind = 'bug' OR diagnostics IS NULL)
) STRICT;
CREATE INDEX feedback_recent ON feedback(received_at DESC, ticket_id DESC);
CREATE INDEX feedback_status_recent ON feedback(status, received_at DESC, ticket_id DESC);
CREATE INDEX feedback_expiration ON feedback(expires_at);

-- A single SQLite write transaction serializes quota checks and all mutations.
-- Duplicate submissions use INSERT ... SELECT ... WHERE NOT EXISTS so these
-- BEFORE INSERT triggers are never run for a replay, even at full quota/capacity.
CREATE TRIGGER feedback_admit BEFORE INSERT ON feedback BEGIN
  SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM storage_usage WHERE singleton=1)
    THEN RAISE(ABORT, 'FEEDBACK_INTAKE_UNAVAILABLE') END;
  SELECT CASE WHEN COALESCE((SELECT accepted FROM daily_global WHERE day=NEW.day),0) >= 100
    THEN RAISE(ABORT, 'FEEDBACK_RATE_LIMITED') END;
  SELECT CASE WHEN COALESCE((SELECT accepted FROM daily_network WHERE day=NEW.day AND network_hash=NEW.network_hash),0) >= 10
    THEN RAISE(ABORT, 'FEEDBACK_RATE_LIMITED') END;
  SELECT CASE WHEN (SELECT retained_bytes FROM storage_usage WHERE singleton=1) + NEW.payload_bytes + 1024 > 104857600
    THEN RAISE(ABORT, 'FEEDBACK_CAPACITY_REACHED') END;
END;
CREATE TRIGGER feedback_account AFTER INSERT ON feedback BEGIN
  INSERT INTO daily_global(day,accepted) VALUES(NEW.day,1)
    ON CONFLICT(day) DO UPDATE SET accepted=accepted+1;
  INSERT INTO daily_network(day,network_hash,accepted) VALUES(NEW.day,NEW.network_hash,1)
    ON CONFLICT(day,network_hash) DO UPDATE SET accepted=accepted+1;
  UPDATE storage_usage SET retained_bytes=retained_bytes+NEW.payload_bytes+1024 WHERE singleton=1;
  -- Admission-only values are removed in this same transaction, not retained
  -- with content; only the two-day quota table contains network pseudonyms.
  UPDATE feedback SET day=NULL, network_hash=NULL WHERE ticket_id=NEW.ticket_id;
END;
CREATE TRIGGER feedback_notes_capacity BEFORE UPDATE OF notes ON feedback BEGIN
  SELECT CASE WHEN (SELECT retained_bytes FROM storage_usage WHERE singleton=1)
    + length(CAST(NEW.notes AS BLOB))-length(CAST(OLD.notes AS BLOB)) > 104857600
    THEN RAISE(ABORT, 'FEEDBACK_CAPACITY_REACHED') END;
END;
CREATE TRIGGER feedback_notes_account AFTER UPDATE OF notes ON feedback BEGIN
  UPDATE storage_usage SET retained_bytes=retained_bytes
    + length(CAST(NEW.notes AS BLOB))-length(CAST(OLD.notes AS BLOB)) WHERE singleton=1;
END;
CREATE TRIGGER feedback_release AFTER DELETE ON feedback BEGIN
  UPDATE storage_usage SET retained_bytes=retained_bytes-OLD.payload_bytes-1024-length(CAST(OLD.notes AS BLOB)) WHERE singleton=1;
END;
