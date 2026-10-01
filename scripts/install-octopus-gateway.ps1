#!/usr/bin/env pwsh
#Requires -Version 7.4
<#
.SYNOPSIS
    Installs the Octopus Argo CD gateway on the wodemo cluster and registers it with Octopus (space Spaces-335).

.DESCRIPTION
    Needs kubectl and helm, the bootstrap done (secret argocd-octopus-token exists), and a temporary Octopus API key in
    the environment variable OCTOPUS_REGISTRATION_KEY. Create the key in Octopus under your profile, "My API Keys", with
    an expiry of one day; delete it afterwards. The script stores it in a Secret only for the registration and removes the
    Secret again when the gateway is registered (-KeepSecret keeps it).

    After it succeeds: Octopus shows the instance under Infrastructure > Argo CD Instances, and the Applications
    wodemo-tdd, wodemo-uat and wodemo-prod (annotated argo.octopus.com/project and /environment) appear against the
    project wodemo. Then set the repository variable PIN_WRITER to octopus so the GitHub pin writer stands down.
#>
[CmdletBinding()]
param(
    [string]$Kubeconfig = (Join-Path $HOME '.kube/wodemo.config'),
    [string]$ChartVersion = '2.1.0',
    [switch]$KeepSecret
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($env:OCTOPUS_REGISTRATION_KEY)) { throw 'Set OCTOPUS_REGISTRATION_KEY to a temporary Octopus API key first.' }
$repoRoot = Split-Path -Parent $PSScriptRoot
$ns = 'octopus-argocd-gateway'

& kubectl --kubeconfig $Kubeconfig get secret argocd-octopus-token -n $ns *> $null
if ($LASTEXITCODE -ne 0) { throw "Secret $ns/argocd-octopus-token is missing: run scripts/bootstrap-cluster.ps1 and create the Argo CD account token first." }

Write-Host 'storing the registration key'
$secretYaml = & kubectl --kubeconfig $Kubeconfig -n $ns create secret generic octopus-gateway-registration `
    "--from-literal=token=$($env:OCTOPUS_REGISTRATION_KEY)" --dry-run=client -o yaml
$secretYaml | & kubectl --kubeconfig $Kubeconfig apply -f - | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'could not store the registration key' }

Write-Host 'installing the gateway'
helm upgrade --install octopus-argocd-gateway oci://registry-1.docker.io/octopusdeploy/octopus-argocd-gateway-chart `
    --version $ChartVersion --namespace $ns --values (Join-Path $repoRoot 'octopus/gateway-values.yaml') --wait --timeout 10m
if ($LASTEXITCODE -ne 0) { throw 'helm install of the gateway failed' }

if (-not $KeepSecret) {
    & kubectl --kubeconfig $Kubeconfig -n $ns delete secret octopus-gateway-registration --ignore-not-found | Out-Null
    Write-Host 'registration key removed from the cluster; delete the API key in Octopus too'
}
Write-Host 'done: check Infrastructure > Argo CD Instances in Octopus'
