DELETE FROM runtime_config WHERE key = 'lp_max_position_usd';
INSERT OR IGNORE INTO schema_migrations(version) VALUES (17);
