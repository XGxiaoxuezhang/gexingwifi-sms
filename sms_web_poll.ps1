# ============================================
# ASR 随身WiFi 短信轮询服务
# 轮询串口未读短信，实时写入 sms_web\data.json
# 同时处理网页提交的发送队列（sms_web\send_queue.json）
# 网页服务器和浏览器由 短信网页监控.bat（sms_tray.ps1）拉起
# 关闭本窗口即停止轮询
# ============================================

. "$PSScriptRoot\sms_common.ps1"

$cfg = Get-SmsConfig

$WebDir     = Join-Path $PSScriptRoot 'sms_web'
$DataPath   = Join-Path $WebDir 'data.json'
$QueuePath  = Join-Path $WebDir 'send_queue.json'
$DeletePath = Join-Path $WebDir 'delete_queue.json'
$ResultPath = Join-Path $WebDir 'send_result.json'
$MarkPath   = Join-Path $WebDir 'read_marks.json'
$LogPath    = Join-Path $PSScriptRoot 'logs\poll.log'

[Console]::Title = '随身WiFi 短信轮询服务（运行中）'

$script:smsList   = @()    # 最新在前
$script:seen      = @{}    # index|body 去重
$script:results   = @{}    # 发送结果：id -> 结果对象
$script:connected = $false
$script:sp        = $null

function Write-PollLog {
    param([string]$Message, [string]$Level = 'INFO')
    Write-Log -Message $Message -Level $Level -LogFile $LogPath
}

# ---------- 数据落盘 ----------
function Write-Data {
    if ($script:smsList.Count -eq 0) {
        $jsonText = '[]'
    } else {
        $jsonText = $script:smsList | ConvertTo-Json -Depth 4
    }
    Write-TextFile $DataPath $jsonText
}

# ---------- 发送结果（按 id 保存，避免互相覆盖） ----------
function Set-SendResult {
    param([string]$Id, [string]$Message)
    $ok = ($Message -eq 'OK')
    if ($null -eq $script:results) { $script:results = @{} }
    $script:results[$Id] = @{
        status  = $(if ($ok) { 'ok' } else { 'fail' })
        message = $Message
        ts      = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }
    # 清理 10 分钟前的记录
    $cutoff = (Get-Date).AddMinutes(-10)
    foreach ($k in @($script:results.Keys)) {
        $t = [datetime]::MinValue
        if ([datetime]::TryParse("$($script:results[$k].ts)", [ref]$t)) {
            if ($t -lt $cutoff) { $script:results.Remove($k) }
        }
    }
    # 最多保留 50 条
    if ($script:results.Count -gt 50) {
        foreach ($k in (@($script:results.Keys) | Select-Object -First ($script:results.Count - 50))) {
            $script:results.Remove($k)
        }
    }
    $jsonText = if ($script:results.Count -eq 0) { '{}' } else { $script:results | ConvertTo-Json -Depth 4 -Compress }
    Write-TextFile $ResultPath $jsonText
}

# ---------- 发送队列 ----------
# 处理发送队列：读取 send_queue.json，逐条发送，只删除本次已完成的 id
# （发送期间网页新提交的任务会被保留，不会丢失）
function Process-SendQueue {
    if (-not (Test-Path $QueuePath)) { return }
    $q = Read-JsonFile $QueuePath
    if ($null -eq $q) { return }
    $tasks = @($q)
    if ($tasks.Count -eq 0) { return }

    $doneIds = @()
    foreach ($task in $tasks) {
        if (-not $task.id) { continue }
        if (-not $task.to -and $null -eq $task.body) { $doneIds += $task.id; continue }

        Write-PollLog "发送短信至 $($task.to)（$($task.body.Length) 字）"
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] 发送短信至 $($task.to)..." -ForegroundColor Cyan

        # 长短信拆分逐条发送
        $parts = Split-SmsBody $task.body
        $final = 'OK'
        foreach ($p in $parts) {
            $msg = Send-SMS $script:sp $task.to $p
            if ($msg -ne 'OK') { $final = $msg; break }
        }

        $ok = ($final -eq 'OK')
        Set-SendResult $task.id $final
        Write-PollLog "发送结果：$final" $(if ($ok) { 'INFO' } else { 'ERROR' })
        Write-Host "    结果：$final" -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
        $doneIds += $task.id
    }

    # 重读队列，仅移除已处理的 id（避免清掉发送过程中新到达的任务）
    if ($doneIds.Count -eq 0) { return }
    $latest = Read-JsonFile $QueuePath
    $remain = @()
    if ($latest) {
        foreach ($t in @($latest)) {
            # 仅保留未处理且合法的任务（id 为空的畸形任务一并剔除）
            if ($t.id -and ($doneIds -notcontains $t.id)) { $remain += $t }
        }
    }
    $jsonText = if ($remain.Count -eq 0) { '[]' } else { $remain | ConvertTo-Json -Depth 4 -Compress }
    Write-TextFile $QueuePath $jsonText
}

# ---------- 删除短信 ----------
# 处理网页提交的删除请求（AT+CMGD），成功则从列表中移除该条
function Process-DeleteQueue {
    if (-not (Test-Path $DeletePath)) { return }
    $tasks = @(Read-JsonFile $DeletePath)
    if ($tasks.Count -eq 0) { return }

    $doneIds = @()
    $changed = $false
    foreach ($t in $tasks) {
        if ($null -eq $t -or -not $t.id) { continue }
        if ($null -eq $t.index) { $doneIds += $t.id; continue }

        $idx = "$($t.index)"
        $resp = Send-AT $script:sp "AT+CMGD=$idx" 1500
        $doneIds += $t.id
        if ($resp -match 'OK') {
            $script:smsList = @($script:smsList | Where-Object { "$($_.index)" -ne $idx })
            $changed = $true
            Write-PollLog "已删除短信 #$idx"
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] 已删除短信 #$idx" -ForegroundColor DarkYellow
        } else {
            Write-PollLog "删除短信 #$idx 失败：$resp" 'WARN'
            Write-Host "    删除失败：$resp" -ForegroundColor Red
        }
    }

    if ($changed) { Write-Data }

    if ($doneIds.Count -eq 0) { return }
    $latest = Read-JsonFile $DeletePath
    $remain = @()
    if ($latest) {
        foreach ($t in @($latest)) {
            if ($t.id -and ($doneIds -notcontains $t.id)) { $remain += $t }
        }
    }
    Write-TextFile $DeletePath $(if ($remain.Count -eq 0) { '[]' } else { $remain | ConvertTo-Json -Depth 4 -Compress })
}

# ---------- 已读标记 ----------
# 网页打开某条短信后会写入 read_marks.json，这里把对应短信标记为已读并消费掉标记
function Apply-ReadMarks {
    if (-not (Test-Path $MarkPath)) { return }
    $marks = Read-JsonFile $MarkPath
    if ($null -eq $marks) { return }
    $marks = @($marks)
    if ($marks.Count -eq 0) { return }

    $remain = @()
    $changed = $false
    foreach ($m in $marks) {
        $idx = "$($m.index)"
        $hit = $null
        foreach ($item in $script:smsList) {
            if ("$($item.index)" -eq $idx) { $hit = $item; break }   # smsList 最新在前
        }
        if ($hit) {
            if ($hit.unread) { $hit.unread = $false; $changed = $true }
        } else {
            $remain += $m   # 还没收录到，保留标记等待下次
        }
    }
    Write-TextFile $MarkPath $(if ($remain.Count -eq 0) { '[]' } else { $remain | ConvertTo-Json -Depth 4 -Compress })
    if ($changed) { Write-Data }
}

# ---------- 轮询 ----------
function Poll-NewSMS {
    $list = @(Get-UnreadSMS $script:sp)
    foreach ($s in $list) {
        $body = Convert-UCS2 $s.Body
        $key = "$($s.Index)|$body"
        if (-not $script:seen.ContainsKey($key)) {
            $script:seen[$key] = $true
            $script:smsList = @(@{ index = "$($s.Index)"; from = $s.From; time = $s.Time; body = $body; unread = $true }) + $script:smsList
            Write-PollLog "新短信：来自 $($s.From)"
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] 新短信：来自 $($s.From)" -ForegroundColor Cyan
        }
    }
    Apply-ReadMarks
    Write-Data
}

# ---------- 连接 ----------
function Connect-Device {
    $script:sp = Connect-SmsDevice -PortName $cfg.port -Baud $cfg.baud -AutoDetect $cfg.auto_detect_port
    $script:connected = $true
    Write-Host "已连接 $($script:sp.PortName) @ $($cfg.baud)" -ForegroundColor Green
}

function Load-History {
    foreach ($s in @(Get-AllSMS $script:sp)) {
        $body = Convert-UCS2 $s.Body
        $key = "$($s.Index)|$body"
        if (-not $script:seen.ContainsKey($key)) {
            $script:seen[$key] = $true
            $script:smsList += @{ index = "$($s.Index)"; from = $s.From; time = $s.Time; body = $body; unread = ("$($s.Stat)" -eq 'REC UNREAD') }
        }
    }
    Write-Data
    Write-Host "已载入 $($script:smsList.Count) 条历史短信" -ForegroundColor Green
    Write-PollLog "已载入 $($script:smsList.Count) 条历史短信"
}

# ---------- 主流程 ----------
Write-Host "随身WiFi 短信轮询服务启动，端口 $($cfg.port)，每 $($cfg.poll_sec) 秒轮询。" -ForegroundColor Green
Write-PollLog "轮询服务启动（端口 $($cfg.port)，间隔 $($cfg.poll_sec)s）"

while ($true) {
    if ($script:connected) {
        try {
            Poll-NewSMS
            Process-SendQueue
            Process-DeleteQueue
        } catch {
            Write-PollLog "串口读取异常：$($_.Exception.Message)" 'ERROR'
            Write-Host '串口读取异常，尝试重连...' -ForegroundColor Yellow
            Close-SerialPort $script:sp
            $script:connected = $false
        }
    } else {
        try {
            Connect-Device
            Load-History
        } catch {
            Write-PollLog "连接失败：$($_.Exception.Message)" 'WARN'
            Write-Host "连接失败：$($_.Exception.Message)，30 秒后重试（详见 logs\poll.log）" -ForegroundColor Yellow
            Start-Sleep -Seconds 30
            continue
        }
    }
    Start-Sleep -Seconds $cfg.poll_sec
}
