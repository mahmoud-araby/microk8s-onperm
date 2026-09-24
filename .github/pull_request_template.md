## What & why

<!-- What does this change do, and why is it needed? Link the issue / ADR / incident. -->

## Type of change

- [ ] Service code (`services/**`)
- [ ] GitOps / service catalogue / tenant (`gitops/**`)
- [ ] Helm chart (`charts/**`)
- [ ] Cluster provisioning (`ansible/**`)
- [ ] CI / supply chain (`.github/**`)
- [ ] Documentation

## Checklist

**Services**
- [ ] Microservice contract kept: port 8080, `/health/live|ready|startup`, `/metrics`, JSON logs with
      `trace_id`/`span_id`/`tenant_id`, `X-Tenant-ID`/`X-Correlation-ID` propagation, SIGTERM drain < 25 s
- [ ] Every query / cache key / message is tenant scoped
- [ ] Outbound calls have timeouts; retries only for idempotent operations; breaker/bulkhead per dependency
- [ ] DB migrations are backward compatible (expand/contract) - older major versions keep working
- [ ] Unit tests added/updated and passing locally
- [ ] Version bumped (`<Version>` / `pom.xml` / `pyproject.toml` / `package.json`) - a new **major** needs a new
      `gitops/apps/<service>/values-v<major>.yaml`

**GitOps / charts / Ansible**
- [ ] `helm lint` + `helm template` with the chart's `ci/` values pass; `kubeconform` passes
- [ ] Sync waves / AppProject / namespaces follow `docs/conventions.md`
- [ ] No secrets in Git (Vault + External Secrets only)
- [ ] Rollback plan described below for production-impacting changes

## Rollout & rollback

<!-- Rings / tenants affected, canary expectations, how to roll back (revert PR, Argo Rollouts abort, ...). -->

## Screenshots / evidence

<!-- Test output, dashboards, kubectl/argocd diff, etc. -->
