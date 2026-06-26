-- Add trading metadata columns to markets table
ALTER TABLE markets ADD COLUMN condition_id TEXT DEFAULT '';
ALTER TABLE markets ADD COLUMN clob_token_ids TEXT DEFAULT '[]';
ALTER TABLE markets ADD COLUMN outcomes TEXT DEFAULT '[]';
ALTER TABLE markets ADD COLUMN neg_risk INTEGER DEFAULT 0;
ALTER TABLE markets ADD COLUMN min_tick_size TEXT DEFAULT '0.01';

INSERT OR IGNORE INTO schema_migrations(version) VALUES(5);
