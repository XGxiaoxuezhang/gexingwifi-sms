# ============================================
# 随身WiFi 短信监控 - 托盘常驻
# 右下角图标：双击打开网页 / 右键菜单操作
# 自动拉起：短信轮询服务 + 网页服务器（默认使用 PowerShell 零依赖版，无需 Python）
# 有未读新短信时在托盘弹出提示气泡
# ============================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

. "$PSScriptRoot\sms_common.ps1"

$cfg = Get-SmsConfig

$ScriptDir      = $PSScriptRoot
$PollScript     = Join-Path $ScriptDir 'sms_web_poll.ps1'
$WebDir         = Join-Path $ScriptDir 'sms_web'
$ServerPsScript = Join-Path $ScriptDir 'sms_web_server.ps1'
$ServerPyScript = Join-Path $WebDir 'server.py'
$DataPath       = Join-Path $WebDir 'data.json'
$TrayLog        = Join-Path $ScriptDir 'logs\tray.log'

$RunKey  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$RunName = 'WiFiSmsMonitor'

# 0.0.0.0 时浏览器要用 127.0.0.1 访问本机
$localHost = if ($cfg.web_host -eq '0.0.0.0' -or $cfg.web_host -eq '*') { '127.0.0.1' } else { $cfg.web_host }
$ProbeUrl  = "http://${localHost}:$($cfg.web_port)/"
$WebUrl    = $ProbeUrl
if ($cfg.access_token) { $WebUrl += "?token=$([uri]::EscapeDataString($cfg.access_token))" }

function Write-TrayLog {
    param([string]$Message, [string]$Level = 'INFO')
    Write-Log -Message $Message -Level $Level -LogFile $TrayLog
}

# ---------- 防重复启动 ----------
$mutex = New-Object System.Threading.Mutex($false, 'SmsTrayMonitor')
if (-not $mutex.WaitOne(0, $false)) {
    [System.Windows.Forms.MessageBox]::Show('短信监控已在运行（看右下角托盘图标）。', '提示')
    exit
}

# ---------- 网页端口占用检查 ----------
$inUse = Get-NetTCPConnection -LocalPort $cfg.web_port -State Listen -ErrorAction SilentlyContinue
if ($inUse) {
    $r = [System.Windows.Forms.MessageBox]::Show("网页端口 $($cfg.web_port) 已被占用（可能是上次未正常退出的监控程序）。`n是否强制结束占用进程并继续启动？", '端口占用', 'YesNo')
    if ($r -eq 'No') { $mutex.Dispose(); exit }
    $inUse | ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 1
}

# ---------- 局域网安全提示 ----------
if ($cfg.web_host -ne '127.0.0.1' -and $cfg.web_host -ne 'localhost' -and -not $cfg.access_token) {
    Write-TrayLog 'web_host 已开放到局域网，但 access_token 为空，建议在 config.json 中设置访问令牌' 'WARN'
    [System.Windows.Forms.MessageBox]::Show("当前 web_host = $($cfg.web_host)，已对局域网开放，但未设置访问令牌。`n建议在 config.json 中填写 access_token 以保护短信内容。", '安全提示')
}

# ---------- 选择网页服务器引擎 ----------
$pyCmd = $null
if (Get-Command py -ErrorAction SilentlyContinue) { $pyCmd = 'py' }
elseif (Get-Command python -ErrorAction SilentlyContinue) { $pyCmd = 'python' }

$script:engine = "$($cfg.server_engine)".ToLower()
if ($script:engine -ne 'powershell' -and $script:engine -ne 'python') { $script:engine = 'powershell' }
if ($script:engine -eq 'python' -and -not $pyCmd) {
    Write-TrayLog '配置要求 Python 引擎，但未找到 py/python，改用 PowerShell 内置引擎' 'WARN'
    $script:engine = 'powershell'
}
Write-TrayLog "网页服务器引擎：$($script:engine)"

# ---------- 子进程启动与管理 ----------
$script:pollProc = $null
$script:srvProc = $null
$script:pollStart = Get-Date
$script:srvStart = Get-Date
$script:pollCrashes = 0
$script:srvCrashes = 0

function Start-PollProcess {
    try {
        return Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File', $PollScript -WindowStyle Hidden -PassThru
    } catch {
        Write-TrayLog "启动轮询服务失败：$($_.Exception.Message)" 'ERROR'
        return $null
    }
}

function Start-WebProcess {
    try {
        if ($script:engine -eq 'python') {
            return Start-Process $pyCmd -ArgumentList $ServerPyScript -WindowStyle Hidden -PassThru
        }
        return Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File', $ServerPsScript -WindowStyle Hidden -PassThru
    } catch {
        Write-TrayLog "启动网页服务器失败：$($_.Exception.Message)" 'ERROR'
        return $null
    }
}

function Test-WebReady {
    param([int]$Seconds = 10)
    for ($i = 0; $i -lt ($Seconds * 2); $i++) {
        Start-Sleep -Milliseconds 500
        try {
            $null = Invoke-WebRequest -Uri $ProbeUrl -UseBasicParsing -TimeoutSec 2
            return $true
        } catch {}
    }
    return $false
}

$script:pollProc = Start-PollProcess
$script:pollStart = Get-Date
$script:srvProc = Start-WebProcess
$script:srvStart = Get-Date

$webReady = Test-WebReady 10
if (-not $webReady -and $script:engine -eq 'powershell' -and $pyCmd) {
    # PowerShell 引擎启动失败（例如本机 HttpListener 需要 URL ACL），自动降级到 Python
    Write-TrayLog 'PowerShell 网页服务器未就绪，改用 Python 引擎重试' 'WARN'
    if ($script:srvProc -and -not $script:srvProc.HasExited) { Stop-Process -Id $script:srvProc.Id -Force -ErrorAction SilentlyContinue }
    $script:engine = 'python'
    $script:srvProc = Start-WebProcess
    $script:srvStart = Get-Date
    $webReady = Test-WebReady 10
}

# ---------- 托盘图标 ----------
$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = [System.Drawing.SystemIcons]::Application
$tray.Text = '随身WiFi 短信监控'
$tray.Visible = $true

# ---------- 开机自启 ----------
function Test-AutoStart {
    try {
        $v = (Get-ItemProperty -Path $RunKey -Name $RunName -ErrorAction SilentlyContinue).$RunName
        return [bool]$v
    } catch { return $false }
}

function Set-AutoStart([bool]$Enable) {
    try {
        if ($Enable) {
            $cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptDir\sms_tray.ps1`""
            Set-ItemProperty -Path $RunKey -Name $RunName -Value $cmd
        } else {
            Remove-ItemProperty -Path $RunKey -Name $RunName -ErrorAction SilentlyContinue
        }
        return $true
    } catch {
        Write-TrayLog "设置开机自启失败：$($_.Exception.Message)" 'ERROR'
        return $false
    }
}

# ---------- 右键菜单 ----------
$menu = New-Object System.Windows.Forms.ContextMenuStrip

$itemOpen = New-Object System.Windows.Forms.ToolStripMenuItem
$itemOpen.Text = '打开短信网页'
$itemOpen.Add_Click({ Start-Process $WebUrl })
$menu.Items.Add($itemOpen) | Out-Null

$itemFolder = New-Object System.Windows.Forms.ToolStripMenuItem
$itemFolder.Text = '打开程序目录'
$itemFolder.Add_Click({ Start-Process explorer.exe $ScriptDir })
$menu.Items.Add($itemFolder) | Out-Null

$itemAuto = New-Object System.Windows.Forms.ToolStripMenuItem
$itemAuto.Text = '开机自动启动'
$itemAuto.CheckOnClick = $true
$itemAuto.Checked = Test-AutoStart
$itemAuto.Add_Click({
    if (-not (Set-AutoStart $itemAuto.Checked)) {
        $itemAuto.Checked = -not $itemAuto.Checked
        [System.Windows.Forms.MessageBox]::Show('设置开机自启失败，详见 logs\tray.log', '提示')
    }
})
$menu.Items.Add($itemAuto) | Out-Null

$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

$itemExit = New-Object System.Windows.Forms.ToolStripMenuItem
$itemExit.Text = '退出监控'
$itemExit.Add_Click({
    $tray.Visible = $false
    $timer.Stop()
    if ($script:srvProc -and -not $script:srvProc.HasExited) { Stop-Process -Id $script:srvProc.Id -Force -ErrorAction SilentlyContinue }
    if ($script:pollProc -and -not $script:pollProc.HasExited) { Stop-Process -Id $script:pollProc.Id -Force -ErrorAction SilentlyContinue }
    Write-TrayLog '用户退出监控'
    [System.Windows.Forms.Application]::Exit()
})
$menu.Items.Add($itemExit) | Out-Null

$tray.ContextMenuStrip = $menu
$tray.Add_MouseDoubleClick({ Start-Process $WebUrl })

# ---------- 状态监视（子进程存活 + 新短信提醒） ----------
$script:lastUnread = -1

function Update-UnreadState {
    $list = Read-JsonFile $DataPath
    if ($null -eq $list) { return }
    $unread = @($list | Where-Object { $_.unread })
    $n = $unread.Count

    $text = "随身WiFi 短信监控 · 未读 $n"
    if ($text.Length -gt 63) { $text = $text.Substring(0, 63) }
    if ($tray.Text -ne $text) { $tray.Text = $text }

    if ($script:lastUnread -ge 0 -and $n -gt $script:lastUnread) {
        $top = $unread[0]
        $preview = "$($top.from)：$($top.body)"
        $preview = $preview -replace '\s+', ' '
        if ($preview.Length -gt 60) { $preview = $preview.Substring(0, 60) + '…' }
        $tray.ShowBalloonTip(4000, '新短信', $preview, [System.Windows.Forms.ToolTipIcon]::Info)
    }
    $script:lastUnread = $n
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 2000
$timer.Add_Tick({
    # 监管轮询服务
    if ($script:pollProc -and $script:pollProc.HasExited) {
        $alive = ((Get-Date) - $script:pollStart).TotalSeconds
        if ($alive -gt 30) { $script:pollCrashes = 0 }
        if ($script:pollCrashes -lt 5) {
            $script:pollCrashes++
            Write-TrayLog "轮询服务已退出（code $($script:pollProc.ExitCode)），重启第 $($script:pollCrashes) 次" 'WARN'
            $script:pollProc = Start-PollProcess
            $script:pollStart = Get-Date
        } elseif ($script:pollCrashes -eq 5) {
            $script:pollCrashes++
            Write-TrayLog '轮询服务反复退出，已停止自动重启，请查看 logs\poll.log' 'ERROR'
            $tray.ShowBalloonTip(5000, '监控异常', '轮询服务反复退出，已停止自动重启，请查看 logs\poll.log', [System.Windows.Forms.ToolTipIcon]::Warning)
        }
    }
    # 监管网页服务器
    if ($script:srvProc -and $script:srvProc.HasExited) {
        $alive = ((Get-Date) - $script:srvStart).TotalSeconds
        if ($alive -gt 30) { $script:srvCrashes = 0 }
        if ($script:srvCrashes -lt 5) {
            $script:srvCrashes++
            Write-TrayLog "网页服务器已退出（code $($script:srvProc.ExitCode)），重启第 $($script:srvCrashes) 次" 'WARN'
            $script:srvProc = Start-WebProcess
            $script:srvStart = Get-Date
        }
    }
    try { Update-UnreadState } catch {}
})
$timer.Start()

# ---------- 打开浏览器 ----------
if ($webReady) {
    try { Start-Process $WebUrl } catch {}
} else {
    Write-TrayLog "网页服务器未就绪（$ProbeUrl），请在 config.json 中把 server_engine 设为 python 并安装 Python 后重试" 'ERROR'
    $tray.ShowBalloonTip(6000, '网页打不开', '网页服务器未启动成功，短信轮询仍在运行。详见 logs\tray.log', [System.Windows.Forms.ToolTipIcon]::Warning)
}
Update-UnreadState

Write-TrayLog "托盘监控启动（引擎 $($script:engine)，端口 $($cfg.web_port)）"
[System.Windows.Forms.Application]::Run()
