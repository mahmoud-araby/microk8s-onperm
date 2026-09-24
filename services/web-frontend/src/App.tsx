import { useCallback, useEffect, useMemo, useState } from "react";
import type { User } from "oidc-client-ts";
import { createApi, type Order, type Product } from "./api";
import { completeLoginIfCallback, createUserManager } from "./auth";
import { loadConfig } from "./config";

export function App() {
  const config = useMemo(() => loadConfig(), []);
  const userManager = useMemo(() => createUserManager(config), [config]);
  const [user, setUser] = useState<User | null>(null);
  const api = useMemo(() => createApi(config, () => user?.access_token), [config, user]);

  const [products, setProducts] = useState<Product[]>([]);
  const [orders, setOrders] = useState<Order[]>([]);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    document.title = `${config.tenantName} · Platform`;
    document.documentElement.style.setProperty("--brand", config.brandColor);
    completeLoginIfCallback(userManager).then(setUser, (e: Error) => setError(e.message));
  }, [config, userManager]);

  const refresh = useCallback(async () => {
    setError(null);
    try {
      const [p, o] = await Promise.all([api.listProducts(), api.listOrders()]);
      setProducts(p);
      setOrders(o);
    } catch (e) {
      setError((e as Error).message);
    }
  }, [api]);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  const order = async (product: Product) => {
    try {
      await api.createOrder(product.id, 1, product.currency, user?.profile.sub ?? "anonymous");
      await refresh();
    } catch (e) {
      setError((e as Error).message);
    }
  };

  return (
    <div className="app">
      <header>
        {config.logoUrl && <img src={config.logoUrl} alt="" className="logo" />}
        <h1>{config.tenantName}</h1>
        <span className="tenant">tenant: {config.tenantId || "shared"}</span>
        <div className="spacer" />
        {userManager &&
          (user ? (
            <button onClick={() => userManager.signoutRedirect()}>Sign out {user.profile.preferred_username}</button>
          ) : (
            <button onClick={() => userManager.signinRedirect()}>Sign in</button>
          ))}
      </header>

      {error && <p className="error">{error}</p>}

      <main>
        <section>
          <h2>Products</h2>
          <table>
            <tbody>
              {products.map((p) => (
                <tr key={p.id}>
                  <td>{p.name}</td>
                  <td>
                    {p.price.toFixed(2)} {p.currency}
                  </td>
                  <td>
                    <button onClick={() => order(p)}>Order</button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </section>
        <section>
          <h2>Orders</h2>
          <table>
            <tbody>
              {orders.map((o) => (
                <tr key={o.id}>
                  <td>{o.id.slice(0, 8)}</td>
                  <td>{o.status}</td>
                  <td>
                    {o.total.toFixed(2)} {o.currency}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </section>
      </main>
    </div>
  );
}
