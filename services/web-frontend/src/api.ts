import type { RuntimeConfig } from "./config";

export interface Product {
  id: string;
  sku: string;
  name: string;
  price: number;
  currency: string;
  stock: number;
}

export interface Order {
  id: string;
  customerId: string;
  status: string;
  currency: string;
  total: number;
  createdAt: string;
}

export class ApiError extends Error {
  constructor(
    public readonly status: number,
    message: string,
  ) {
    super(message);
  }
}

/**
 * Calls services through Kong: {apiBaseUrl}/{service}/{version}/... . X-Tenant-ID is informational only — Kong
 * overwrites it from the JWT `tenant` claim, which is the trust boundary.
 */
export function createApi(config: RuntimeConfig, getToken: () => string | undefined, fetchFn: typeof fetch = fetch) {
  async function request<T>(path: string, init: RequestInit = {}): Promise<T> {
    const headers = new Headers(init.headers);
    headers.set("Accept", "application/json");
    headers.set("X-Correlation-ID", crypto.randomUUID());
    if (config.tenantId) headers.set("X-Tenant-ID", config.tenantId);
    const token = getToken();
    if (token) headers.set("Authorization", `Bearer ${token}`);
    if (init.body) headers.set("Content-Type", "application/json");

    const response = await fetchFn(`${config.apiBaseUrl}${path}`, { ...init, headers });
    if (!response.ok) {
      throw new ApiError(response.status, `${init.method ?? "GET"} ${path} failed: ${response.status}`);
    }
    return (await response.json()) as T;
  }

  return {
    listProducts: () => request<Product[]>("/catalog/v1/products"),
    listOrders: () => request<Order[]>("/orders/v1/orders"),
    createOrder: (productId: string, quantity: number, currency: string, customerId: string) =>
      request<Order>("/orders/v1/orders", {
        method: "POST",
        body: JSON.stringify({ customerId, currency, items: [{ productId, quantity }] }),
      }),
  };
}

export type Api = ReturnType<typeof createApi>;
