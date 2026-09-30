# wodemo-gitops

Desired state of the **wodemo** demo (the work-order sample app, repository
[wodemo-app](https://github.com/clearmeasure-aisf-sample-apps/wodemo-app)) and the config-as-code of its Octopus
Deploy project. Everything here is demo-grade: one small AKS cluster (`aks-wodemo` in `rg-wodemo`), one shared SQL Server,
three environments (tdd, uat, prod) as namespaces.

```text
wodemo-app (GitHub Actions)            wodemo-gitops (this repo)                 cluster aks-wodemo
  push to main                          wodemo/envs/<env>/kustomization.yaml       Argo CD  ->  wodemo-<env>
   -> ci (build, test)                    images[].newTag = the pins                 PreSync: db-init, db-migrate
   -> release: 3 images to ACR,         argocd/apps/*  Applications                 then ui-server + worker
      cosign-signed, GitHub release v<n>  data/sqlserver  shared SQL Server         ingress-nginx, sslip.io hosts
                 \___ pin writer ________/  .octopus/wodemo  Octopus project as code
```

## Layout

| Path | Purpose |
|---|---|
| `bootstrap/` | Argo CD values and the root Application (applied once by the bootstrap script) |
| `argocd/apps/` | Applications: ingress-nginx, the SQL Server, `wodemo-tdd`, `wodemo-uat`, `wodemo-prod` |
| `data/sqlserver/` | Shared SQL Server 2022 Express (StatefulSet, 8 Gi volume). The sa password is a Secret created by the bootstrap script, never in Git |
| `wodemo/base/` | ui-server, worker, ingress, and two PreSync hooks: `db-init` (database and login) and `db-migrate` (DbUp console of the pinned release) |
| `wodemo/envs/<env>/` | Per-environment overlay: namespace, config, ingress host, **the image pins** |
| `.octopus/wodemo/` | Octopus project `wodemo` as config-as-code (deployment process, settings, variables) |
| `octopus/terraform/` | Octopus environments, lifecycle, feed and project shell (not yet applied, see below) |
| `scripts/` | `bootstrap-cluster.ps1` (one-time cluster setup), `set-pin.sh` (pin writer) |
| `.github/workflows/` | `validate` (renders every overlay), `sync-tdd` and `promote` (pin writer stand-in) |

## Who writes pins

Only a pin writer changes `images[].newTag`:

- **`PIN_WRITER=actions`** (current): `sync-tdd` follows the latest release of wodemo-app every 10 minutes and pins tdd;
  `promote` (manual, choose uat or prod) pins the version of the previous environment. Environment `prod` requires a
  reviewer.
- **`PIN_WRITER=octopus`**: Octopus Deploy's "Update Argo CD image tags" step does it (`.octopus/wodemo/`). Set the
  repository variable to `octopus` so the two workflows stand down.

## Migrations

Every sync first runs `db-init` (creates the environment's database and application login, idempotent) and then
`db-migrate` (the `db-migrator` image of the pinned release runs the DbUp scripts). A failing migration fails the sync
and the old pods keep serving. The demo uses `sa` for the migration and a per-environment `db_owner` login for the app.
The migrator reaches SQL Server as `sql-localhost` (an ExternalName alias) only because the console skips certificate
validation for server names containing "localhost"; a real environment would use a certificate from a trusted CA.

## Bootstrap

Prerequisites: `az` logged in, `kubectl`, `helm`, PowerShell 7, and the cluster `aks-wodemo` running.

```bash
pwsh scripts/bootstrap-cluster.ps1 -CommitHosts
```

## Octopus

The Octopus project is **code here but not applied**: creating it needs an Octopus API key (or a signed-in session),
which the automation that built this repository does not have. To apply, with a Space Manager key:

```bash
cd octopus/terraform
export TF_VAR_octopus_api_key=<key>        # never commit it
terraform init && terraform apply -var "space_id=<space>"
```

Then install the Octopus Argo CD gateway in the cluster (chart `octopus-argocd-gateway-chart`, registration token from
Octopus), register the cluster's Argo CD, create a release of `wodemo` from the latest ACR images, and set the
repository variable `PIN_WRITER` to `octopus`.
