const { Pool } = require("pg");
const logger = require("../logger");

const migrations = [
  `CREATE TABLE IF NOT EXISTS items (
    id UUID PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    description TEXT DEFAULT '',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
  );`,
  `CREATE INDEX IF NOT EXISTS idx_items_created_at ON items(created_at DESC);`,
  `CREATE INDEX IF NOT EXISTS idx_items_name ON items(name);`,
];

async function migrate() {
  const pool = new Pool({ connectionString: process.env.DATABASE_URL });
  try {
    for (const sql of migrations) {
      await pool.query(sql);
      logger.info("Migration applied", { sql: sql.substring(0, 50) });
    }
    logger.info("All migrations completed successfully");
  } catch (err) {
    logger.error("Migration failed", { error: err.message });
    process.exit(1);
  } finally {
    await pool.end();
  }
}

if (require.main === module) {
  migrate();
}

module.exports = { migrate };
