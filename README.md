# wodemo-gitops

Desired state of the **wodemo** demo (the work-order sample app, repository
[wodemo-app](https://github.com/clearmeasure-aisf-sample-apps/wodemo-app)). Everything here is demo-grade: one small AKS
cluster (`aks-wodemo` in `rg-wodemo`), one shared SQL Server, three environments (tdd, uat, prod) as namespaces, images in
the Azure Container Registry `acrwodemoce304`.

```text
wodemo-app (GitHub Actions)             wodemo-gitops (this repo)                  cluster aks-wodemo
  push to main                           wodemo/envs/<env>/kustomization.yaml        Argo CD  ->  wodemo-<env>
   -> ci (build, test)                     images[].newTag = the pins                  sync waves: config, db-init,
   -> release: 3 images to ACR,           argocd/apps/*   Applications                  db-migrate, then ui-server + worker
      cosign-signed, GitHub release v<n>  data/sqlserver  shared SQL Server            ingress-nginx, sslip.io hosts
                 \___ pin writer ________/
```

## Layout

| Path | Purpose |
|---|---|
| `bootstrap/` | Argo CD values and the root Application (applied once by the bootstrap script) |
| `argocd/apps/` | Applications: ingress-nginx, the SQL Server, `wodemo-tdd`, `wodemo-uat`, `wodemo-prod` |
| `data/sqlserver/` | Shared SQL Server 2022 Express (StatefulSet, 8 Gi volume). The sa password is a Secret created by the bootstrap script, never in Git |
| `wodemo/base/` | ui-server, worker, ingress, and two hooks: `db-init` (database and login) and `db-migrate` (DbUp console of the pinned release) |
| `wodemo/envs/<env>/` | Per-environment overlay: namespace, config, ingress host, **the image pins** |
| `octopus/gateway-values.yaml` | Values of the Octopus Argo CD gateway |
| `scripts/` | `bootstrap-cluster.ps1` (one-time cluster setup), `install-octopus-gateway.ps1`, `set-pin.sh` (pin writer) |
| `.github/workflows/` | `validate` (renders every overlay), `sync-tdd` and `promote` (pin writer stand-in) |

## Who writes pins

Only a pin writer changes `images[].newTag`:

- **`PIN_WRITER=actions`** (current): `sync-tdd` follows the latest release of wodemo-app every 10 minutes and pins tdd;
  `promote` (manual, choose uat or prod) pins the version of the previous environment. Environment `prod` requires a
  reviewer.
- **`PIN_WRITER=octopus`**: Octopus Deploy's "Update Argo CD image tags" step does it. Set the repository variable to
  `octopus` so the two workflows stand down.

## Migrations

Every sync applies the environment's ConfigMap (wave -1), runs `db-init` (creates the database and the application
login, idempotent, wave 0), then `db-migrate` (the `db-migrator` image of the pinned release runs the DbUp scripts, wave
1), and only then rolls the workloads out (wave 2). A failing migration fails the sync and the old pods keep serving.
The demo uses `sa` for the migration and a per-environment `db_owner` login for the app. The migrator reaches SQL Server
as `sql-localhost` (an ExternalName alias) only because the console skips certificate validation for server names
containing "localhost"; a real environment would use a certificate from a trusted CA.

If a sync is stuck on a failed hook of an earlier revision, clear it: remove `/operation` from the Application and delete
the old Jobs `db-init` and `db-migrate`; Argo CD then starts again from the current revision.

## Bootstrap

Prerequisites: `az` logged in, `kubectl`, `helm`, PowerShell 7, and the cluster `aks-wodemo` running.

```bash
pwsh scripts/bootstrap-cluster.ps1 -CommitHosts
```

## Octopus

Project **wodemo** exists in the Octopus space *AI Software Factory - Prototype* (`Spaces-335`), with the environments
`wodemo-tdd`, `wodemo-uat`, `wodemo-prod`, lifecycle `wodemo` (tdd automatic, then uat, then prod), project group
`wodemo`, feed `acr-wodemo` (anonymous; the registry allows anonymous pull) and the deployment process "Prod approval"
(prod only) followed by "Update Argo CD image tags" (all three environments). The project's configuration lives in
Octopus, **not** in Git: converting it to config-as-code was refused because the space's stored Git credential is
restricted to other repositories. Add a credential that covers this repository to convert it later.

Still to do, because it needs an Octopus API key:

```bash
export OCTOPUS_REGISTRATION_KEY=<temporary API key, expiry one day>
pwsh scripts/install-octopus-gateway.ps1
```

That installs the gateway (`octopus/gateway-values.yaml`), which registers the cluster's Argo CD as `argocd-wodemo` in the
space. Then delete the API key in Octopus, create a release of `wodemo`, and set the repository variable `PIN_WRITER` to
`octopus`. The values are adapted from the platform's working gateway and have not been exercised here.
