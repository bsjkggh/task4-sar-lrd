param([int]$Seconds = 180)
$p = New-Object System.IO.Ports.SerialPort COM10,115200,None,8,One
$p.ReadTimeout = 1000
$p.Open()
$sw = [System.IO.StreamWriter]::new("D:\task4_lrd_v2\build\uart.log", $true)
$end = (Get-Date).AddSeconds($Seconds)
while ((Get-Date) -lt $end) {
    try {
        $s = $p.ReadExisting()
        if ($s) { $sw.Write($s); $sw.Flush(); [Console]::Out.Write($s) }
    } catch {}
    Start-Sleep -Milliseconds 200
}
$p.Close(); $sw.Close()
