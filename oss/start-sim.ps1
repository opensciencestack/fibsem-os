<#
Starts (or restarts) the fibsem-os simulator on this Windows host and exposes it on
the host's network address. Run as administrator; safe to run on every deploy.

    .\oss\start-sim.ps1 [-Config quattro-s-sim-configuration] [-Port 8001]

Every YAML in oss\configs is registered, so a client can switch between them with
POST /microscope/disconnect and POST /microscope/connect {"configuration": "<name>"};
-Config picks the one the server starts with.

The server runs with FIBSEM_SIM_NO_BLOCKLIST=1, so a client may vent, pump, link
the stage and switch beams on the simulated microscope.

Set FIBSEM_OPERATOR_TOKEN to pin the operator token, the bearer token OSS apps send.
Without it the server keeps the token in <State>\operator-token.json, or makes one.
#>
param(
    [string]$Config = 'quattro-s-sim-configuration',
    [int]$Port = 8001,
    [string]$State = 'C:\fibsem-state'
)
$ErrorActionPreference = 'Stop'

$repo = Split-Path $PSScriptRoot -Parent
$exe = Join-Path $repo '.venv\Scripts\fibsem-autolamella-server.exe'
$python = Join-Path $repo '.venv\Scripts\python.exe'
$configs = Join-Path $PSScriptRoot 'configs'
$configPath = Join-Path $configs "$Config.yaml"
$task = "fibsem-sim-$Port"
$log = Join-Path $State "server-$Port"

foreach ($p in $exe, $python, $configPath) {
    if (-not (Test-Path $p)) { throw "$p not found" }
}

# Stop whatever serves this port: the task, or a server someone started by hand.
Stop-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
Get-NetTCPConnection -State Listen -LocalAddress 127.0.0.1 -LocalPort $Port -ErrorAction SilentlyContinue |
    ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue }

# The state folder holds the operator token: SYSTEM and Administrators only.
New-Item -ItemType Directory -Force $State | Out-Null
icacls $State /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null

if ($env:FIBSEM_OPERATOR_TOKEN) {
    @{ token = $env:FIBSEM_OPERATOR_TOKEN; person = $null } | ConvertTo-Json |
        Set-Content -Encoding ascii (Join-Path $State 'operator-token.json')
}

# The server reads its configuration list once at start, so register before starting.
$env:FIBSEM_HOME = $State
$register = 'import sys; from fibsem import config; [config.register_configuration(p) for p in sys.argv[2:]]; config.set_default_configuration(config.register_configuration(sys.argv[1]))'
$all = @(Get-ChildItem $configs -Filter *.yaml | ForEach-Object FullName)
& $python -I -c $register $configPath @all
if ($LASTEXITCODE -ne 0) { throw "registering the configurations failed" }

$run = "cd /d `"$configs`" && set FIBSEM_HOME=$State&& set FIBSEM_SIM_NO_BLOCKLIST=1&& `"$exe`" --config `"$configPath`" --serve-microscope " +
       "--port $Port --discovery `"$State\app-server-$Port.json`" >> `"$log.out.log`" 2>> `"$log.err.log`""
Register-ScheduledTask -TaskName $task -Force `
    -Action (New-ScheduledTaskAction -Execute 'cmd.exe' -Argument "/s /c `"$run`"") `
    -Trigger (New-ScheduledTaskTrigger -AtStartup) `
    -Principal (New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest) `
    -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 `
        -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries) | Out-Null

# The server listens on 127.0.0.1 only; forward the host's own address to it.
$ip = @((Get-NetIPConfiguration | Where-Object IPv4DefaultGateway | Select-Object -First 1).IPv4Address)[0].IPAddress
netsh interface portproxy delete v4tov4 listenaddress=$ip listenport=$Port 2>&1 | Out-Null
netsh interface portproxy add v4tov4 listenaddress=$ip listenport=$Port connectaddress=127.0.0.1 connectport=$Port | Out-Null
Set-Service iphlpsvc -StartupType Automatic
Start-Service iphlpsvc
if (-not (Get-NetFirewallRule -DisplayName "fibsem $Port" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName "fibsem $Port" -Direction Inbound -Protocol TCP -LocalPort $Port `
        -Action Allow -Profile Any | Out-Null
}

Start-ScheduledTask -TaskName $task
$deadline = (Get-Date).AddSeconds(90)
do {
    Start-Sleep 3
    try { $up = (Invoke-RestMethod "http://127.0.0.1:$Port/health" -TimeoutSec 3).status -eq 'ok' } catch { $up = $false }
} until ($up -or (Get-Date) -gt $deadline)

if (-not $up) {
    Get-Content "$log.err.log" -Tail 20 -ErrorAction SilentlyContinue
    throw "the simulator did not answer /health on port $Port within 90 s; logs: $log.*.log"
}
"Simulator up on http://${ip}:$Port with $Config; logs in $log.*.log"
