# CertificateExpiringSoon

Also used by `CertificateExpiryCritical`, `CertificateNotReady` and `TLSEndpointCertificateExpiring`
(`gitops/platform/observability/alerts/manifests/platform-rules.yaml`).

## Severity

| Alert | Severity | Expression | `for` |
|---|---|---|---|
| `CertificateExpiringSoon` | warning | `(certmanager_certificate_expiration_timestamp_seconds - time()) < 14 * 24 * 3600` | 1h |
| `CertificateExpiryCritical` | critical | same, `< 3 * 24 * 3600` | 10m |
| `CertificateNotReady` | warning | `max by (namespace, name) (certmanager_certificate_ready_status{condition="False"}) == 1` | 15m |
| `TLSEndpointCertificateExpiring` | warning | `(probe_ssl_earliest_cert_expiry - time()) < 14 * 24 * 3600` (blackbox) | 1h |

## Meaning

cert-manager should renew well before 14 days: internal certificates are 90 d with `renewBefore: 720h`
(30 d), Let's Encrypt certificates renew at 30 d left by default. A certificate at < 14 d therefore means
renewal has been failing for about two weeks. `TLSEndpointCertificateExpiring` looks at the live endpoint
(covers certificates not managed by cert-manager, or a gateway still serving an old secret).

Issuers: `ClusterIssuer` **`internal-ca`** (CA keypair `cert-manager/internal-ca-keypair`) for
`*.internal.example.local` / `*.ops.example.local` (Certificates `internal-wildcard`, `ops-wildcard`,
`upstream-ca` in `istio-internal`), and **`letsencrypt-prod`** (ACME HTTP-01 via IngressClass `kong`) for public
hosts — one `<release>-tls` certificate per Kong Ingress rendered by `charts/microservice` / `charts/frontend`
in `tenant-*` / `shared-services`.

## Impact

When it expires: browsers/clients reject TLS — public API (`api.example.com`, `<tenant>.api.example.com`),
frontends, or ops UIs / internal gateway traffic, depending on the certificate.

## Diagnosis

```bash
kubectl -n <namespace> get certificate <name> -o wide
cmctl status certificate <name> -n <namespace>          # Certificate -> CertificateRequest -> Order -> Challenge
kubectl -n <namespace> get certificaterequests,orders.acme.cert-manager.io,challenges.acme.cert-manager.io
kubectl -n cert-manager logs deploy/cert-manager --tail=300 | grep -i <name>
kubectl get clusterissuers internal-ca letsencrypt-prod -o wide
```

Let's Encrypt HTTP-01 failures: the challenge must be reachable from the Internet at
`http://<host>/.well-known/acme-challenge/...` through the Kong public VIP (`kubectl -n kong get svc
kong-gateway-proxy`, MetalLB `public-pool`); check `kubectl describe challenge ...` for the reason (DNS, port 80
blocked, rate limit, Kong route missing).

Live endpoint: `echo | openssl s_client -connect api.example.com:443 -servername api.example.com 2>/dev/null |
openssl x509 -noout -enddate -issuer`. Grafana **Platform Overview & SLOs** → *TLS certificate expiry (probed
endpoints)*.

```promql
sort((certmanager_certificate_expiration_timestamp_seconds - time()) / 86400)
```

## Mitigation

1. Fix the root cause shown by `cmctl status` (issuer not Ready, ACME challenge failing, invalid DNS name,
   CA secret missing), then force a renewal: `cmctl renew <name> -n <namespace>`.
2. `internal-ca` not Ready: verify `cert-manager/internal-ca-keypair` exists and the `internal-ca`
   Certificate (issued by `selfsigned-bootstrap`) is Ready.
3. ACME rate-limited (many releases on the same host): point releases to a shared wildcard secret
   (`kong.tls.secretName` + `kong.tls.certManager: false` in `charts/microservice` values) instead of one order
   per release.
4. Secret renewed but endpoint still old: Istio gateways reload SDS automatically; for Kong, check the
   controller synced the Secret (`kubectl -n kong logs deploy/kong-controller`), then restart
   `kong-gateway` pods if needed.
5. Last resort before expiry: issue manually from `internal-ca` or obtain the certificate out of band and store
   it in the target Secret (document it and remove once cert-manager works).

## Escalation

Warning → `#platform-alerts`; `CertificateExpiryCritical` pages on-call. Public-certificate issues involving
DNS / firewall (port 80 to the public VIP): network team.

## Related

- [SyntheticProbeFailed](SyntheticProbeFailed.md), [Kong5xxSurge](Kong5xxSurge.md)
- `gitops/platform/core/cert-manager/manifests/`, `docs/conventions.md` (Secrets and certificates)
