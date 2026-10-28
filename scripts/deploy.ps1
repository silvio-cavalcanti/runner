[CmdletBinding()]
param(
    [string] $StackName = 'gh-runners',

    [Parameter(Mandatory)]
    [ValidateSet('repository', 'organization')]
    [string] $Scope,

    [Parameter(Mandatory)]
    [string] $Owner,

    [string] $Repo = '',

    [Parameter(Mandatory)]
    [string] $TokenSecretArn,

    [Parameter(Mandatory)]
    [string] $VpcId,

    [Parameter(Mandatory)]
    [string] $SubnetId,

    [ValidateRange(1, 10)]
    [int] $RunnerCount = 4,

    [string] $Labels = 't3-large',

    [string] $RunnerGroup = '',

    [ValidateSet('t3.large', 't3.xlarge', 't3.2xlarge', 'm6i.large', 'm6i.xlarge', 'c6i.xlarge')]
    [string] $InstanceType = 't3.large',

    [ValidateSet('true', 'false')]
    [string] $AssignPublicIp = 'true',

    [ValidateSet('restricted', 'all')]
    [string] $EgressMode = 'restricted',

    [string] $SshCidr = '',

    [string] $KeyName = '',

    [ValidateRange(30, 2000)]
    [int] $VolumeSizeGiB = 100,

    [string] $Region = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Scope -eq 'repository' -and [string]::IsNullOrWhiteSpace($Repo)) {
    throw "-Repo e obrigatorio quando -Scope repository."
}
if (-not [string]::IsNullOrWhiteSpace($SshCidr) -and [string]::IsNullOrWhiteSpace($KeyName)) {
    throw "-KeyName e obrigatorio quando -SshCidr e informado."
}

$template = Join-Path (Split-Path -Parent $PSScriptRoot) 'github-runners-stack.yaml'
if (-not (Test-Path $template)) {
    throw "Template nao encontrado: $template"
}

$overrides = @(
    "GitHubScope=$Scope"
    "GitHubOwner=$Owner"
    "GitHubTokenSecretArn=$TokenSecretArn"
    "VpcId=$VpcId"
    "SubnetId=$SubnetId"
    "RunnerCount=$RunnerCount"
    "RunnerLabels=$Labels"
    "InstanceType=$InstanceType"
    "AssignPublicIp=$AssignPublicIp"
    "EgressMode=$EgressMode"
    "VolumeSizeGiB=$VolumeSizeGiB"
)
if ($Scope -eq 'repository') { $overrides += "GitHubRepo=$Repo" }
if (-not [string]::IsNullOrWhiteSpace($RunnerGroup)) { $overrides += "RunnerGroup=$RunnerGroup" }
if (-not [string]::IsNullOrWhiteSpace($SshCidr)) { $overrides += "SshAllowedCidr=$SshCidr" }
if (-not [string]::IsNullOrWhiteSpace($KeyName)) { $overrides += "KeyName=$KeyName" }

$awsArgs = @(
    'cloudformation', 'deploy'
    '--stack-name', $StackName
    '--template-file', $template
    '--capabilities', 'CAPABILITY_IAM'
    '--parameter-overrides'
) + $overrides
if (-not [string]::IsNullOrWhiteSpace($Region)) { $awsArgs += @('--region', $Region) }

Write-Host "==> aws $($awsArgs -join ' ')" -ForegroundColor Cyan
& aws @awsArgs
if ($LASTEXITCODE -ne 0) { throw "Falha no deploy (exit $LASTEXITCODE)." }

$regionArgs = @()
if (-not [string]::IsNullOrWhiteSpace($Region)) { $regionArgs = @('--region', $Region) }

$outputs = & aws cloudformation describe-stacks --stack-name $StackName `
    @regionArgs --query 'Stacks[0].Outputs' --output json | ConvertFrom-Json

Write-Host "`nSaidas do stack:" -ForegroundColor Green
$outputs | ForEach-Object { Write-Host ("  {0,-20} {1}" -f $_.OutputKey, $_.OutputValue) }

Write-Host "`nAcompanhe o bootstrap:" -ForegroundColor Yellow
Write-Host "  aws ssm start-session --target $($outputs | Where-Object OutputKey -eq 'InstanceId' | Select-Object -ExpandProperty OutputValue)"
Write-Host "  sudo tail -f /var/log/gh-runner-bootstrap.log"
Write-Host "  journalctl -u gh-runner@1 -f"
