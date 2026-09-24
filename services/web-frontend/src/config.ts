export interface RuntimeConfig {
  /** e.g. https://api.example.com or https://acme.api.example.com ("" = same origin) */
  apiBaseUrl: string;
  /** Keycloak realm URL, e.g. https://keycloak.example.com/realms/acme ("" disables login) */
  authUrl: string;
  clientId: string;
  tenantId: string;
  tenantName: string;
  brandColor: string;
  logoUrl?: string;
}

declare global {
  interface Window {
    __CONFIG__?: Partial<RuntimeConfig>;
  }
}

export function loadConfig(raw: Partial<RuntimeConfig> | undefined = globalThis.window?.__CONFIG__): RuntimeConfig {
  const tenantId = raw?.tenantId ?? "";
  return {
    apiBaseUrl: (raw?.apiBaseUrl ?? "").replace(/\/+$/, ""),
    authUrl: raw?.authUrl ?? "",
    clientId: raw?.clientId || "web",
    tenantId,
    tenantName: raw?.tenantName || (tenantId ? tenantId.toUpperCase() : "Platform"),
    brandColor: raw?.brandColor || "#1f2937",
    logoUrl: raw?.logoUrl,
  };
}
