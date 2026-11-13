<#
Installs or updates SwitchBoard + SwitchBoardChat + Synapse + MAS on Windows (Docker Desktop).
Same options as install.sh, which this runs with Git for Windows' bash:
  .\install.ps1 --domain example.org --email admin@example.org
  .\install.ps1 --non-interactive --domain test --tls selfsigned
Default install folder: %USERPROFILE%\switchboard. Compatible with Windows PowerShell 5.1 and PowerShell 7.
Run verify.sh the same way: .\install.ps1 -Script verify.sh [--functional]
#>
$ErrorActionPreference = 'Stop'
# No param() block: every argument goes to the bash script untouched (PowerShell would otherwise bind
# a value such as the domain name to a parameter of its own).
$Script = 'install.sh'
$rest = @($args)
if ($rest.Count -ge 2 -and $rest[0] -eq '-Script') { $Script = $rest[1]; $rest = @($rest | Select-Object -Skip 2) }

$bash = @(
    "$env:ProgramFiles\Git\bin\bash.exe",
    "${env:ProgramFiles(x86)}\Git\bin\bash.exe",
    "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe"
) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
if (-not $bash) {
    Write-Host "Git for Windows is needed (it provides bash): https://git-scm.com/download/win"
    exit 3
}
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Host "Docker Desktop is needed: https://www.docker.com/products/docker-desktop (then start it)"
    exit 3
}
$target = (Join-Path $PSScriptRoot $Script) -replace '\\', '/'
& $bash $target @rest
exit $LASTEXITCODE
