#Requires -Version 5.1
<#
  Sobe o emulador Android, instala o app e abre a tela principal.

  Uso:
    .\scripts\run-app.ps1                        # fluxo completo (emulador -> build -> install -> abrir app)
    .\scripts\run-app.ps1 -GrantPermissions      # + concede as permissoes de saude via adb
    .\scripts\run-app.ps1 -SkipBuild             # so abre o app (emulador ja rodando)
    .\scripts\run-app.ps1 -Avd OutraAvd          # usa outra AVD
#>
param(
    [string]$Avd = "DiarioAmarApi36",
    [switch]$SkipBuild,
    [switch]$GrantPermissions,
    [int]$BootTimeoutSec = 300
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$script:started = Get-Date

function Elapsed { return ("{0:N0}s" -f ((Get-Date) - $script:started).TotalSeconds) }
function Step($n, $msg) { Write-Host "[$n][t=$(Elapsed)] $msg" -ForegroundColor Cyan }
function Ok($msg)       { Write-Host "     [t=$(Elapsed)] $msg" -ForegroundColor Green }
function Warn($msg)     { Write-Host "     AVISO: $msg" -ForegroundColor Yellow }
function Fail($msg)     { Write-Host "[ERRO] $msg" -ForegroundColor Red; exit 1 }

# ---------- 1. SDK ----------
$sdk = $null
$lp = Join-Path $root "local.properties"
if (Test-Path $lp) {
    $m = Select-String -Path $lp -Pattern '^sdk\.dir\s*=\s*(.+)$'
    if ($m) { $sdk = (($m.Matches[0].Groups[1].Value -replace '\\:', ':') -replace '\\\\', '\').TrimEnd('\') }
}
if (-not $sdk) { $sdk = $env:ANDROID_HOME }
if (-not $sdk) { $sdk = $env:ANDROID_SDK_ROOT }
if (-not $sdk) { $sdk = Join-Path $env:LOCALAPPDATA "Android\Sdk" }
$sdk = $sdk.TrimEnd('\')
if (-not (Test-Path (Join-Path $sdk "platform-tools"))) { Fail "SDK Android nao encontrado em: $sdk" }

$adb      = Join-Path $sdk "platform-tools\adb.exe"
$emulator = Join-Path $sdk "emulator\emulator.exe"
$avdmgr   = Join-Path $sdk "cmdline-tools\latest\bin\avdmanager.bat"
$env:ANDROID_HOME = $sdk
$env:PATH = "$sdk\platform-tools;$sdk\emulator;$sdk\cmdline-tools\latest\bin;$env:PATH"

if (-not (Test-Path $lp)) {
    $esc = $sdk -replace '\\', '\\' -replace ':', '\:'
    Set-Content -Path $lp -Value "sdk.dir=$esc" -Encoding ASCII
}

# adb sem deixar o ErrorActionPreference=Stop derrubar o script no stderr nativo
function Invoke-Adb {
    $eap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try { return (& $adb @args 2>&1) } finally { $ErrorActionPreference = $eap }
}

function Get-AdbDevice {
    foreach ($line in (Invoke-Adb devices)) {
        if ("$line" -match '^(\S+)\s+device\s*$') { return $Matches[1] }
    }
    return $null
}

# ---------- 2. Dispositivo conectado ----------
Step "1/5" "Verificando dispositivo/emulador..."
$device = Get-AdbDevice
$startedEmulator = $false

if (-not $device) {
    # so considera AVDs locais reais (ignora .ini de outros workspaces)
    $existing = @()
    $avdDir = Join-Path $env:USERPROFILE ".android\avd"
    if (Test-Path $avdDir) {
        $existing = @(Get-ChildItem $avdDir -Directory -Filter "*.avd" | ForEach-Object { $_.Name -replace '\.avd$', '' })
    }

    if ($existing -notcontains $Avd) {
        if ($existing.Count -gt 0) {
            Warn "AVD '$Avd' nao existe; usando '$($existing[0])'"
            $Avd = $existing[0]
        } else {
            Step "1/5" "Criando AVD '$Avd' (android-36 google_apis)..."
            if (-not (Test-Path $avdmgr)) { Fail "avdmanager nao encontrado em $avdmgr" }
            "no" | & $avdmgr create avd --force --name $Avd --package "system-images;android-36;google_apis;x86_64" --device pixel_6
            if ($LASTEXITCODE -ne 0) { Fail "Falha ao criar a AVD" }
            Ok "AVD criada: $Avd"
        }
    }

    if (-not (Test-Path $emulator)) { Fail "emulator.exe nao encontrado em $emulator" }
    Step "1/5" "Iniciando emulador: $Avd"
    Start-Process -FilePath $emulator -ArgumentList @("-avd", $Avd, "-no-snapshot-save", "-no-boot-anim")
    $startedEmulator = $true
} else {
    Ok "Ja ha um dispositivo ativo: $device"
}

# ---------- 3. Espera do boot ----------
if ($startedEmulator) {
    Step "2/5" "Aguardando boot do emulador (max ${BootTimeoutSec}s)..."
    $deadline = (Get-Date).AddSeconds($BootTimeoutSec)
    $booted = $false
    while ((Get-Date) -lt $deadline) {
        if (Get-AdbDevice) {
            $prop = ((Invoke-Adb shell getprop sys.boot_completed) | Out-String).Trim()
            if ($prop -eq "1") { $booted = $true; break }
        } else {
            $emuProc = Get-Process -Name "emulator","qemu-system-*" -ErrorAction SilentlyContinue
            if (-not $emuProc) { Fail "O processo do emulador encerrou inesperadamente" }
        }
        Start-Sleep -Seconds 2
    }
    if (-not $booted) { Fail "Emulador nao terminou de iniciar em ${BootTimeoutSec}s" }
    Ok "Boot concluido"
    $device = Get-AdbDevice
    if (-not $device) { Fail "Nenhum dispositivo visivel apos o boot" }
} else {
    Step "2/5" "Boot: ja havia dispositivo ativo, seguindo"
}

# ---------- 4. Build + install ----------
if (-not $SkipBuild) {
    Step "3/5" "Build + installDebug..."
    $gradlew = Join-Path $root "gradlew.bat"
    if (-not (Test-Path $gradlew)) { Fail "gradlew.bat nao encontrado" }
    Push-Location $root
    try { & cmd /c "`"$gradlew`" installDebug" }
    finally { Pop-Location }
    if ($LASTEXITCODE -ne 0) { Fail "Falha no build/install (exit $LASTEXITCODE)" }
    Ok "App instalado"
} else {
    Step "3/5" "Build ignorado (-SkipBuild)"
}

# ---------- 5. Permissoes (antes de abrir, senao a tela de rationale abre) ----------
if ($GrantPermissions) {
    Step "4/5" "Concedendo permissoes de saude..."
    $perms = @(
        "android.permission.health.READ_STEPS",
        "android.permission.health.READ_SLEEP",
        "android.permission.health.READ_RESTING_HEART_RATE",
        "android.permission.health.READ_ACTIVE_CALORIES_BURNED",
        "android.permission.health.READ_TOTAL_CALORIES_BURNED",
        "android.permission.health.READ_DISTANCE",
        "android.permission.health.READ_WEIGHT",
        "android.permission.health.READ_HEALTH_DATA_HISTORY",
        "android.permission.health.READ_HEALTH_DATA_IN_BACKGROUND"
    )
    foreach ($p in $perms) { Invoke-Adb shell pm grant com.homefelipev.healthcoach $p | Out-Null }
    Ok "Permissoes concedidas"
    # o Health Connect leva alguns segundos para refletir o grant; abrir antes mostra estado defasado
    Start-Sleep -Seconds 4
} else {
    Step "4/5" "Permissoes nao concedidas (use -GrantPermissions para pular o fluxo de consentimento)"
}

# ---------- 6. Abre a tela principal ----------
Step "5/5" "Abrindo a tela principal..."
Invoke-Adb logcat -c | Out-Null
# relanca do zero: com a instancia antiga viva o app fica com estado de permissao defasado
Invoke-Adb shell am force-stop com.homefelipev.healthcoach | Out-Null
$launch = (Invoke-Adb shell am start -n "com.homefelipev.healthcoach/.ui.MainActivity") -join "`n"
if ($LASTEXITCODE -ne 0 -or $launch -match "Error|Exception") {
    Fail "Nao foi possivel abrir o app:`n$launch"
}
Ok "App aberto no emulador"

# traz a janela do emulador para frente
try {
    Add-Type @"
using System;using System.Runtime.InteropServices;
public class Win32 { [DllImport("user32.dll")] public static bool SetForegroundWindow(IntPtr h); }
"@ -ErrorAction SilentlyContinue
    $win = Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne 0 -and ($_.ProcessName -match "qemu|emulator|crashpad" -or $_.MainWindowTitle -match [regex]::Escape($Avd)) } |
        Select-Object -First 1
    if ($win) { [Win32]::SetForegroundWindow($win.MainWindowHandle) | Out-Null }
} catch { }

# ---------- 7. Checagens de sanidade ----------
Write-Host "[check] Health Connect..." -ForegroundColor Cyan
$pkgs = (Invoke-Adb shell pm list packages) -join "`n"
$hasHealthConnect = ($pkgs -match "com\.google\.android\.apps\.healthdata") -or
                    ($pkgs -match "com\.google\.android\.healthconnect\.controller")
if (-not $hasHealthConnect) {
    Warn "Health Connect nao esta neste sistema; as permissoes de saude nao funcionarao."
} else {
    Ok "Health Connect disponivel"
}

$err = ((Invoke-Adb logcat -d -s AndroidRuntime:E) | Select-Object -Last 30) -join "`n"
if ($err -match "com\.homefelipev\.healthcoach") {
    Warn "Erros recentes do app no logcat:"
    Write-Host $err -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Pronto em $(Elapsed): app instalado e aberto no emulador ($device)." -ForegroundColor Green
exit 0
