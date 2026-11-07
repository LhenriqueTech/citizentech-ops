# Instala VirtualBox + Vagrant (se faltarem) e sobe a VM CitizenTech com vagrant up.
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8
$proj = Split-Path -Parent $MyInvocation.MyCommand.Path
$log  = Join-Path $proj 'setup-windows.log'
$vlog = Join-Path $proj 'vagrant-up.log'
function Log($m) { $l = "$(Get-Date -Format s) $m"; Write-Host $l; Add-Content -Path $log -Value $l }

Log "=== Inicio (admin: $(([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators'))) ==="
$dl  = Join-Path $env:USERPROFILE 'Downloads'
$vbm = 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe'
$vg  = 'C:\Program Files\Vagrant\bin\vagrant.exe'

if (-not (Test-Path $vbm)) {
  $vb = Get-ChildItem $dl -Filter 'VirtualBox-*-Win.exe' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if (-not $vb) { Log "ERRO: instalador do VirtualBox nao encontrado em $dl"; exit 1 }
  Log "Instalando VirtualBox: $($vb.FullName)"
  $p = Start-Process $vb.FullName -ArgumentList '--silent','--ignore-reboot' -Wait -PassThru
  Log "VirtualBox exit code: $($p.ExitCode)"
} else { Log "VirtualBox ja instalado" }

if (-not (Test-Path $vg)) {
  $msi = Get-ChildItem $dl -Filter 'vagrant_*_windows_amd64.msi' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if (-not $msi) { Log "ERRO: instalador do Vagrant nao encontrado em $dl"; exit 1 }
  Log "Instalando Vagrant: $($msi.FullName)"
  $p = Start-Process msiexec.exe -ArgumentList '/i', "`"$($msi.FullName)`"", '/qn', '/norestart', '/l*v', "`"$proj\vagrant-install.log`"" -Wait -PassThru
  Log "Vagrant exit code: $($p.ExitCode) (3010 = ok, reinicio recomendado)"
} else { Log "Vagrant ja instalado" }

if (-not (Test-Path $vbm) -or -not (Test-Path $vg)) { Log "ERRO: instalacao incompleta"; exit 1 }
Log "VirtualBox: $(& $vbm --version)"
Log "Vagrant: $(& $vg --version)"

Set-Location $proj
Log "Coletando diagnostico..."
& (Join-Path $proj 'diagnostico.ps1')
$st = (& $vg status --machine-readable) -join "`n"
if ($st -match ',state,running') {
  Log "VM ja esta rodando: executando vagrant provision..."
  & $vg provision *>&1 | Tee-Object -FilePath $vlog
} else {
  Log "Executando vagrant up (pode levar 10-15 min)..."
  & $vg up --provider virtualbox --provision *>&1 | Tee-Object -FilePath $vlog
}
Log "vagrant terminou com codigo $LASTEXITCODE"
& $vg status *>&1 | Tee-Object -FilePath $vlog -Append
Log "=== Fim ==="
Start-Sleep -Seconds 5
