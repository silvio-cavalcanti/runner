[CmdletBinding()]
param(
    [string] $Name = 'github/actions-runner-token',
    [string] $Token = '',
    [string] $Description = 'GitHub token for self-hosted Actions runners'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Token)) {
    $Token = (gh auth token).Trim()
}
if ([string]::IsNullOrWhiteSpace($Token)) {
    throw "Nenhum token informado. Passe -Token ou autentique o gh CLI (gh auth login)."
}

# O PowerShell 5.1 remove as aspas ao passar JSON inline para comandos nativos,
# o que grava um secret invalido ({token:gho_...}). Escrever em arquivo evita isso.
$json = @{ token = $Token.Trim() } | ConvertTo-Json -Compress
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("gh-runner-secret-" + [guid]::NewGuid() + ".json")
[IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))

try {
    aws secretsmanager describe-secret --name $Name --query ARN --output text 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $arn = aws secretsmanager put-secret-value --secret-id $Name --secret-string "file://$tmp" --query ARN --output text
        Write-Host "Secret atualizado: $arn" -ForegroundColor Green
    } else {
        $arn = aws secretsmanager create-secret --name $Name --description $Description --secret-string "file://$tmp" --query ARN --output text
        Write-Host "Secret criado: $arn" -ForegroundColor Green
    }
    Write-Host "Use este ARN em -TokenSecretArn do deploy.ps1."
} finally {
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
}
