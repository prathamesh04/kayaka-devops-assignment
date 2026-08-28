const { Pool } = require("pg");
const { v4: uuidv4 } = require("uuid");
const logger = require("../logger");

const sampleItems = [
  { name: "Widget A", description: "A high-quality widget for everyday use" },
  { name: "Gadget B", description: "An innovative gadget for tech enthusiasts" },
  { name: "Tool C", description: "A durable tool for professional work" },
  { name: "Device D", description: "A portable device for on-the-go productivity" },
  { name: "Module E", description: "A modular component for system integration" },
];

async function seed() {
  const pool = new Pool({ connectionString: process.env.DATABASE_URL });
  try {
    for (const item of sampleItems) {
      await pool.query(
        "INSERT INTO items (id, name, description) VALUES ($1, $2, $3) ON CONFLICT (id) DO NOTHING",
        [uuidv4(), item.name, item.description]
      );
    }
    logger.info(`Seeded ${sampleItems.length} items`);
  } catch (err) {
    logger.error("Seed failed", { error: err.message });
    process.exit(1);
  } finally {
    await pool.end();
  }
}

if (require.main === module) {
  seed();
}

module.exports = { seed };
