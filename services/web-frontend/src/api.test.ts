import { describe, expect, it, vi } from "vitest";
import { createApi } from "./api";
import { loadConfig } from "./config";

describe("loadConfig", () => {
  it("applies defaults and trims trailing slashes", () => {
    const config = loadConfig({ apiBaseUrl: "https://acme.api.example.com/", tenantId: "acme" });
    expect(config.apiBaseUrl).toBe("https://acme.api.example.com");
    expect(config.tenantName).toBe("ACME");
    expect(config.clientId).toBe("web");
  });

  it("works without any runtime config", () => {
    expect(loadConfig(undefined).apiBaseUrl).toBe("");
  });
});

describe("createApi", () => {
  it("calls Kong-style versioned paths with tenant, correlation and bearer headers", async () => {
    const fetchFn = vi.fn(async () => new Response("[]", { status: 200 }));
    const api = createApi(loadConfig({ apiBaseUrl: "https://api.example.com", tenantId: "acme" }), () => "tok", fetchFn);

    await api.listOrders();

    const [url, init] = fetchFn.mock.calls[0] as unknown as [string, RequestInit];
    const headers = new Headers(init.headers);
    expect(url).toBe("https://api.example.com/orders/v1/orders");
    expect(headers.get("X-Tenant-ID")).toBe("acme");
    expect(headers.get("Authorization")).toBe("Bearer tok");
    expect(headers.get("X-Correlation-ID")).toBeTruthy();
  });

  it("raises ApiError on failure", async () => {
    const fetchFn = vi.fn(async () => new Response("", { status: 503 }));
    const api = createApi(loadConfig({ tenantId: "acme" }), () => undefined, fetchFn);
    await expect(api.listProducts()).rejects.toMatchObject({ status: 503 });
  });
});
