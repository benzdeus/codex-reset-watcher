param(
    [switch]$Help,
    [switch]$Check,
    [switch]$UiSmokeTest,
    [switch]$InstallShortcut,
    [switch]$UninstallShortcut
)

$ErrorActionPreference = "Stop"

$rootDir = Split-Path -Parent $PSScriptRoot
$trayScript = Join-Path $rootDir "Windows\CodexResetWatcherTray.ps1"
$distDir = Join-Path $rootDir "dist"
$shortcutName = "Codex Reset Watcher.lnk"

if (-not (Test-Path -LiteralPath $trayScript)) {
    throw "Windows tray script not found: $trayScript"
}

function Get-ShortcutTargets {
    $desktop = [Environment]::GetFolderPath("Desktop")
    $startMenu = [Environment]::GetFolderPath("Programs")
    return @(
        Join-Path $desktop $shortcutName
        Join-Path $startMenu $shortcutName
    )
}

function New-ShortcutIcon {
    Add-Type -AssemblyName System.Drawing
    Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class CodexResetWatcherShortcutNative {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool DestroyIcon(IntPtr hIcon);
}
"@

    if (-not (Test-Path -LiteralPath $distDir)) {
        New-Item -ItemType Directory -Path $distDir -Force | Out-Null
    }

    $icoPath = Join-Path $distDir "CodexResetWatcher.ico"
    if (Test-Path -LiteralPath $icoPath) {
        return $icoPath
    }

    $pngPath = Join-Path $rootDir "Assets\AppIcon.png"
    if (-not (Test-Path -LiteralPath $pngPath)) {
        return "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    }

    $bitmap = $null
    $small = $null
    $icon = $null
    $stream = $null
    $handle = [IntPtr]::Zero
    try {
        $bitmap = New-Object System.Drawing.Bitmap($pngPath)
        $small = New-Object System.Drawing.Bitmap($bitmap, 64, 64)
        $handle = $small.GetHicon()
        $icon = [System.Drawing.Icon]::FromHandle($handle)
        $stream = [System.IO.File]::Create($icoPath)
        $icon.Save($stream)
        return $icoPath
    } finally {
        if ($stream) { $stream.Dispose() }
        if ($icon) { $icon.Dispose() }
        if ($handle -ne [IntPtr]::Zero) { [CodexResetWatcherShortcutNative]::DestroyIcon($handle) | Out-Null }
        if ($small) { $small.Dispose() }
        if ($bitmap) { $bitmap.Dispose() }
    }
}

function Install-Shortcut {
    $powershellExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$trayScript`""
    $iconPath = New-ShortcutIcon
    $shell = New-Object -ComObject WScript.Shell

    foreach ($shortcutPath in Get-ShortcutTargets) {
        $folder = Split-Path -Parent $shortcutPath
        if (-not (Test-Path -LiteralPath $folder)) {
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
        }

        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = $powershellExe
        $shortcut.Arguments = $arguments
        $shortcut.WorkingDirectory = $rootDir
        $shortcut.Description = "Check Codex bonus/reset credit expiry"
        $shortcut.IconLocation = $iconPath
        $shortcut.Save()
        Write-Host "Created shortcut: $shortcutPath"
    }
}

function Uninstall-Shortcut {
    foreach ($shortcutPath in Get-ShortcutTargets) {
        if (Test-Path -LiteralPath $shortcutPath) {
            Remove-Item -LiteralPath $shortcutPath -Force
            Write-Host "Removed shortcut: $shortcutPath"
        }
    }
}

if ($Help) {
    Write-Host "Codex Reset Watcher Windows runner"
    Write-Host ""
    Write-Host "Usage:"
    Write-Host "  powershell -ExecutionPolicy Bypass -File script\build_and_run.ps1"
    Write-Host "  powershell -ExecutionPolicy Bypass -File script\build_and_run.ps1 -InstallShortcut"
    Write-Host "  powershell -ExecutionPolicy Bypass -File script\build_and_run.ps1 -UninstallShortcut"
    Write-Host "  powershell -ExecutionPolicy Bypass -File script\build_and_run.ps1 -Check"
    exit 0
}

if ($InstallShortcut) {
    Install-Shortcut
    exit 0
}

if ($UninstallShortcut) {
    Uninstall-Shortcut
    exit 0
}

if ($Check) {
    & $trayScript -Check
    exit $LASTEXITCODE
}

if ($UiSmokeTest) {
    & $trayScript -UiSmokeTest
    exit $LASTEXITCODE
}

& $trayScript
