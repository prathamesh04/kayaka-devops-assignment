require("dotenv").config();
const express = require("express");
const helmet = require("helmet");
const cors = require("cors");
const morgan = require("morgan");
const { register, collectDefaultMetrics, Counter, Histogram } = require("prom-client");
const { v4: uuidv4 } = require("uuid");
const logger = require("./logger");

let defaultMetricsCollected = false;

const httpRequestDuration = new Histogram({
  name: "kayaka_http_request_duration_seconds",
  help: "Duration of HTTP requests in seconds",
  labelNames: ["method", "route", "status_code"],
  buckets: [0.01, 0.05, 0.1, 0.5, 1, 2, 5],
});

const httpRequestTotal = new Counter({
  name: "kayaka_http_requests_total",
  help: "Total number of HTTP requests",
  labelNames: ["method", "route", "status_code"],
});

function createApp(pool) {
  const app = express();

  if (!defaultMetricsCollected) {
    collectDefaultMetrics({ prefix: "kayaka_" });
    defaultMetricsCollected = true;
  }

  app.use(helmet());
  app.use(cors());
  app.use(express.json());
  app.use(morgan("combined", {
    stream: { write: (msg) => logger.info(msg.trim()) },
  }));

  app.use((req, res, next) => {
    const start = Date.now();
    res.on("finish", () => {
      const duration = (Date.now() - start) / 1000;
      const route = req.route ? req.route.path : req.path;
      httpRequestDuration.labels(req.method, route, res.statusCode).observe(duration);
      httpRequestTotal.labels(req.method, route, res.statusCode).inc();
    });
    next();
  });

  app.get("/health", async (req, res) => {
    try {
      await pool.query("SELECT 1");
      res.json({ status: "healthy", timestamp: new Date().toISOString() });
    } catch (err) {
      logger.error("Health check failed", { error: err.message });
      res.status(503).json({ status: "unhealthy", error: "Database unreachable" });
    }
  });

  app.get("/ready", async (req, res) => {
    try {
      await pool.query("SELECT 1");
      res.json({ status: "ready" });
    } catch {
      res.status(503).json({ status: "not ready" });
    }
  });

  app.get("/metrics", async (req, res) => {
    try {
      res.set("Content-Type", register.contentType);
      res.end(await register.metrics());
    } catch (err) {
      res.status(500).end(err.message);
    }
  });

  app.get("/api/items", async (req, res) => {
    try {
      const result = await pool.query(
        "SELECT * FROM items ORDER BY created_at DESC LIMIT $1 OFFSET $2",
        [parseInt(req.query.limit) || 20, parseInt(req.query.offset) || 0]
      );
      res.json({ items: result.rows, total: result.rowCount });
    } catch (err) {
      logger.error("Failed to fetch items", { error: err.message });
      res.status(500).json({ error: "Internal server error" });
    }
  });

  app.get("/api/items/:id", async (req, res) => {
    try {
      const result = await pool.query("SELECT * FROM items WHERE id = $1", [req.params.id]);
      if (result.rows.length === 0) {
        return res.status(404).json({ error: "Item not found" });
      }
      res.json(result.rows[0]);
    } catch (err) {
      logger.error("Failed to fetch item", { error: err.message, id: req.params.id });
      res.status(500).json({ error: "Internal server error" });
    }
  });

  app.post("/api/items", async (req, res) => {
    const { name, description } = req.body;
    if (!name) {
      return res.status(400).json({ error: "Name is required" });
    }
    try {
      const id = uuidv4();
      const result = await pool.query(
        "INSERT INTO items (id, name, description) VALUES ($1, $2, $3) RETURNING *",
        [id, name, description || ""]
      );
      logger.info("Item created", { id, name });
      res.status(201).json(result.rows[0]);
    } catch (err) {
      logger.error("Failed to create item", { error: err.message });
      res.status(500).json({ error: "Internal server error" });
    }
  });

  app.put("/api/items/:id", async (req, res) => {
    const { name, description } = req.body;
    try {
      const result = await pool.query(
        "UPDATE items SET name = COALESCE($1, name), description = COALESCE($2, description) WHERE id = $3 RETURNING *",
        [name, description, req.params.id]
      );
      if (result.rows.length === 0) {
        return res.status(404).json({ error: "Item not found" });
      }
      res.json(result.rows[0]);
    } catch (err) {
      logger.error("Failed to update item", { error: err.message });
      res.status(500).json({ error: "Internal server error" });
    }
  });

  app.delete("/api/items/:id", async (req, res) => {
    try {
      const result = await pool.query("DELETE FROM items WHERE id = $1 RETURNING id", [req.params.id]);
      if (result.rows.length === 0) {
        return res.status(404).json({ error: "Item not found" });
      }
      res.status(204).end();
    } catch (err) {
      logger.error("Failed to delete item", { error: err.message });
      res.status(500).json({ error: "Internal server error" });
    }
  });

  app.use((err, req, res, _next) => {
    logger.error("Unhandled error", { error: err.message, stack: err.stack });
    res.status(500).json({ error: "Internal server error" });
  });

  return app;
}

module.exports = { createApp };