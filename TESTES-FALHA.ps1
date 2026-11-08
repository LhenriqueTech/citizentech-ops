# Roda os testes de falha na VM, incluindo a reinicialização (vagrant reload)
$proj = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $proj
$vg = 'C:\Program Files\Vagrant\bin\vagrant.exe'
$st = Join-Path $proj 'testes-falha.log'
function Log($m) { "$(Get-Date -Format s) $m" | Out-File $st -Append }
"" | Out-File $st
Log "status da VM"
& $vg status *>&1 | Out-File $st -Append
$s = (& $vg status --machine-readable) -join "`n"
if ($s -notmatch ',state,running') { Log "VM desligada: vagrant up"; & $vg up *>&1 | Out-File $st -Append }
Log "teste 1: falha controlada"
& $vg ssh -c "sudo rm -f /vagrant/evidencias/testes-falha/*.txt; sudo bash /vagrant/tools/teste-falhas.sh script" *>&1 | Out-File $st -Append
Log "teste 2: monitor parado"
& $vg ssh -c "sudo bash /vagrant/tools/teste-falhas.sh monitor" *>&1 | Out-File $st -Append
Log "teste 3: antes do reboot"
& $vg ssh -c "sudo bash /vagrant/tools/teste-falhas.sh pre-reboot" *>&1 | Out-File $st -Append
Log "teste 3: vagrant reload"
& $vg reload *>&1 | Out-File $st -Append
Log "teste 3: depois do reboot (codigo reload $LASTEXITCODE)"
& $vg ssh -c "sudo bash /vagrant/tools/teste-falhas.sh pos-reboot" *>&1 | Out-File $st -Append
Log "FIM"
Start-Sleep -Seconds 3
