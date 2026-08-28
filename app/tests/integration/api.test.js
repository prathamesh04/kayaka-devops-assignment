import { describe, it, expect, beforeAll, afterAll } from "vitest";
import request from "supertest";
import pg from "pg";
import { createApp } from "../../src/app.js";
import { migrate } from "../../src/db/migrate.js";

const DATABASE_URL =
  process.env.TEST_DATABASE_URL || "postgresql://kayaka:postgres@localhost:5432/kayaka_test";

describe("API Integration Tests", () => {
  let app;
  let pool;

  beforeAll(async () => {
    pool = new pg.Pool({ connectionString: DATABASE_URL });
    app = createApp(pool);
    await migrate();
  });

  afterAll(async () => {
    if (pool) await pool.end();
  });

  it("GET /api/items should return items list", async () => {
    const res = await request(app).get("/api/items");
    expect(res.status).toBe(200);
    expect(res.body).toHaveProperty("items");
    expect(Array.isArray(res.body.items)).toBe(true);
  });

  it("POST /api/items should create an item", async () => {
    const res = await request(app)
      .post("/api/items")
      .send({ name: "Test Item", description: "Integration test" });
    expect(res.status).toBe(201);
    expect(res.body.name).toBe("Test Item");
    expect(res.body).toHaveProperty("id");
  });

  it("GET /api/items/:id should return the created item", async () => {
    const createRes = await request(app)
      .post("/api/items")
      .send({ name: "Fetch Test", description: "to be fetched" });
    const id = createRes.body.id;

    const res = await request(app).get(`/api/items/${id}`);
    expect(res.status).toBe(200);
    expect(res.body.name).toBe("Fetch Test");
  });

  it("PUT /api/items/:id should update the item", async () => {
    const createRes = await request(app)
      .post("/api/items")
      .send({ name: "Update Test", description: "original" });
    const id = createRes.body.id;

    const res = await request(app)
      .put(`/api/items/${id}`)
      .send({ name: "Updated Test" });
    expect(res.status).toBe(200);
    expect(res.body.name).toBe("Updated Test");
  });

  it("DELETE /api/items/:id should delete the item", async () => {
    const createRes = await request(app)
      .post("/api/items")
      .send({ name: "Delete Test", description: "to be deleted" });
    const id = createRes.body.id;

    const res = await request(app).delete(`/api/items/${id}`);
    expect(res.status).toBe(204);
  });

  it("GET /api/items/:id should return 404 for non-existent item", async () => {
    const res = await request(app).get("/api/items/00000000-0000-0000-0000-000000000000");
    expect(res.status).toBe(404);
  });
});