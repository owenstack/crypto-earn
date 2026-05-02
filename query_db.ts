import { Database } from "bun:sqlite";

const path = process.env.DB_PATH ?? "./db/cex.sqlite3";
console.log(`Using database: ${path}`);
const db = new Database(path, { readonly: true });

const signalCount = db.query("SELECT count(*) as count FROM dry_run_signals").get() as { count: number };
console.log(`Dry run signals: ${signalCount.count}`);

const latestBalance = db.query("SELECT * FROM balance_snapshots ORDER BY snapshot_at DESC LIMIT 1").get();
console.log(`Latest balance snapshot:`, latestBalance);

const latestSignals = db.query("SELECT * FROM dry_run_signals ORDER BY timestamp DESC LIMIT 5").all();
console.log(`Latest 5 dry run signals:`, latestSignals);
