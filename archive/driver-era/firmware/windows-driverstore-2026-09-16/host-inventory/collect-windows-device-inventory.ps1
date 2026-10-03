$out = 'C:\Users\cates\AppData\Local\Temp\a16-fw\devs.txt'
$lines = @()
$lines += '=== bound signed drivers for WLAN / BT / audio / display / video ==='
Get-CimInstance Win32_PnPSignedDriver |
  Where-Object { $_.DeviceName -match 'Qualcomm|Adreno|Aqstic|FastConnect|SoundWire|Display|HDMI|DisplayPort' } |
  Select-Object DeviceName, DriverProviderName, DriverVersion, InfName, DeviceID |
  Sort-Object DeviceName | Format-Table -AutoSize | Out-String -Width 400 | ForEach-Object { $lines += $_ }
$lines += ''
$lines += '=== all present devices class Display / Monitor / Camera / Image ==='
Get-PnpDevice -PresentOnly | Where-Object { $_.Class -in @('Display','Monitor','Camera','Image','Media') } |
  Select-Object Class,Status,FriendlyName,InstanceId | Sort-Object Class |
  Format-Table -AutoSize | Out-String -Width 400 | ForEach-Object { $lines += $_ }
$lines += ''
$lines += '=== every present device whose instance id starts with ACPI or PCI, name+id only ==='
Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -match '^(ACPI|PCI)\\' } |
  Select-Object Status,Class,FriendlyName,InstanceId | Sort-Object Class,FriendlyName |
  Format-Table -AutoSize | Out-String -Width 400 | ForEach-Object { $lines += $_ }
$lines | Out-File -Encoding utf8 $out
