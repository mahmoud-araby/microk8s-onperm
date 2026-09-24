# ArgoCDAppOutOfSync

Also used by `ArgoCDAppSyncFailed` (`gitops/platform/observability/alerts/manifests/platform-rules.yaml`).

## Severity

| Alert | Severity | Expression | `for` |
|---|---|---|---|
| `ArgoCDAppOutOfSync` | warning | `max by (name, project, dest_namespace) (argocd_app_info{sync_status="OutOfSync"}) == 1` | 30m |
| `ArgoCDAppSyncFailed` | warning | `sum by (name, project) (increase(argocd_app_sync_total{phase=~"Error\|Failed"}[15m])) > 0` | 0m |

Both carry `namespace: argocd`.

## Meaning

The live state of Application `{{ $labels.name }}` has differed from Git (`main` of
`https://github.com/mahmoud-araby/microk8s-onperm.git`) for 30 minutes. Everything is `automated` with
`prune: true, selfHeal: true` and a retry backoff (10 s → 5 min, limit 10), so a lasting OutOfSync means:

- auto-sync keeps failing (invalid manifest, admission webhook / Kyverno denial, immutable field, missing CRD,
  AppProject restriction, hook Job failing — e.g. `es-bootstrap` in `logging`);
- a permanent diff that sync cannot fix (a controller or mutating webhook rewrites a field → needs an
  `ignoreDifferences` entry);
- **service releases waiting for their ring**: the `services` ApplicationSet uses RollingSync (canary → early
  → general) and disables per-Application auto-sync; releases in later rings stay OutOfSync while an earlier
  ring is not Healthy;
- a sync window (the `core` AppProject has a commented freeze-window example) blocks automated syncs.

## Impact

Git changes (image bumps, config, security fixes) are not applied. Usually not user-facing by itself, but a
failed sync may leave a component half-applied.

## Diagnosis

```bash
argocd login argocd.ops.example.local --sso
argocd app get <name> --show-operation        # last operation, phase, message, retry count
argocd app diff <name>                         # what differs
argocd app history <name>
kubectl -n argocd get application <name> -o jsonpath='{.status.operationState.message}{"\n"}'
kubectl -n argocd logs statefulset/argocd-application-controller --tail=300 | grep '"<name>"'
kubectl -n argocd get applicationset services -o jsonpath='{.status.applicationStatus}' | jq   # RollingSync state
```

```promql
argocd_app_info{sync_status="OutOfSync"}
sum by (name, phase) (increase(argocd_app_sync_total[1h]))
```

## Mitigation

1. Read the operation message and fix the manifest **in Git** (bad values, schema error, missing CRD — check the
   sync wave order in `docs/conventions.md`).
2. Admission denial (Kyverno / webhook): `kubectl get events -n <dest_namespace> | grep -i denied`; fix the
   resource or request a policy exception — do not disable the policy.
3. Permanent diff caused by a controller: add a targeted `ignoreDifferences` (see existing ones in
   `gitops/bootstrap/argocd/values.yaml` and `gitops/apps/applicationsets/services.yaml`).
4. Stuck operation: `argocd app terminate-op <name>`, then `argocd app sync <name>` (add `--prune` only after
   reviewing the diff).
5. RollingSync blocked by an earlier ring: fix the Degraded application in that ring
   ([ArgoCDAppDegraded](ArgoCDAppDegraded.md)); the following rings then proceed automatically.
6. Immutable field (e.g. StatefulSet `volumeClaimTemplates`, Service `clusterIP`): coordinate a
   delete/recreate with `argocd app sync <name> --resource <group>:<kind>:<name> --force` only for stateless
   resources; for stateful ones follow [PlatformPVCFillingUp](PlatformPVCFillingUp.md) (PVC expansion).

## Escalation

`#platform-alerts`. The author of the offending commit (`git log` on the app's path) and the owning team
(platform / data / service team). Escalate to platform on-call if `platform-core` or `argocd-self` is failing.

## Related

- [ArgoCDAppDegraded](ArgoCDAppDegraded.md), [RolloutAborted](RolloutAborted.md)
- `gitops/bootstrap/root-app.yaml`, `gitops/apps/README.md` (release flow)
