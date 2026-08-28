import { describe, it, expect } from "vitest";
import request from "supertest";
import { createApp } from "../../src/app.js";

function fakePool(overrides = {}) {
  const query = overrides.query || (() => { throw new Error("no query stub"); });
  return { query };
}

describe("Health endpoints", () => {
  it("GET /health should return healthy when DB is up", async () => {
    const app = createApp(fakePool({
      query: async () => ({ rows: [{ "?column?": 1 }] }),
    }));

    const res = await request(app).get("/health");
    expect(res.status).toBe(200);
    expect(res.body.status).toBe("healthy");
  });

  it("GET /health should return 503 when DB is down", async () => {
    const app = createApp(fakePool({
      query: async () => { throw new Error("Connection refused"); },
    }));

    const res = await request(app).get("/health");
    expect(res.status).toBe(503);
    expect(res.body.status).toBe("unhealthy");
  });
});

describe("Item validation", () => {
  it("POST /api/items should return 400 without name", async () => {
    const app = createApp(fakePool());
    const res = await request(app)
      .post("/api/items")
      .send({ description: "no name" });
    expect(res.status).toBe(400);
    expect(res.body.error).toBe("Name is required");
  });
});

describe("CRUD operations", () => {
  const rows = [{ id: "abc", name: "Widget", description: "desc" }];

  it("GET /api/items should list items", async () => {
    const app = createApp(fakePool({
      query: async () => ({ rows, rowCount: 1 }),
    }));
    const res = await request(app).get("/api/items");
    expect(res.status).toBe(200);
    expect(res.body.items).toEqual(rows);
  });

  it("POST /api/items should create an item", async () => {
    const app = createApp(fakePool({
      query: async () => ({ rows: [{ id: "x", name: "New", description: "" }] }),
    }));
    const res = await request(app)
      .post("/api/items")
      .send({ name: "New" });
    expect(res.status).toBe(201);
    expect(res.body.id).toBe("x");
  });

  it("GET /api/items/:id should return 404 for missing item", async () => {
    const app = createApp(fakePool({
      query: async () => ({ rows: [] }),
    }));
    const res = await request(app).get("/api/items/00000000-0000-0000-0000-000000000000");
    expect(res.status).toBe(404);
  });

  it("DELETE /api/items/:id should return 204", async () => {
    const app = createApp(fakePool({
      query: async () => ({ rows: [{ id: "x" }] }),
    }));
    const res = await request(app).delete("/api/items/x");
    expect(res.status).toBe(204);
  });

  it("GET /metrics should expose Prometheus metrics", async () => {
    const app = createApp(fakePool({
      query: async () => ({ rows: [{ "?column?": 1 }] }),
    }));
    const res = await request(app).get("/metrics");
    expect(res.status).toBe(200);
    expect(res.headers["content-type"]).toContain("text/plain");
    expect(res.text).toContain("kayaka_http_request_duration_seconds");
  });
});