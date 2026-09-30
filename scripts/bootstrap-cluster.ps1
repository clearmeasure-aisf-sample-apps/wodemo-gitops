#!/usr/bin/env pwsh
#Requires -Version 7.4
<#
.SYNOPSIS
    One-time bootstrap of the wodemo demo cluster: Argo CD, the secrets that never live in Git, and the root Application.

.DESCRIPTION
    Idempotent. Needs az (logged in), kubectl and helm. Does, in order:
      1. gets credentials of the AKS cluster into a dedicated kubeconfig (your default kubeconfig is not touched)
      2. installs Argo CD (chart argo/argo-cd 10.9.5, bootstrap/argocd-values.yaml)
      3. creates the namespaces and the secrets with generated passwords (only those that do not exist yet):
           wodemo-data/mssql-sa                      sa password of the shared SQL Server
           wodemo-<env>/db-admin                     the same sa password, for the db-init and db-migrate hooks
           wodemo-<env>/db-app                       username wodemo_<env>_app and its own password
      4. applies bootstrap/root-app.yaml; Argo CD then installs ingress-nginx, SQL Server and the three environments
      5. waits for the ingress load balancer IP and writes the sslip.io host names into the environment overlays
         (-CommitHosts also commits and pushes that change)
    Passwords are printed nowhere. Read one back with:
      kubectl --kubeconfig <file> -n wodemo-data get secret mssql-sa -o jsonpath='{.data.password}' | base64 -d
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup = 'rg-wodemo',
    [string]$ClusterName = 'aks-wodemo',
    [string]$Kubeconfig = (Join-Path $HOME '.kube/wodemo.config'),
    [string]$ArgoCdChartVersion = '10.9.5',
    [switch]$CommitHosts
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$envs = 'tdd', 'uat', 'prod'

function New-DemoPassword {
    # 24 characters, alphanumeric (safe inside SQL and connection strings) with all three classes SQL Server requires.
    $upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ'; $lower = 'abcdefghijkmnpqrstuvwxyz'; $digit = '23456789'
    $all = ($upper + $lower + $digit).ToCharArray()
    $chars = @(
        $upper[(Get-Random -Maximum $upper.Length)], $lower[(Get-Random -Maximum $lower.Length)], $digit[(Get-Random -Maximum $digit.Length)]
    ) + (1..21 | ForEach-Object { $all[(Get-Random -Maximum $all.Length)] })
    -join ($chars | Sort-Object { Get-Random })
}

function Invoke-Kubectl { & kubectl --kubeconfig $Kubeconfig @args; if ($LASTEXITCODE -ne 0) { throw "kubectl $($args -join ' ') failed" } }

function Get-SecretValue([string]$Namespace, [string]$Name, [string]$Key) {
    $b64 = & kubectl --kubeconfig $Kubeconfig -n $Namespace get secret $Name -o "jsonpath={.data.$Key}" 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrEmpty($b64)) { return $null }
    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
}

function Set-SecretIfMissing([string]$Namespace, [string]$Name, [hashtable]$Data) {
    & kubectl --kubeconfig $Kubeconfig -n $Namespace get secret $Name *> $null
    if ($LASTEXITCODE -eq 0) { Write-Host "secret $Namespace/$Name exists"; return }
    [string[]]$literals = @($Data.GetEnumerator() | ForEach-Object { "--from-literal=$($_.Key)=$($_.Value)" })
    # Do not route this through Invoke-Kubectl: a failure message would echo the password.
    & kubectl --kubeconfig $Kubeconfig -n $Namespace create secret generic $Name @literals | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "creating secret $Namespace/$Name failed" }
    Write-Host "secret $Namespace/$Name created"
}

Write-Host '== 1. credentials'
New-Item -ItemType Directory -Force (Split-Path $Kubeconfig) | Out-Null
az aks get-credentials --resource-group $ResourceGroup --name $ClusterName --file $Kubeconfig --overwrite-existing --admin 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'az aks get-credentials failed (is the cluster running? az aks start)' }
$env:KUBECONFIG = $Kubeconfig

Write-Host '== 2. Argo CD'
helm repo add argo https://argoproj.github.io/argo-helm *> $null
helm repo update argo *> $null
helm upgrade --install argocd argo/argo-cd --version $ArgoCdChartVersion --namespace argocd --create-namespace `
    --values (Join-Path $repoRoot 'bootstrap/argocd-values.yaml') --wait --timeout 10m
if ($LASTEXITCODE -ne 0) { throw 'helm install argo-cd failed' }

Write-Host '== 3. namespaces and secrets'
foreach ($ns in @('wodemo-data') + ($envs | ForEach-Object { "wodemo-$_" })) {
    & kubectl --kubeconfig $Kubeconfig create namespace $ns --dry-run=client -o yaml | & kubectl --kubeconfig $Kubeconfig apply -f - | Out-Null
}
$saPassword = Get-SecretValue 'wodemo-data' 'mssql-sa' 'password'
if (-not $saPassword) { $saPassword = New-DemoPassword }
Set-SecretIfMissing 'wodemo-data' 'mssql-sa' @{ password = $saPassword }
foreach ($e in $envs) {
    Set-SecretIfMissing "wodemo-$e" 'db-admin' @{ password = $saPassword }
    Set-SecretIfMissing "wodemo-$e" 'db-app' @{ username = "wodemo_${e}_app"; password = (New-DemoPassword) }
}

Write-Host '== 4. root Application'
Invoke-Kubectl apply -f (Join-Path $repoRoot 'bootstrap/root-app.yaml') | Out-Null

Write-Host '== 5. ingress IP and host names'
$ip = $null
for ($i = 0; $i -lt 60 -and -not $ip; $i++) {
    $ip = & kubectl --kubeconfig $Kubeconfig -n ingress-nginx get svc ingress-nginx-controller -o 'jsonpath={.status.loadBalancer.ingress[0].ip}' 2>$null
    if (-not $ip) { Start-Sleep -Seconds 15 }
}
if (-not $ip) { throw 'the ingress load balancer has no IP yet; run this script again in a few minutes' }
Write-Host "ingress IP $ip"
$changed = $false
foreach ($e in $envs) {
    $file = Join-Path $repoRoot "wodemo/envs/$e/kustomization.yaml"
    $text = Get-Content -Raw $file
    $new = $text -replace "wodemo-$e\.[0-9A-Za-z_.]+\.sslip\.io", "wodemo-$e.$ip.sslip.io" -replace "wodemo-$e\.INGRESS_IP\.sslip\.io", "wodemo-$e.$ip.sslip.io"
    if ($new -ne $text) { Set-Content -NoNewline -Path $file -Value $new; $changed = $true }
}
if ($changed -and $CommitHosts) {
    git -C $repoRoot add wodemo/envs
    git -C $repoRoot commit -m "Set the sslip.io host names to the ingress IP $ip"
    git -C $repoRoot push
}
elseif ($changed) { Write-Host 'host names changed in the working tree; commit and push them (or rerun with -CommitHosts)' }
foreach ($e in $envs) { Write-Host "  http://wodemo-$e.$ip.sslip.io" }
Write-Host 'Argo CD UI: kubectl --kubeconfig' $Kubeconfig '-n argocd port-forward svc/argocd-server 8080:80'
Write-Host 'Argo CD admin password: kubectl --kubeconfig' $Kubeconfig '-n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d'
