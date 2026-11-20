# E8.0-H5/H6: effective external exposure sweep from operator box (172.22.6.30). READ-ONLY TCP connect probes.
$ErrorActionPreference = 'SilentlyContinue'
$s52ports = @(22,80,443,3001,4000,4101,4102,5055,5435,8000,8087,8088,8200,8210,8211,8212,9090,3100,9100)
$s53ports = @(22,80,443,3000,3001,4000,5432,6333,6379,7474,7687,8000,8033,8043,8044,8045,8046,8047,8048,8053,8054,8063,8064,8080,8990,9000,9090,9400,9443,9500,14101,18101,18200,18210,22001)
$out = @()
$out += "sweep start $(Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ') from $(ipconfig | Out-String | Select-String '172\.22\.6\.\d+' | Select-Object -First 1)"
foreach ($p in $s52ports) {
    $r = Test-NetConnection -ComputerName '172.30.0.133' -Port $p -WarningAction SilentlyContinue
    $out += ("s52:{0}`t{1}" -f $p, $(if ($r.TcpTestSucceeded) {'OPEN'} else {'BLOCKED'}))
}
foreach ($p in $s53ports) {
    $r = Test-NetConnection -ComputerName '172.20.1.53' -Port $p -WarningAction SilentlyContinue
    $out += ("s53:{0}`t{1}" -f $p, $(if ($r.TcpTestSucceeded) {'OPEN'} else {'BLOCKED'}))
}
$out += "sweep end $(Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ')"
$out | Out-File -Encoding utf8 'evidence/E8.0-H/exposure_sweep.raw.txt'
$out | ForEach-Object { Write-Output $_ }
Write-Output "=== public edge content checks ==="
foreach ($h in @('https://radio.ai.ismc.ir/', 'https://rag.ai.ismc.ir/')) {
    $code = curl -sk -o NUL -w '%{http_code}' --max-time 20 $h
    $title = curl -sk --max-time 20 $h | Select-String -Pattern '<title[^>]*>([^<]*)' | Select-Object -First 1
    Write-Output ("{0}  HTTP {1}  title~{2}" -f $h, $code, $title)
}
