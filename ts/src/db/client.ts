/** Bun:sqlite read-only client for dashboard / Telegram queries. */
import { Database } from "bun:sqlite";

let _db: Database | null = null;

export function getDB(): Database {
  if (_db) return _db;
  const path = Bun.env.DB_PATH ?? "./data/cex.db";
  const readonly = true;
  _db = new Database(path, { readonly, create: false });
  if (!readonly) {
    _db.run("PRAGMA journal_mode=WAL;");
  }
  _db.run("PRAGMA busy_timeout=3000;");
  return _db;
}

export function queryPositions() {
  return getDB()
    .query("SELECT * FROM positions WHERE status='open' ORDER BY created_at DESC LIMIT 100")
    .all();
}

export function queryOrders() {
  return getDB()
    .query("SELECT * FROM orders WHERE status NOT IN ('filled','cancelled','rejected') ORDER BY created_at DESC LIMIT 100")
    .all();
}

export function queryRecentLogs(limit = 200) {
  return getDB()
    .query("SELECT level, component, message, created_at FROM logs ORDER BY created_at DESC LIMIT ?")
    .all(limit);
}

export function queryConfig() {
  return getDB()
    .query("SELECT key, new_value, changed_at FROM config_changes ORDER BY changed_at DESC")
    .all();
}
