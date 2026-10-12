# ============================================
# 格行随身WiFi 短信工具 - 公共模块
# 提供：配置加载、串口操作、AT 指令、UCS2 编解码、JSON 读写、日志
# 用法：在各脚本开头 dot-source 本文件
#   . "$PSScriptRoot\sms_common.ps1"
# ============================================

$script:SmsRoot = $PSScriptRoot

# ---------- 配置 ----------
function Get-SmsConfig {
    $cfg = [ordered]@{
        port             = 'COM12'
        baud             = 115200
        poll_sec         = 8
        auto_detect_port = $true
        web_host         = '127.0.0.1'
        web_port         = 8666
        server_engine    = 'auto'
        access_token     = ''
    }
    $cfgPath = Join-Path $script:SmsRoot 'config.json'
    if (Test-Path $cfgPath) {
        try {
            $j = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j.port)                        { $cfg.port = "$($j.port)" }
            if ($j.baud)                        { $cfg.baud = [int]$j.baud }
            if ($j.poll_sec)                    { $cfg.poll_sec = [int]$j.poll_sec }
            if ($null -ne $j.auto_detect_port)  { $cfg.auto_detect_port = [bool]$j.auto_detect_port }
            if ($j.web_host)                    { $cfg.web_host = "$($j.web_host)" }
            if ($j.web_port)                    { $cfg.web_port = [int]$j.web_port }
            if ($j.server_engine)               { $cfg.server_engine = "$($j.server_engine)" }
            if ($null -ne $j.access_token)      { $cfg.access_token = "$($j.access_token)" }
        } catch {
            Write-Log "config.json 解析失败，使用默认配置：$($_.Exception.Message)" 'WARN'
        }
    }
    return $cfg
}

# ---------- 日志（默认 logs\app.log，超过 1MB 自动转存） ----------
function Write-Log {
    param(
        [Parameter(Mandatory=$true)][string]$Message,
        [string]$Level = 'INFO',
        [string]$LogFile
    )
    try {
        if (-not $LogFile) { $LogFile = Join-Path $script:SmsRoot 'logs\app.log' }
        $dir = Split-Path $LogFile -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
        Add-Content -Path $LogFile -Value $line -Encoding UTF8
        $fi = Get-Item $LogFile -ErrorAction SilentlyContinue
        if ($fi -and $fi.Length -gt 1MB) {
            $bak = "$LogFile.old"
            if (Test-Path $bak) { Remove-Item $bak -Force -ErrorAction SilentlyContinue }
            Move-Item $LogFile $bak -Force -ErrorAction SilentlyContinue
        }
    } catch {}
}

# ---------- JSON 文件读写（UTF8 无 BOM，与网页端约定一致） ----------
function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    try { return Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function Write-TextFile {
    param([string]$Path, [string]$Content)
    try { [IO.File]::WriteAllText($Path, $Content, (New-Object Text.UTF8Encoding $false)) } catch {}
}

# ---------- 串口 ----------
function Open-SerialPort {
    param([string]$PortName, [int]$Baud)
    $sp = New-Object System.IO.Ports.SerialPort $PortName, $Baud, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
    $sp.ReadTimeout = 2000
    $sp.WriteTimeout = 2000
    $sp.Open()
    Start-Sleep -Milliseconds 300
    $sp.DiscardInBuffer()
    return $sp
}

function Close-SerialPort {
    param($sp)
    if ($sp) { try { $sp.Close() } catch {} }
}

# 自动探测串口：依次尝试各 COM 口发送 AT，返回第一个响应的端口名
function Find-SmsPort {
    param([int]$Baud = 115200)
    $names = @()
    try { $names = [System.IO.Ports.SerialPort]::GetPortNames() } catch {}
    $sorted = $names | Sort-Object { [regex]::Replace($_, '\D', '') }
    foreach ($p in $sorted) {
        try {
            $sp = Open-SerialPort $p $Baud
            $resp = Send-AT $sp 'AT' 500
            Close-SerialPort $sp
            if ($resp -match 'OK') {
                Write-Log "自动探测到短信设备端口：$p"
                return $p
            }
        } catch {}
    }
    return $null
}

# 打开串口并初始化：优先配置端口，失败时按开关决定是否自动探测
function Connect-SmsDevice {
    param(
        [string]$PortName,
        [int]$Baud,
        [bool]$AutoDetect = $true
    )
    if ($PortName) {
        try {
            $sp = Open-SerialPort $PortName $Baud
            $null = Send-AT $sp 'AT+CMGF=1'
            $null = Send-AT $sp 'AT+CSCS="GSM"'
            Write-Log "串口已连接：$PortName @ $Baud"
            return $sp
        } catch {
            Write-Log "打开串口 $PortName 失败：$($_.Exception.Message)" 'WARN'
            Close-SerialPort $sp
        }
    }
    if ($AutoDetect) {
        $found = Find-SmsPort $Baud
        if ($found) {
            $sp = Open-SerialPort $found $Baud
            $null = Send-AT $sp 'AT+CMGF=1'
            $null = Send-AT $sp 'AT+CSCS="GSM"'
            Write-Log "串口已连接（自动探测）：$found @ $Baud"
            return $sp
        }
    }
    throw "无法连接短信设备（端口：$PortName）"
}

# ---------- AT 指令 ----------
# 发送 AT 指令并等待完整响应
function Send-AT($sp, [string]$cmd, [int]$waitMs = 1500) {
    $sp.DiscardInBuffer()
    $sp.Write($cmd + [char]13)
    Start-Sleep -Milliseconds $waitMs
    $buf = ''
    $deadline = (Get-Date).AddMilliseconds(8000)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 150
        if ($sp.BytesToRead -gt 0) { $buf += $sp.ReadExisting() }
        if ($buf -match 'OK' -or $buf -match 'ERROR') { break }
    }
    return $buf
}

# 解析 +CMGL 响应为对象列表
function Parse-CMGL([string]$buf) {
    $result = @()
    if ($buf -match 'ERROR' -or $buf -notmatch '\+CMGL') { return $result }
    $cur = $null
    foreach ($ln in ($buf -split "`r?`n")) {
        if ($ln -match '^\+CMGL:\s*(\d+),"([^"]*)","([^"]*)"') {
            if ($cur) { $result += $cur }
            $cur = @{ Index = $matches[1]; Stat = $matches[2]; From = $matches[3]; Time = ''; Body = '' }
            if ($ln -match '",,"([^"]+)"') { $cur.Time = $matches[1] }
        } elseif ($cur -and $ln.Trim() -ne '' -and $ln -notmatch '^OK') {
            $cur.Body += $ln.Trim()
        }
    }
    if ($cur) { $result += $cur }
    return $result
}

# 查询未读短信
function Get-UnreadSMS($sp) {
    return Parse-CMGL (Send-AT $sp 'AT+CMGL="REC UNREAD"' 1300)
}

# 查询全部短信
function Get-AllSMS($sp) {
    return Parse-CMGL (Send-AT $sp 'AT+CMGL="ALL"' 1500)
}

# ---------- UCS2 编解码 ----------
# 解码 UCS2(HEX) 中文短信
# 注意：仅当内容为纯十六进制字符、长度是 4 的倍数、且含有 A-F 字母时才解码。
# 纯数字内容（如 6 位验证码）可能是明文，若按 HEX 解码会变成乱码。
function Convert-UCS2([string]$hex) {
    if ($hex -match '^[0-9A-Fa-f]+$' -and $hex.Length -gt 0 -and ($hex.Length % 4) -eq 0 -and $hex -match '[A-Fa-f]') {
        $sb = New-Object System.Text.StringBuilder
        for ($i = 0; $i -lt $hex.Length; $i += 4) {
            [void]$sb.Append([char][Convert]::ToUInt16($hex.Substring($i, 4), 16))
        }
        return $sb.ToString()
    }
    return $hex
}

# 字符串转 UCS2(HEX)，用于发送中文短信
function UCS2-Encode([string]$s) {
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $s.ToCharArray()) {
        [void]$sb.Append([Convert]::ToString([int][char]$ch, 16).PadLeft(4, '0'))
    }
    return $sb.ToString()
}

# 长短信拆分：UCS2 编码单条上限约 70 字符，超出部分拆分多条发送
function Split-SmsBody {
    param([string]$Body, [int]$Max = 70)
    $parts = @()
    if ([string]::IsNullOrEmpty($Body)) { return ,$parts }
    $chars = $Body.ToCharArray()
    for ($i = 0; $i -lt $chars.Count; $i += $Max) {
        $len = [Math]::Min($Max, $chars.Count - $i)
        $parts += -join $chars[$i..($i + $len - 1)]
    }
    return ,$parts
}

# 判断正文能否用 GSM 字符集直接发送（纯 ASCII 兼容性最好，中文必须 UCS2）
function Test-GsmSafe([string]$s) {
    return ($s -match '^[\x20-\x7E\r\n]*$')
}

# 发送一条短信（AT+CMGS）：号码按原样传入（多数模块这样最稳），正文按 GSM/UCS2 自适应；
# 若设备不给输入提示符，再用 UCS2 编码的号码重试一次。
function Send-SMS($sp, [string]$to, [string]$body) {
    $enc = if (Test-GsmSafe $body) { 'GSM' } else { 'UCS2' }
    $r = Send-SMS-Raw $sp $to $body $enc
    if ($r -ne 'NO_PROMPT') { return $r }
    Write-Log "原始号码未获得输入提示符，改用 UCS2 号码重试：$to" 'WARN'
    $r2 = Send-SMS-Raw $sp (UCS2-Encode $to) $body 'UCS2'
    if ($r2 -eq 'NO_PROMPT') {
        return '失败：设备未就绪，没有返回输入提示符（已尝试原始与 UCS2 两种号码格式）'
    }
    return $r2
}

# 真正执行一次发送；'NO_PROMPT' 是内部标记，表示设备未给出 ">" 提示符
function Send-SMS-Raw($sp, [string]$da, [string]$body, [string]$enc) {
    try {
        $null = Send-AT $sp ("AT+CSCS=`"$enc`"") 800
        $payload = if ($enc -eq 'UCS2') { UCS2-Encode $body } else { $body }
        $sp.DiscardInBuffer()
        $sp.Write("AT+CMGS=`"$da`"" + [char]13)
        $prompt = ''
        $deadline = (Get-Date).AddMilliseconds(5000)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 150
            if ($sp.BytesToRead -gt 0) { $prompt += $sp.ReadExisting() }
            if ($prompt -match '>') { break }
        }
        if ($prompt -notmatch '>') {
            $null = Send-AT $sp 'AT+CSCS="GSM"' 500
            return 'NO_PROMPT'
        }
        $sp.Write($payload + [char]0x1A)
        Start-Sleep -Milliseconds 1500
        $resp = ''
        $deadline2 = (Get-Date).AddMilliseconds(10000)
        while ((Get-Date) -lt $deadline2) {
            Start-Sleep -Milliseconds 150
            if ($sp.BytesToRead -gt 0) { $resp += $sp.ReadExisting() }
            if ($resp -match 'OK' -or $resp -match 'ERROR') { break }
        }
        $null = Send-AT $sp 'AT+CSCS="GSM"' 500
        $clean = ($resp -replace '\s+', ' ').Trim()
        if ($clean.Length -gt 160) { $clean = $clean.Substring(0, 160) }
        if ($resp -match 'ERROR') { return "失败：设备返回 $clean" }
        if ($resp -match 'OK') { return 'OK' }
        return "失败：设备无响应（$clean）"
    } catch {
        try { $null = Send-AT $sp 'AT+CSCS="GSM"' 500 } catch {}
        return "异常：$($_.Exception.Message)"
    }
}
