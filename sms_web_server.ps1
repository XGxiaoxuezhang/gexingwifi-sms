# ============================================
# 随身WiFi 短信 - 网页服务器（零依赖版）
# 只使用 Windows 自带的 PowerShell / .NET，无需安装 Python
# 接口与 sms_web\server.py 完全一致：
#   POST /send           追加发送队列
#   POST /delete         追加删除队列（轮询脚本用 AT+CMGD 删除）
#   POST /mark_read      标记单条已读
#   POST /mark_read_all  批量标记已读
#   POST /contacts       保存联系人备注
#   GET  /contacts       读取联系人备注
#   GET  /send_result    发送结果 {id: {status,message,ts}}
#   GET  /events         SSE 实时推送短信列表
#   其余路径按静态文件返回（含 data.json）
# ============================================

. "$PSScriptRoot\sms_common.ps1"

$cfg    = Get-SmsConfig
$Root   = Join-Path $PSScriptRoot 'sms_web'
$WebLog = Join-Path $PSScriptRoot 'logs\web.log'

$c = @{
    Root         = $Root
    Token        = "$($cfg.access_token)"
    DataPath     = Join-Path $Root 'data.json'
    QueuePath    = Join-Path $Root 'send_queue.json'
    DeletePath   = Join-Path $Root 'delete_queue.json'
    MarksPath    = Join-Path $Root 'read_marks.json'
    ContactsPath = Join-Path $Root 'contacts.json'
    ResultPath   = Join-Path $Root 'send_result.json'
    LogPath      = $WebLog
    Mime         = @{
        '.html' = 'text/html; charset=utf-8'
        '.htm'  = 'text/html; charset=utf-8'
        '.js'   = 'application/javascript; charset=utf-8'
        '.css'  = 'text/css; charset=utf-8'
        '.json' = 'application/json; charset=utf-8'
        '.png'  = 'image/png'
        '.jpg'  = 'image/jpeg'
        '.jpeg' = 'image/jpeg'
        '.gif'  = 'image/gif'
        '.svg'  = 'image/svg+xml'
        '.ico'  = 'image/x-icon'
        '.txt'  = 'text/plain; charset=utf-8'
    }
}

# 请求处理脚本块（在主运行空间或独立 runspace 中执行，必须自包含）
$handler = {
    param($ctx, $c)

    function Send-Bytes($res, [byte[]]$bytes, [string]$ctype, [int]$code = 200) {
        $res.StatusCode = $code
        if ($ctype) { $res.ContentType = $ctype }
        $res.Headers.Set('Cache-Control', 'no-store')
        $res.ContentLength64 = $bytes.LongLength
        $res.OutputStream.Write($bytes, 0, $bytes.Length)
    }

    function Send-Json($res, $obj, [int]$code = 200) {
        $json = if ($obj -is [string]) { $obj } else { ConvertTo-Json -InputObject $obj -Depth 6 -Compress }
        Send-Bytes $res ([Text.Encoding]::UTF8.GetBytes($json)) 'application/json; charset=utf-8' $code
    }

    function Read-Json([string]$p, $default) {
        try {
            if (Test-Path $p) {
                $t = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8)
                if ($t -and $t.Trim()) { return ($t | ConvertFrom-Json) }
            }
        } catch {}
        return $default
    }

    function Write-Json([string]$p, $obj) {
        $json = if ($obj -is [string]) { $obj } else { ConvertTo-Json -InputObject $obj -Depth 6 -Compress }
        [IO.File]::WriteAllText($p, $json, (New-Object Text.UTF8Encoding $false))
    }

    # 追加一条记录到 JSON 数组文件
    function Append-Queue([string]$p, $item) {
        $out = @()
        foreach ($x in @(Read-Json $p @())) { if ($null -ne $x) { $out += $x } }
        $out += $item
        Write-Json $p @($out)
    }

    function Read-Body($req) {
        try {
            if ($req.ContentLength64 -le 0) { return @{} }
            $sr = New-Object IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8)
            $text = $sr.ReadToEnd()
            $sr.Close()
            if (-not $text) { return @{} }
            return ($text | ConvertFrom-Json)
        } catch { return @{} }
    }

    function Get-AuthToken($req) {
        $t = $req.QueryString['token']
        if (-not $t) { $t = $req.Headers['X-Auth-Token'] }
        return "$t"
    }

    function Set-Contacts([string]$from, [string]$name) {
        $map = [ordered]@{}
        $raw = Read-Json $c.ContactsPath $null
        if ($raw) { foreach ($pr in $raw.PSObject.Properties) { $map[$pr.Name] = $pr.Value } }
        if ([string]::IsNullOrWhiteSpace($name)) {
            if ($map.Contains($from)) { $map.Remove($from) }
        } else {
            $map[$from] = $name
        }
        if ($map.Count -eq 0) { Write-Json $c.ContactsPath '{}' } else { Write-Json $c.ContactsPath $map }
    }

    function Read-TextFile([string]$p, [string]$default) {
        try {
            if (Test-Path $p) {
                $t = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8)
                if ($t -and $t.Trim()) { return $t }
            }
        } catch {}
        return $default
    }

    $req = $ctx.Request
    $res = $ctx.Response
    $res.KeepAlive = $false

    try {
        $path = $req.Url.AbsolutePath
        $method = $req.HttpMethod

        # 鉴权：首页与 index.html 放行（页面本身不含数据），其余需带令牌
        if ($c.Token -and $path -ne '/' -and $path -ne '/index.html') {
            if ((Get-AuthToken $req) -ne $c.Token) {
                Send-Json $res @{ ok = $false; error = 'unauthorized' } 401
                return
            }
        }

        switch ($path) {
            '/events' {
                # SSE：data.json 变化时推送给浏览器
                $res.StatusCode = 200
                $res.ContentType = 'text/event-stream; charset=utf-8'
                $res.Headers.Set('Cache-Control', 'no-store')
                $res.SendChunked = $true
                $stream = $res.OutputStream
                # 先发一个注释帧，让浏览器立刻触发 onopen
                $hello = [Text.Encoding]::UTF8.GetBytes(": connected`n`n")
                $stream.Write($hello, 0, $hello.Length)
                $stream.Flush()
                $last = ''
                while ($true) {
                    $text = ''
                    try { $text = [IO.File]::ReadAllText($c.DataPath, [Text.Encoding]::UTF8) } catch {}
                    if ($text -and $text -ne $last) {
                        $last = $text
                        $payload = 'data: ' + ($text -replace "`r?`n", '') + "`n`n"
                        $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
                        $stream.Write($bytes, 0, $bytes.Length)
                        $stream.Flush()
                    }
                    Start-Sleep -Milliseconds 800
                }
                return
            }
            '/send' {
                if ($method -ne 'POST') { Send-Json $res @{ ok = $false; error = 'method' } 405; return }
                $body = Read-Body $req
                if (-not $body.id -or -not $body.to) { Send-Json $res @{ ok = $false; error = '参数不完整' } 400; return }
                Append-Queue $c.QueuePath $body
                Send-Json $res @{ ok = $true }
                return
            }
            '/delete' {
                if ($method -ne 'POST') { Send-Json $res @{ ok = $false; error = 'method' } 405; return }
                $body = Read-Body $req
                if ($null -eq $body.index) { Send-Json $res @{ ok = $false; error = '参数不完整' } 400; return }
                Append-Queue $c.DeletePath @{ id = [guid]::NewGuid().ToString('N'); index = "$($body.index)" }
                Send-Json $res @{ ok = $true }
                return
            }
            '/mark_read' {
                if ($method -ne 'POST') { Send-Json $res @{ ok = $false; error = 'method' } 405; return }
                $body = Read-Body $req
                if ($null -ne $body.index) {
                    $now = [int64](([DateTime]::UtcNow - [DateTime]'1970-01-01').TotalMilliseconds)
                    Append-Queue $c.MarksPath @{ index = "$($body.index)"; ts = $now }
                }
                Send-Json $res @{ ok = $true }
                return
            }
            '/mark_read_all' {
                if ($method -ne 'POST') { Send-Json $res @{ ok = $false; error = 'method' } 405; return }
                $body = Read-Body $req
                $now = [int64](([DateTime]::UtcNow - [DateTime]'1970-01-01').TotalMilliseconds)
                foreach ($i in @($body.indexes)) {
                    if ($null -ne $i) { Append-Queue $c.MarksPath @{ index = "$i"; ts = $now } }
                }
                Send-Json $res @{ ok = $true }
                return
            }
            '/contacts' {
                if ($method -eq 'POST') {
                    $body = Read-Body $req
                    Set-Contacts "$($body.from)" "$($body.name)"
                    Send-Json $res @{ ok = $true }
                } else {
                    Send-Bytes $res ([Text.Encoding]::UTF8.GetBytes((Read-TextFile $c.ContactsPath '{}'))) 'application/json; charset=utf-8'
                }
                return
            }
            '/send_result' {
                Send-Bytes $res ([Text.Encoding]::UTF8.GetBytes((Read-TextFile $c.ResultPath '{}'))) 'application/json; charset=utf-8'
                return
            }
        }

        # ---------- 静态文件 ----------
        $rel = $path.TrimStart('/')
        if ([string]::IsNullOrEmpty($rel)) { $rel = 'index.html' }
        $rel = $rel -replace '/', '\'
        $rootFull = [IO.Path]::GetFullPath($c.Root)
        $full = [IO.Path]::GetFullPath((Join-Path $rootFull $rel))
        if (-not $full.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
            Send-Json $res @{ ok = $false; error = 'forbidden' } 403
            return
        }
        if (Test-Path $full -PathType Leaf) {
            $ext = [IO.Path]::GetExtension($full).ToLower()
            $ctype = if ($c.Mime.ContainsKey($ext)) { $c.Mime[$ext] } else { 'application/octet-stream' }
            Send-Bytes $res ([IO.File]::ReadAllBytes($full)) $ctype
        } else {
            Send-Json $res @{ ok = $false; error = 'not found' } 404
        }
    } catch {
        try { Send-Json $res @{ ok = $false; error = "$($_.Exception.Message)" } 500 } catch {}
    } finally {
        try { $res.Close() } catch {}
    }
}

# ---------- 启动监听 ----------
$hostName = "$($cfg.web_host)"
$port     = [int]$cfg.web_port

# http.sys 的前缀规则：localhost 与 127.0.0.1 必须分别注册（否则报 Invalid Hostname）
if ($hostName -eq '127.0.0.1' -or $hostName -eq 'localhost') {
    $prefixes = @("http://localhost:${port}/", "http://127.0.0.1:${port}/")
} else {
    # 局域网/所有地址：非管理员会被拒绝（需要 netsh urlacl 或管理员运行）
    $prefixes = @("http://+:${port}/")
}

$listener = New-Object System.Net.HttpListener
foreach ($p in $prefixes) { $listener.Prefixes.Add($p) }

try {
    $listener.Start()
} catch {
    $msg = "网页服务器无法监听 $($prefixes -join ' , ') ：$($_.Exception.Message)"
    if ($hostName -ne '127.0.0.1' -and $hostName -ne 'localhost') {
        $msg += '（监听局域网地址需要以管理员身份运行，或改用 server_engine=python，或把 web_host 改回 127.0.0.1）'
    }
    Write-Log $msg 'ERROR' $WebLog
    Write-Host $msg -ForegroundColor Red
    throw
}

Write-Host "SMS web server (PowerShell 零依赖) on http://${hostName}:${port}"
Write-Log "网页服务器(PowerShell)已启动：$($prefixes -join ' , ')" 'INFO' $WebLog

$sseJobs = New-Object System.Collections.ArrayList

try {
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()

        # 回收已断开的 SSE 任务
        foreach ($j in @($sseJobs)) {
            if ($j.async.IsCompleted) {
                try { $j.ps.Dispose() } catch {}
                $null = $sseJobs.Remove($j)
            }
        }

        if ($ctx.Request.Url.AbsolutePath -eq '/events') {
            # SSE 连接需要长期保持，放到独立 runspace，避免阻塞主循环
            $ps = [PowerShell]::Create()
            $null = $ps.AddScript($handler.ToString()).AddArgument($ctx).AddArgument($c)
            $async = $ps.BeginInvoke()
            $null = $sseJobs.Add(@{ ps = $ps; async = $async })
        } else {
            & $handler $ctx $c
        }
    }
} finally {
    try { $listener.Stop() } catch {}
    foreach ($j in @($sseJobs)) { try { $j.ps.Dispose() } catch {} }
    Write-Log '网页服务器(PowerShell)已停止' 'INFO' $WebLog
}
