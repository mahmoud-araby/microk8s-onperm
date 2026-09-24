import { UserManager, WebStorageStateStore, type User } from "oidc-client-ts";
import type { RuntimeConfig } from "./config";

/** OIDC (Keycloak, authorization code + PKCE). Returns null when no authUrl is configured (local dev). */
export function createUserManager(config: RuntimeConfig): UserManager | null {
  if (!config.authUrl) return null;
  const origin = window.location.origin;
  return new UserManager({
    authority: config.authUrl,
    client_id: config.clientId,
    redirect_uri: `${origin}/callback`,
    post_logout_redirect_uri: origin,
    response_type: "code",
    scope: "openid profile email",
    automaticSilentRenew: true,
    userStore: new WebStorageStateStore({ store: window.sessionStorage }),
  });
}

export async function completeLoginIfCallback(manager: UserManager | null): Promise<User | null> {
  if (!manager) return null;
  if (window.location.pathname === "/callback") {
    const user = await manager.signinRedirectCallback();
    window.history.replaceState({}, document.title, "/");
    return user;
  }
  return manager.getUser();
}
