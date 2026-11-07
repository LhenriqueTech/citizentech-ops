$out = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'diagnostico.txt'
"=== CPU ===" | Out-File $out
Get-CimInstance Win32_Processor | Select-Object Name, VirtualizationFirmwareEnabled, SecondLevelAddressTranslationExtensions | Format-List | Out-File $out -Append
"=== Hypervisor presente (Hyper-V/VBS) ===" | Out-File $out -Append
(Get-CimInstance Win32_ComputerSystem).HypervisorPresent | Out-File $out -Append
"=== bcdedit hypervisorlaunchtype ===" | Out-File $out -Append
bcdedit /enum '{current}' 2>&1 | Select-String hypervisor | Out-File $out -Append
"=== Recursos opcionais ===" | Out-File $out -Append
Get-WindowsOptionalFeature -Online -ErrorAction SilentlyContinue | Where-Object { $_.FeatureName -match 'Hyper-V|VirtualMachinePlatform|HypervisorPlatform|Subsystem-Linux' } | Select-Object FeatureName, State | Format-Table -AutoSize | Out-File $out -Append
"=== VBox.log (trechos) ===" | Out-File $out -Append
$vlog = Join-Path $env:USERPROFILE 'VirtualBox VMs\citizentech-srv01\Logs\VBox.log'
if (Test-Path $vlog) { Select-String -Path $vlog -Pattern 'NEM|HM: HMR3Init|VT-x|AMD-V|turtle|Guest Additions|failed|error' | Select-Object -First 60 | ForEach-Object { $_.Line } | Out-File $out -Append } else { "VBox.log nao encontrado" | Out-File $out -Append }
