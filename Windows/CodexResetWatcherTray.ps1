param(
    [switch]$Help,
    [switch]$Check,
    [switch]$UiSmokeTest
)

$ErrorActionPreference = "Stop"

if ($Help) {
    Write-Host "Codex Reset Watcher Windows tray"
    Write-Host ""
    Write-Host "Usage:"
    Write-Host "  powershell -ExecutionPolicy Bypass -File script\build_and_run.ps1"
    Write-Host "  powershell -ExecutionPolicy Bypass -File script\build_and_run.ps1 -Check"
    Write-Host ""
    Write-Host "Shows Codex usage limits plus banked bonus/reset credit expiry."
    Write-Host "The window stays open until you hide or quit it, and includes a Windows startup setting."
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class CodexResetWatcherNative {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool DestroyIcon(IntPtr hIcon);

    [DllImport("dwmapi.dll", PreserveSig = true)]
    public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);
}
"@

[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

$script:RootDir = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:ResetCreditsEndpoint = "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits"
$script:UsageEndpoint = "https://chatgpt.com/backend-api/wham/usage"
$script:State = $null
$script:Form = $null
$script:Content = $null
$script:NotifyIcon = $null
$script:IsQuitting = $false
$script:IsRendering = $false
$script:StartupRunName = "Codex Reset Watcher"
$script:StartupRunKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$script:SettingsDir = Join-Path $env:APPDATA "Codex Reset Watcher"
$script:SettingsPath = Join-Path $script:SettingsDir "settings.json"
$script:WindowWidth = 820
$script:WindowHeight = 760
$script:PageMargin = 16
$script:ColumnGap = 12
$script:FullWidth = 788
$script:ColumnWidth = 388

function New-Color {
    param([int]$Hex)
    return [System.Drawing.Color]::FromArgb(255, (($Hex -shr 16) -band 255), (($Hex -shr 8) -band 255), ($Hex -band 255))
}

$script:Palette = @{
    Background = New-Color 0x101114
    Card = New-Color 0x191B20
    CardElevated = New-Color 0x20232A
    Text = New-Color 0xF4F4F5
    Muted = New-Color 0xA1A1AA
    Subtle = New-Color 0x71717A
    Border = New-Color 0x2C313A
    Button = New-Color 0x272B34
    ButtonHover = New-Color 0x313642
    Blue = New-Color 0x60A5FA
    Green = New-Color 0x22C55E
    Amber = New-Color 0xF59E0B
    Red = New-Color 0xF43F5E
    RedTint = New-Color 0x2A151D
    AmberTint = New-Color 0x2B2112
}

function New-Font {
    param(
        [float]$Size,
        [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Regular
    )
    return New-Object System.Drawing.Font("Segoe UI", $Size, $Style, [System.Drawing.GraphicsUnit]::Point)
}

function Get-JsonValue {
    param([object]$Object, [string[]]$Names)
    if ($null -eq $Object) { return $null }
    foreach ($name in $Names) {
        $property = $Object.PSObject.Properties[$name]
        if ($null -ne $property) { return $property.Value }
    }
    return $null
}

function ConvertTo-Text {
    param([object]$Value)
    if ($null -eq $Value) { return $null }
    $text = ([string]$Value).Trim()
    if ($text.Length -eq 0) { return $null }
    return $text
}

function ConvertTo-Int {
    param([object]$Value)
    if ($null -eq $Value) { return $null }
    $parsed = 0
    if ([int]::TryParse(([string]$Value).Trim(), [ref]$parsed)) { return $parsed }
    return $null
}

function ConvertTo-Double {
    param([object]$Value)
    if ($null -eq $Value) { return $null }
    $parsed = 0.0
    if ([double]::TryParse(
        ([string]$Value).Trim(),
        [System.Globalization.NumberStyles]::Float,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [ref]$parsed
    )) {
        if (-not [double]::IsNaN($parsed) -and -not [double]::IsInfinity($parsed)) {
            return $parsed
        }
    }
    return $null
}

function ConvertFrom-Base64Url {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $base64 = $Value.Replace("-", "+").Replace("_", "/")
    switch ($base64.Length % 4) {
        2 { $base64 += "==" }
        3 { $base64 += "=" }
        0 { }
        default { return $null }
    }
    try {
        return [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($base64))
    } catch {
        return $null
    }
}

function Get-JwtPayload {
    param([string]$Token)
    if ([string]::IsNullOrWhiteSpace($Token)) { return $null }
    $parts = $Token.Split(".")
    if ($parts.Length -lt 2) { return $null }
    $json = ConvertFrom-Base64Url $parts[1]
    if ($null -eq $json) { return $null }
    try {
        return $json | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Get-CodexHome {
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        return [System.Environment]::ExpandEnvironmentVariables($env:CODEX_HOME)
    }
    return Join-Path $HOME ".codex"
}

function Get-AuthContext {
    $authPath = Join-Path (Get-CodexHome) "auth.json"
    if (-not (Test-Path -LiteralPath $authPath)) {
        throw "No Codex login found. Sign in to Codex Desktop first."
    }

    try {
        $auth = Get-Content -LiteralPath $authPath -Raw | ConvertFrom-Json
    } catch {
        throw "Could not read Codex login. Sign in to Codex Desktop again."
    }

    $tokens = Get-JsonValue $auth @("tokens")
    $accessToken = ConvertTo-Text (Get-JsonValue $tokens @("access_token", "accessToken"))
    if ([string]::IsNullOrWhiteSpace($accessToken)) {
        throw "Codex login has no access token. Sign in to Codex Desktop again."
    }

    $idToken = ConvertTo-Text (Get-JsonValue $tokens @("id_token", "idToken"))
    $fallbackAccountId = ConvertTo-Text (Get-JsonValue $tokens @("account_id", "accountId"))
    $idPayload = Get-JwtPayload $idToken
    $accessPayload = Get-JwtPayload $accessToken
    $idAuth = Get-JsonValue $idPayload @("https://api.openai.com/auth")
    $accessAuth = Get-JsonValue $accessPayload @("https://api.openai.com/auth")

    $accountId = ConvertTo-Text (Get-JsonValue $idAuth @("chatgpt_account_id"))
    if ([string]::IsNullOrWhiteSpace($accountId)) {
        $accountId = ConvertTo-Text (Get-JsonValue $accessAuth @("chatgpt_account_id"))
    }
    if ([string]::IsNullOrWhiteSpace($accountId)) {
        $accountId = $fallbackAccountId
    }

    $label = ConvertTo-Text (Get-JsonValue $idPayload @("email"))
    if ([string]::IsNullOrWhiteSpace($label)) {
        $label = ConvertTo-Text (Get-JsonValue $idPayload @("name"))
    }
    if ([string]::IsNullOrWhiteSpace($label)) {
        $label = "Codex account"
    }

    return [pscustomobject]@{
        AccessToken = $accessToken
        AccountId = $accountId
        Label = $label
    }
}

function Test-Endpoint {
    param([string]$Url)
    try {
        $uri = [System.Uri]$Url
    } catch {
        return $false
    }
    return $uri.Scheme -eq "https" -and
        $uri.Host -eq "chatgpt.com" -and
        $uri.IsDefaultPort -and
        [string]::IsNullOrEmpty($uri.UserInfo) -and
        [string]::IsNullOrEmpty($uri.Query) -and
        [string]::IsNullOrEmpty($uri.Fragment) -and
        (
            $uri.AbsolutePath -eq "/backend-api/wham/rate-limit-reset-credits" -or
            $uri.AbsolutePath -eq "/backend-api/wham/usage"
        )
}

function Invoke-CodexJson {
    param(
        [object]$Context,
        [string]$Url
    )

    if (-not (Test-Endpoint $Url)) {
        throw "Codex endpoint is not trusted."
    }

    $headers = @{
        Authorization = "Bearer $($Context.AccessToken)"
        originator = "Codex Desktop"
        "OAI-Product-Sku" = "CODEX"
        Accept = "application/json"
    }
    if (-not [string]::IsNullOrWhiteSpace($Context.AccountId)) {
        $headers["ChatGPT-Account-Id"] = $Context.AccountId
    }

    try {
        $response = Invoke-WebRequest -Uri $Url -Method Get -Headers $headers -TimeoutSec 20 -UseBasicParsing
    } catch {
        $status = $null
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
            $status = [int]$_.Exception.Response.StatusCode
        }
        if ($status -eq 401 -or $status -eq 403) { throw "Codex rejected the saved login." }
        if ($status -eq 429) { throw "Codex rate-limited this check." }
        if ($status) { throw "Codex returned HTTP $status." }
        throw "Could not reach Codex."
    }

    if ([string]::IsNullOrWhiteSpace($response.Content)) {
        throw "Codex returned an empty response."
    }

    try {
        return $response.Content | ConvertFrom-Json
    } catch {
        throw "Codex returned JSON this runner could not decode."
    }
}

function Invoke-ResetCredits {
    param([object]$Context)
    return Invoke-CodexJson $Context $script:ResetCreditsEndpoint
}

function Invoke-Usage {
    param([object]$Context)
    return Invoke-CodexJson $Context $script:UsageEndpoint
}

function ConvertFrom-IsoDate {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $parsed = [System.DateTimeOffset]::MinValue
    if ([System.DateTimeOffset]::TryParse(
        $Value,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::AssumeUniversal,
        [ref]$parsed
    )) {
        return $parsed.LocalDateTime
    }
    return $null
}

function Convert-Credits {
    param([object]$Response)

    $items = Get-JsonValue $Response @("credits")
    if ($null -eq $items) {
        $items = @()
    } elseif ($items -isnot [System.Array]) {
        $items = @($items)
    }

    $credits = @()
    foreach ($item in $items) {
        $status = ConvertTo-Text (Get-JsonValue $item @("status"))
        if ($null -eq $status) { $status = "unknown" }
        if (-not $status.Equals("available", [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        $id = ConvertTo-Text (Get-JsonValue $item @("id"))
        if ($null -eq $id) { $id = [guid]::NewGuid().ToString("n") }
        $expiresRaw = ConvertTo-Text (Get-JsonValue $item @("expires_at", "expiresAt"))
        $expiresAt = ConvertFrom-IsoDate $expiresRaw

        $credits += [pscustomobject]@{
            Id = $id
            ExpiresAt = $expiresAt
            ExpiresAtRaw = $expiresRaw
        }
    }

    $availableCount = ConvertTo-Int (Get-JsonValue $Response @("available_count", "availableCount"))
    if ($null -eq $availableCount) {
        $availableCount = $credits.Count
    }

    $credits = @($credits | Sort-Object @{ Expression = {
        if ($_.ExpiresAt) { $_.ExpiresAt } else { [datetime]::MaxValue }
    }}, Id)

    return [pscustomobject]@{
        AvailableCount = [int]$availableCount
        Credits = $credits
    }
}

function Get-WindowTitle {
    param([object]$LimitSeconds)

    if ($null -eq $LimitSeconds) {
        return "Usage limit"
    }

    if ($LimitSeconds -ge 14400 -and $LimitSeconds -le 21600) {
        return "5 hour usage limit"
    }

    if ($LimitSeconds -ge 518400 -and $LimitSeconds -le 864000) {
        return "Weekly usage limit"
    }

    if ($LimitSeconds -ge 86400) {
        $days = [math]::Max(1, [int]($LimitSeconds / 86400))
        return "$days day usage limit"
    }

    $hours = [math]::Max(1, [int]($LimitSeconds / 3600))
    return "$hours hour usage limit"
}

function ConvertTo-ResetDate {
    param(
        [object]$ResetAt,
        [object]$ResetAfterSeconds
    )

    $epoch = ConvertTo-Double $ResetAt
    if ($null -ne $epoch) {
        if ($epoch -gt 10000000000) {
            $epoch = $epoch / 1000
        }
        if ($epoch -ge 1577836800 -and $epoch -le 4102444800) {
            try {
                return [System.DateTimeOffset]::FromUnixTimeSeconds([int64][math]::Floor($epoch)).LocalDateTime
            } catch {
            }
        }
    }

    $after = ConvertTo-Int $ResetAfterSeconds
    if ($null -ne $after) {
        return (Get-Date).AddSeconds([math]::Max(0, $after))
    }

    return $null
}

function Format-UsageReset {
    param([object]$Date)

    if ($null -eq $Date) {
        return "Reset time unavailable"
    }

    $date = [datetime]$Date
    if ($date.Date -eq (Get-Date).Date) {
        return "Resets " + $date.ToString("h:mm tt", [System.Globalization.CultureInfo]::GetCultureInfo("en-US"))
    }

    return "Resets " + $date.ToString("MMM d, yyyy h:mm tt", [System.Globalization.CultureInfo]::GetCultureInfo("en-US"))
}

function Format-UsagePrefix {
    param([string]$Value)

    $text = ConvertTo-Text $Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    $text = $text -replace "_", "-"
    $parts = @($text -split "-" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($parts.Count -eq 0) {
        return $null
    }

    $pretty = @()
    foreach ($part in $parts) {
        if ($part -match "^[0-9.]+$") {
            $pretty += $part
        } elseif ($part.Equals("gpt", [System.StringComparison]::OrdinalIgnoreCase)) {
            $pretty += "GPT"
        } else {
            $pretty += $part.Substring(0, 1).ToUpperInvariant() + $part.Substring(1).ToLowerInvariant()
        }
    }

    return ($pretty -join "-")
}

function Get-UsagePrefixFromPath {
    param([string[]]$Path)

    $skip = @(
        "rate_limit", "rateLimit", "primary_window", "primaryWindow", "secondary_window", "secondaryWindow",
        "windows", "usage", "limits", "items", "data", "rate_limits", "rateLimits"
    )

    for ($index = $Path.Count - 1; $index -ge 0; $index--) {
        $part = $Path[$index]
        if ($skip -contains $part) {
            continue
        }
        if ($part -match "gpt|codex|spark|model") {
            return Format-UsagePrefix $part
        }
    }

    return $null
}

function Get-UsagePrefixFromNode {
    param([object]$Node)

    $candidates = @(
        "model_slug", "modelSlug", "model", "model_name", "modelName",
        "model_id", "modelId", "sku", "name", "title", "display_name", "displayName"
    )

    foreach ($candidate in $candidates) {
        $value = ConvertTo-Text (Get-JsonValue $Node @($candidate))
        if ([string]::IsNullOrWhiteSpace($value)) {
            continue
        }
        if ($value -match "gpt|codex|spark") {
            return Format-UsagePrefix $value
        }
    }

    return $null
}

function Convert-UsageWindow {
    param(
        [object]$Window,
        [string]$FallbackTitle,
        [string]$Prefix
    )

    $used = ConvertTo-Int (Get-JsonValue $Window @("used_percent", "usedPercent"))
    $remaining = ConvertTo-Int (Get-JsonValue $Window @("remaining_percent", "remainingPercent"))
    if ($null -eq $remaining -and $null -ne $used) {
        $remaining = [math]::Max(0, [math]::Min(100, 100 - $used))
    }
    if ($null -ne $remaining) {
        $remaining = [math]::Max(0, [math]::Min(100, $remaining))
    }

    $limitSeconds = ConvertTo-Int (Get-JsonValue $Window @("limit_window_seconds", "limitWindowSeconds"))
    $resetAfter = ConvertTo-Int (Get-JsonValue $Window @("reset_after_seconds", "resetAfterSeconds"))
    $resetAt = Get-JsonValue $Window @("reset_at", "resetAt")
    $title = $FallbackTitle
    if ([string]::IsNullOrWhiteSpace($title)) {
        $title = Get-WindowTitle $limitSeconds
    }
    if (-not [string]::IsNullOrWhiteSpace($Prefix)) {
        $title = "$Prefix $title"
    }

    return [pscustomobject]@{
        Title = $title
        RemainingPercent = $remaining
        LimitWindowSeconds = $limitSeconds
        ResetDate = ConvertTo-ResetDate $resetAt $resetAfter
    }
}

function Add-UsageDisplay {
    param(
        [System.Collections.ArrayList]$Displays,
        [System.Collections.Hashtable]$Seen,
        [object]$Window,
        [string]$FallbackTitle,
        [string]$Prefix
    )

    $display = Convert-UsageWindow $Window $FallbackTitle $Prefix
    if ($null -eq $display.RemainingPercent -and $null -eq $display.LimitWindowSeconds) {
        return
    }

    $key = "$($display.Title)|$($display.RemainingPercent)|$($display.LimitWindowSeconds)|$($display.ResetDate)"
    if ($Seen.ContainsKey($key)) {
        return
    }

    $Seen[$key] = $true
    [void]$Displays.Add($display)
}

function Find-UsageWindows {
    param(
        [object]$Node,
        [string[]]$Path,
        [System.Collections.ArrayList]$Displays,
        [System.Collections.Hashtable]$Seen,
        [string]$InheritedPrefix = $null
    )

    if ($null -eq $Node) {
        return
    }

    if ($Node -is [System.Array]) {
        foreach ($item in $Node) {
            Find-UsageWindows $item $Path $Displays $Seen $InheritedPrefix
        }
        return
    }

    $properties = @($Node.PSObject.Properties)
    if ($properties.Count -eq 0) {
        return
    }

    $nodePrefix = Get-UsagePrefixFromNode $Node
    $resolvedPrefix = $InheritedPrefix
    if (-not [string]::IsNullOrWhiteSpace($nodePrefix)) {
        $resolvedPrefix = $nodePrefix
    }

    $hasWindowShape = $null -ne (Get-JsonValue $Node @("limit_window_seconds", "limitWindowSeconds")) -and
        (
            $null -ne (Get-JsonValue $Node @("used_percent", "usedPercent")) -or
            $null -ne (Get-JsonValue $Node @("remaining_percent", "remainingPercent"))
        )

    if ($hasWindowShape) {
        $pathPrefix = Get-UsagePrefixFromPath $Path
        $prefix = $resolvedPrefix
        if ([string]::IsNullOrWhiteSpace($prefix)) {
            $prefix = $pathPrefix
        }
        Add-UsageDisplay $Displays $Seen $Node $null $prefix
    }

    foreach ($property in $properties) {
        $nextPath = @($Path + $property.Name)
        Find-UsageWindows $property.Value $nextPath $Displays $Seen $resolvedPrefix
    }
}

function Convert-UsageDisplays {
    param([object]$Response)

    $displays = New-Object System.Collections.ArrayList
    $seen = @{}
    $rateLimit = Get-JsonValue $Response @("rate_limit", "rateLimit")
    if ($null -ne $rateLimit) {
        $primary = Get-JsonValue $rateLimit @("primary_window", "primaryWindow")
        if ($null -ne $primary) {
            $primarySeconds = ConvertTo-Int (Get-JsonValue $primary @("limit_window_seconds", "limitWindowSeconds"))
            $primaryTitle = Get-WindowTitle $primarySeconds
            Add-UsageDisplay $displays $seen $primary $primaryTitle $null
        }
        $secondary = Get-JsonValue $rateLimit @("secondary_window", "secondaryWindow")
        if ($null -ne $secondary) {
            $secondarySeconds = ConvertTo-Int (Get-JsonValue $secondary @("limit_window_seconds", "limitWindowSeconds"))
            $secondaryTitle = Get-WindowTitle $secondarySeconds
            Add-UsageDisplay $displays $seen $secondary $secondaryTitle $null
        }
    }

    Find-UsageWindows $Response @() $displays $seen
    return @($displays)
}

function Get-DaysLeft {
    param([object]$Date)
    if ($null -eq $Date) { return $null }
    $remaining = ([datetime]$Date).Date - (Get-Date).Date
    return [int]$remaining.TotalDays
}

function Format-DaysLeft {
    param([object]$Date)
    $days = Get-DaysLeft $Date
    if ($null -eq $days) { return "expiry unavailable" }
    if ($days -lt 0) { return "expired" }
    if ($days -eq 0) { return "expires today" }
    if ($days -eq 1) { return "1 day left" }
    return "$days days left"
}

function Format-Expiry {
    param([object]$Date)
    if ($null -eq $Date) { return "No expiry date returned" }
    return ([datetime]$Date).ToString("ddd, MMM d, h:mm tt", [System.Globalization.CultureInfo]::GetCultureInfo("en-US"))
}

function Get-Tone {
    param([object]$Date)
    $days = Get-DaysLeft $Date
    if ($null -eq $days) { return $script:Palette.Muted }
    if ($days -le 1) { return $script:Palette.Red }
    if ($days -le 7) { return $script:Palette.Amber }
    return $script:Palette.Green
}

function Get-Background {
    param([object]$Date)
    $days = Get-DaysLeft $Date
    if ($null -eq $days) { return $script:Palette.Card }
    if ($days -le 1) { return $script:Palette.RedTint }
    if ($days -le 7) { return $script:Palette.AmberTint }
    return $script:Palette.Card
}

function Get-UsageTone {
    param([object]$RemainingPercent)

    if ($null -eq $RemainingPercent) { return $script:Palette.Muted }
    if ($RemainingPercent -lt 25) { return $script:Palette.Red }
    if ($RemainingPercent -lt 60) { return $script:Palette.Amber }
    return $script:Palette.Green
}

function Get-State {
    $state = [pscustomobject]@{
        AccountLabel = "Codex account"
        LastChecked = $null
        AvailableCount = 0
        Credits = @()
        UsageWindows = @()
        UsageError = $null
        Error = $null
    }

    try {
        $context = Get-AuthContext
        $state.AccountLabel = $context.Label
        try {
            $usageResponse = Invoke-Usage $context
            $state.UsageWindows = @(Convert-UsageDisplays $usageResponse)
        } catch {
            $state.UsageError = "Could not load usage limits. $($_.Exception.Message)"
        }

        try {
            $response = Invoke-ResetCredits $context
            $credits = Convert-Credits $response
            $state.AvailableCount = $credits.AvailableCount
            $state.Credits = @($credits.Credits)
        } catch {
            $state.Error = "Could not load bonus resets. $($_.Exception.Message)"
        }
        $state.LastChecked = Get-Date
    } catch {
        $state.Error = $_.Exception.Message
    }

    return $state
}

function Get-StartupCommand {
    $entryScript = Join-Path $script:RootDir "script\build_and_run.ps1"
    return "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$entryScript`""
}

function Get-StartupEnabled {
    try {
        $value = (Get-ItemProperty -Path $script:StartupRunKey -Name $script:StartupRunName -ErrorAction Stop).($script:StartupRunName)
        return -not [string]::IsNullOrWhiteSpace($value)
    } catch {
        return $false
    }
}

function Set-StartupEnabled {
    param([bool]$Enabled)

    if ($Enabled) {
        if (-not (Test-Path -LiteralPath $script:StartupRunKey)) {
            New-Item -Path $script:StartupRunKey -Force | Out-Null
        }
        Set-ItemProperty -Path $script:StartupRunKey -Name $script:StartupRunName -Value (Get-StartupCommand) | Out-Null
    } else {
        Remove-ItemProperty -Path $script:StartupRunKey -Name $script:StartupRunName -ErrorAction SilentlyContinue
    }
}

function Get-AppSettings {
    $defaults = [pscustomobject]@{
        AlwaysOnTop = $true
    }

    if (-not (Test-Path -LiteralPath $script:SettingsPath)) {
        return $defaults
    }

    try {
        $settings = Get-Content -LiteralPath $script:SettingsPath -Raw | ConvertFrom-Json
        if ($null -eq $settings.PSObject.Properties["AlwaysOnTop"]) {
            $settings | Add-Member -NotePropertyName AlwaysOnTop -NotePropertyValue $true
        }
        return $settings
    } catch {
        return $defaults
    }
}

function Save-AppSettings {
    param([object]$Settings)

    if (-not (Test-Path -LiteralPath $script:SettingsDir)) {
        New-Item -ItemType Directory -Path $script:SettingsDir -Force | Out-Null
    }

    $Settings | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:SettingsPath -Encoding UTF8
}

function Get-AlwaysOnTopEnabled {
    return [bool](Get-AppSettings).AlwaysOnTop
}

function Set-AlwaysOnTopEnabled {
    param([bool]$Enabled)

    $settings = Get-AppSettings
    $settings.AlwaysOnTop = $Enabled
    Save-AppSettings $settings

    if ($script:Form) {
        $script:Form.TopMost = $Enabled
    }
}

function New-InitialState {
    return [pscustomobject]@{
        AccountLabel = "Codex account"
        LastChecked = $null
        AvailableCount = 0
        Credits = @()
        UsageWindows = @()
        UsageError = $null
        Error = "Click Refresh to check bonus reset expiry."
    }
}

function Write-State {
    param([object]$State)
    Write-Host "Codex bonus/reset credits"
    Write-Host "Account: $($State.AccountLabel)"
    foreach ($window in $State.UsageWindows) {
        $remaining = if ($null -eq $window.RemainingPercent) { "unknown" } else { "$($window.RemainingPercent)% remaining" }
        Write-Host "$($window.Title): $remaining ($((Format-UsageReset $window.ResetDate)))"
    }
    if ($State.UsageError) {
        Write-Host "Usage warning: $($State.UsageError)"
    }
    Write-Host "Available: $($State.AvailableCount)"
    if ($State.Error) {
        Write-Host "Warning: $($State.Error)"
        return
    }

    $index = 1
    foreach ($credit in $State.Credits) {
        Write-Host "Bonus ${index}: $(Format-DaysLeft $credit.ExpiresAt) ($((Format-Expiry $credit.ExpiresAt)))"
        $index += 1
    }

    while ($index -le $State.AvailableCount) {
        Write-Host "Bonus ${index}: expiry unavailable"
        $index += 1
    }
}

function New-TrayIcon {
    $png = Join-Path $script:RootDir "Assets\AppIcon.png"
    if (Test-Path -LiteralPath $png) {
        try {
            $bitmap = New-Object System.Drawing.Bitmap($png)
            $small = New-Object System.Drawing.Bitmap($bitmap, 32, 32)
            $handle = $small.GetHicon()
            $icon = ([System.Drawing.Icon]::FromHandle($handle)).Clone()
            [CodexResetWatcherNative]::DestroyIcon($handle) | Out-Null
            $small.Dispose()
            $bitmap.Dispose()
            return $icon
        } catch {
        }
    }
    return [System.Drawing.SystemIcons]::Information
}

function Add-Border {
    param([System.Windows.Forms.Control]$Control, [System.Drawing.Color]$Color)
    $Control.Tag = $Color
    $Control.Add_Paint({
        param($sender, $eventArgs)
        $pen = New-Object System.Drawing.Pen($sender.Tag)
        $eventArgs.Graphics.DrawRectangle($pen, 0, 0, $sender.Width - 1, $sender.Height - 1)
        $pen.Dispose()
    })
}

function Add-Label {
    param(
        [System.Windows.Forms.Control]$Parent,
        [string]$Text,
        [int]$X,
        [int]$Y,
        [int]$Width,
        [int]$Height,
        [float]$Size,
        [System.Drawing.FontStyle]$Style,
        [System.Drawing.Color]$Color,
        [System.Drawing.ContentAlignment]$Align = [System.Drawing.ContentAlignment]::MiddleLeft
    )

    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Location = New-Object System.Drawing.Point($X, $Y)
    $label.Size = New-Object System.Drawing.Size($Width, $Height)
    $label.Font = New-Font $Size $Style
    $label.ForeColor = $Color
    $label.BackColor = [System.Drawing.Color]::Transparent
    $label.TextAlign = $Align
    $label.AutoEllipsis = $true
    $Parent.Controls.Add($label)
    return $label
}

function Set-ModernButton {
    param(
        [System.Windows.Forms.Button]$Button,
        [bool]$Accent = $false
    )

    $Button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $Button.FlatAppearance.BorderSize = 1
    $Button.FlatAppearance.BorderColor = if ($Accent) { $script:Palette.Blue } else { $script:Palette.Border }
    $Button.BackColor = if ($Accent) { $script:Palette.Blue } else { $script:Palette.Button }
    $Button.ForeColor = if ($Accent) { [System.Drawing.Color]::White } else { $script:Palette.Text }
    $Button.Font = New-Font 9 ([System.Drawing.FontStyle]::Regular)
    $Button.Cursor = [System.Windows.Forms.Cursors]::Hand
}

function Set-DarkTitleBar {
    param([System.Windows.Forms.Form]$Form)

    $enabled = 1
    try {
        [CodexResetWatcherNative]::DwmSetWindowAttribute($Form.Handle, 20, [ref]$enabled, 4) | Out-Null
        [CodexResetWatcherNative]::DwmSetWindowAttribute($Form.Handle, 19, [ref]$enabled, 4) | Out-Null
    } catch {
    }
}

function Add-Card {
    param(
        [int]$Y,
        [int]$Height,
        [System.Drawing.Color]$BackColor,
        [System.Drawing.Color]$BorderColor,
        [int]$X = $script:PageMargin,
        [int]$Width = $script:FullWidth
    )
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Location = New-Object System.Drawing.Point($X, $Y)
    $panel.Size = New-Object System.Drawing.Size($Width, $Height)
    $panel.BackColor = $BackColor
    Add-Border $panel $BorderColor
    $script:Content.Controls.Add($panel)
    return $panel
}

function Add-Meter {
    param(
        [System.Windows.Forms.Control]$Parent,
        [int]$X,
        [int]$Y,
        [int]$Width,
        [object]$Percent,
        [System.Drawing.Color]$Color
    )

    $track = New-Object System.Windows.Forms.Panel
    $track.Location = New-Object System.Drawing.Point($X, $Y)
    $track.Size = New-Object System.Drawing.Size($Width, 7)
    $track.BackColor = $script:Palette.Border
    $Parent.Controls.Add($track)

    $value = 0
    if ($null -ne $Percent) {
        $value = [math]::Max(0, [math]::Min(100, [int]$Percent))
    }
    $fillWidth = [int][math]::Round($Width * $value / 100)

    $fill = New-Object System.Windows.Forms.Panel
    $fill.Location = New-Object System.Drawing.Point(0, 0)
    $fill.Size = New-Object System.Drawing.Size($fillWidth, 7)
    $fill.BackColor = $Color
    $track.Controls.Add($fill)
}

function Render-State {
    param([object]$State)
    if ($null -eq $script:Content) { return }

    $script:IsRendering = $true
    $script:Content.SuspendLayout()
    $script:Content.Controls.Clear()

    $y = $script:PageMargin
    $header = Add-Card $y 100 $script:Palette.Card $script:Palette.Border
    Add-Label $header "Codex Reset Watcher" 16 10 260 28 13 ([System.Drawing.FontStyle]::Bold) $script:Palette.Text | Out-Null
    $checked = "Not checked yet"
    if ($State.LastChecked) {
        $checked = "Last checked " + ([datetime]$State.LastChecked).ToString("h:mm tt", [System.Globalization.CultureInfo]::GetCultureInfo("en-US"))
    }
    Add-Label $header $checked 16 38 260 20 8.5 ([System.Drawing.FontStyle]::Regular) $script:Palette.Muted | Out-Null
    Add-Label $header "Active: $($State.AccountLabel)" 16 62 460 20 8.5 ([System.Drawing.FontStyle]::Regular) $script:Palette.Muted | Out-Null
    Add-Label $header ([string]$State.AvailableCount) 642 16 110 34 22 ([System.Drawing.FontStyle]::Bold) $script:Palette.Text ([System.Drawing.ContentAlignment]::MiddleRight) | Out-Null
    $unit = "bonuses"
    if ($State.AvailableCount -eq 1) { $unit = "bonus" }
    Add-Label $header $unit 642 52 110 20 9 ([System.Drawing.FontStyle]::Regular) $script:Palette.Muted ([System.Drawing.ContentAlignment]::MiddleRight) | Out-Null
    $y += 112

    if ($State.UsageWindows -and @($State.UsageWindows).Count -gt 0) {
        Add-Label $script:Content "Usage limits" 16 $y 180 22 9 ([System.Drawing.FontStyle]::Bold) $script:Palette.Muted | Out-Null
        $y += 28
        $usageIndex = 0
        foreach ($window in $State.UsageWindows) {
            $tone = Get-UsageTone $window.RemainingPercent
            $column = $usageIndex % 2
            $row = [int][math]::Floor($usageIndex / 2)
            $cardX = $script:PageMargin + ($column * ($script:ColumnWidth + $script:ColumnGap))
            $cardY = $y + ($row * 100)
            $usageCard = Add-Card $cardY 88 $script:Palette.Card $script:Palette.Border $cardX $script:ColumnWidth
            Add-Label $usageCard $window.Title 14 10 250 22 9.5 ([System.Drawing.FontStyle]::Bold) $script:Palette.Muted | Out-Null
            $remainingText = if ($null -eq $window.RemainingPercent) { "Unknown remaining" } else { "$($window.RemainingPercent)% remaining" }
            Add-Label $usageCard $remainingText 14 31 170 28 14 ([System.Drawing.FontStyle]::Bold) $script:Palette.Text | Out-Null
            Add-Meter $usageCard 14 62 360 $window.RemainingPercent $tone
            Add-Label $usageCard (Format-UsageReset $window.ResetDate) 206 32 168 22 8.5 ([System.Drawing.FontStyle]::Regular) $script:Palette.Muted ([System.Drawing.ContentAlignment]::MiddleRight) | Out-Null
            $usageIndex += 1
        }
        $usageRows = [math]::Ceiling(@($State.UsageWindows).Count / 2)
        $y += ([int]$usageRows * 100)
    }

    if ($State.UsageError) {
        $usageErrorCard = Add-Card $y 58 $script:Palette.AmberTint $script:Palette.Amber
        Add-Label $usageErrorCard $State.UsageError 14 10 740 36 8.5 ([System.Drawing.FontStyle]::Regular) $script:Palette.Text | Out-Null
        $y += 70
    }

    Add-Label $script:Content "Bonus resets" 16 $y 180 22 9 ([System.Drawing.FontStyle]::Bold) $script:Palette.Muted | Out-Null
    $y += 28

    if ($State.Error) {
        $errorCard = Add-Card $y 70 $script:Palette.AmberTint $script:Palette.Amber
        Add-Label $errorCard $State.Error 14 12 740 44 9 ([System.Drawing.FontStyle]::Regular) $script:Palette.Text | Out-Null
        $y += 82
    } elseif ($State.AvailableCount -eq 0) {
        $empty = Add-Card $y 58 $script:Palette.Card $script:Palette.Border
        Add-Label $empty "No banked bonus resets" 14 12 500 28 10 ([System.Drawing.FontStyle]::Bold) $script:Palette.Muted | Out-Null
        $y += 70
    } else {
        $index = 1
        foreach ($credit in $State.Credits) {
            $tone = Get-Tone $credit.ExpiresAt
            $zeroIndex = $index - 1
            $column = $zeroIndex % 2
            $row = [int][math]::Floor($zeroIndex / 2)
            $cardX = $script:PageMargin + ($column * ($script:ColumnWidth + $script:ColumnGap))
            $cardY = $y + ($row * 82)
            $card = Add-Card $cardY 72 (Get-Background $credit.ExpiresAt) $tone $cardX $script:ColumnWidth
            Add-Label $card "Bonus $index" 14 10 130 24 10 ([System.Drawing.FontStyle]::Bold) $script:Palette.Text | Out-Null
            Add-Label $card (Format-Expiry $credit.ExpiresAt) 14 36 210 22 8.5 ([System.Drawing.FontStyle]::Regular) $script:Palette.Muted | Out-Null
            Add-Label $card (Format-DaysLeft $credit.ExpiresAt) 222 17 150 30 12 ([System.Drawing.FontStyle]::Bold) $tone ([System.Drawing.ContentAlignment]::MiddleRight) | Out-Null
            $index += 1
        }

        while ($index -le $State.AvailableCount) {
            $zeroIndex = $index - 1
            $column = $zeroIndex % 2
            $row = [int][math]::Floor($zeroIndex / 2)
            $cardX = $script:PageMargin + ($column * ($script:ColumnWidth + $script:ColumnGap))
            $cardY = $y + ($row * 82)
            $card = Add-Card $cardY 64 $script:Palette.Card $script:Palette.Border $cardX $script:ColumnWidth
            Add-Label $card "Bonus $index" 14 10 130 22 10 ([System.Drawing.FontStyle]::Bold) $script:Palette.Text | Out-Null
            Add-Label $card "Codex did not return an expiry date." 14 34 210 20 8.5 ([System.Drawing.FontStyle]::Regular) $script:Palette.Muted | Out-Null
            Add-Label $card "expiry unavailable" 214 18 160 24 10 ([System.Drawing.FontStyle]::Bold) $script:Palette.Muted ([System.Drawing.ContentAlignment]::MiddleRight) | Out-Null
            $index += 1
        }
        $bonusRows = [math]::Ceiling($State.AvailableCount / 2)
        $y += ([int]$bonusRows * 82)
    }

    $settings = Add-Card $y 98 $script:Palette.Card $script:Palette.Border
    Add-Label $settings "Window settings" 14 8 180 20 9 ([System.Drawing.FontStyle]::Bold) $script:Palette.Text | Out-Null

    $alwaysOnTop = New-Object System.Windows.Forms.CheckBox
    $alwaysOnTop.Text = "Always on top"
    $alwaysOnTop.Location = New-Object System.Drawing.Point(14, 34)
    $alwaysOnTop.Size = New-Object System.Drawing.Size(160, 24)
    $alwaysOnTop.Font = New-Font 9 ([System.Drawing.FontStyle]::Regular)
    $alwaysOnTop.ForeColor = $script:Palette.Text
    $alwaysOnTop.BackColor = [System.Drawing.Color]::Transparent
    $alwaysOnTop.Checked = Get-AlwaysOnTopEnabled
    $alwaysOnTop.Add_CheckedChanged({
        param($sender, $eventArgs)
        if ($script:IsRendering) { return }
        try {
            Set-AlwaysOnTopEnabled $sender.Checked
        } catch {
            [System.Windows.Forms.MessageBox]::Show(
                "Could not update always-on-top setting. $($_.Exception.Message)",
                "Codex Reset Watcher",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
            $script:IsRendering = $true
            $sender.Checked = -not $sender.Checked
            $script:IsRendering = $false
        }
    })
    $settings.Controls.Add($alwaysOnTop)

    $startup = New-Object System.Windows.Forms.CheckBox
    $startup.Text = "Open when Windows starts"
    $startup.Location = New-Object System.Drawing.Point(190, 34)
    $startup.Size = New-Object System.Drawing.Size(190, 24)
    $startup.Font = New-Font 9 ([System.Drawing.FontStyle]::Regular)
    $startup.ForeColor = $script:Palette.Text
    $startup.BackColor = [System.Drawing.Color]::Transparent
    $startup.Checked = Get-StartupEnabled
    $startup.Add_CheckedChanged({
        param($sender, $eventArgs)
        if ($script:IsRendering) { return }
        try {
            Set-StartupEnabled $sender.Checked
        } catch {
            [System.Windows.Forms.MessageBox]::Show(
                "Could not update Windows startup setting. $($_.Exception.Message)",
                "Codex Reset Watcher",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
            $script:IsRendering = $true
            $sender.Checked = -not $sender.Checked
            $script:IsRendering = $false
        }
    })
    $settings.Controls.Add($startup)
    Add-Label $settings "Startup uses the current-user Run entry. No admin needed." 14 66 350 18 8 ([System.Drawing.FontStyle]::Regular) $script:Palette.Muted | Out-Null
    $y += 110

    $refresh = New-Object System.Windows.Forms.Button
    $refresh.Text = "Refresh"
    $refresh.Location = New-Object System.Drawing.Point($script:PageMargin, $y)
    $refresh.Size = New-Object System.Drawing.Size(90, 30)
    Set-ModernButton $refresh $true
    $refresh.Add_Click({ Refresh-State })
    $script:Content.Controls.Add($refresh)

    $hide = New-Object System.Windows.Forms.Button
    $hide.Text = "Hide"
    $hideX = $script:PageMargin + $script:FullWidth - 188
    $hide.Location = New-Object System.Drawing.Point($hideX, $y)
    $hide.Size = New-Object System.Drawing.Size(84, 30)
    Set-ModernButton $hide
    $hide.Add_Click({ $script:Form.Hide() })
    $script:Content.Controls.Add($hide)

    $quit = New-Object System.Windows.Forms.Button
    $quit.Text = "Quit"
    $quitX = $script:PageMargin + $script:FullWidth - 90
    $quit.Location = New-Object System.Drawing.Point($quitX, $y)
    $quit.Size = New-Object System.Drawing.Size(90, 30)
    Set-ModernButton $quit
    $quit.Add_Click({
        $script:IsQuitting = $true
        $script:NotifyIcon.Visible = $false
        [System.Windows.Forms.Application]::Exit()
    })
    $script:Content.Controls.Add($quit)
    $y += 44

    $script:Content.AutoScrollMinSize = New-Object System.Drawing.Size(0, 0)
    $script:Content.ResumeLayout()
    $script:IsRendering = $false

    if ($script:NotifyIcon) {
        $tooltip = "Codex: $($State.AvailableCount) bonus reset"
        if ($State.AvailableCount -ne 1) { $tooltip += "s" }
        $script:NotifyIcon.Text = $tooltip.Substring(0, [math]::Min(63, $tooltip.Length))
    }
}

function Refresh-State {
    if ($script:Form) { $script:Form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor }
    $script:State = Get-State
    if ($script:Form) { $script:Form.Cursor = [System.Windows.Forms.Cursors]::Default }
    Render-State $script:State
}

function Show-Popup {
    if ($null -eq $script:State) {
        $script:State = New-InitialState
    }
    Render-State $script:State

    $screen = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position)
    $area = $screen.WorkingArea
    $width = [math]::Min($script:WindowWidth, $area.Width - 24)
    $height = [math]::Min($script:WindowHeight, $area.Height - 24)
    $script:Form.Size = New-Object System.Drawing.Size($width, $height)
    $left = $area.Right - $width - 10
    $top = $area.Bottom - $height - 10
    $script:Form.Location = New-Object System.Drawing.Point($left, $top)
    $script:Form.TopMost = Get-AlwaysOnTopEnabled
    $script:Form.Show()
    $script:Form.Activate()

    if ($null -eq $script:State.LastChecked) {
        $script:Form.BeginInvoke([System.Action]{ Refresh-State }) | Out-Null
    }
}

function Initialize-App {
    $script:State = New-InitialState

    $script:Form = New-Object System.Windows.Forms.Form
    $script:Form.Text = "Codex Reset Watcher"
    $script:Form.ShowInTaskbar = $true
    $script:Form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $script:Form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
    $script:Form.MaximizeBox = $false
    $script:Form.MinimizeBox = $false
    $script:Form.TopMost = Get-AlwaysOnTopEnabled
    $script:Form.BackColor = $script:Palette.Background
    $script:Form.ForeColor = $script:Palette.Text
    $script:Form.Add_HandleCreated({
        Set-DarkTitleBar $script:Form
    })
    $script:Form.Add_FormClosing({
        param($sender, $eventArgs)
        if (-not $script:IsQuitting) {
            $eventArgs.Cancel = $true
            $script:Form.Hide()
        }
    })

    $script:Content = New-Object System.Windows.Forms.Panel
    $script:Content.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:Content.AutoScroll = $false
    $script:Content.BackColor = $script:Palette.Background
    $script:Form.Controls.Add($script:Content)

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $open = $menu.Items.Add("Open")
    $open.Add_Click({ Show-Popup })
    $refresh = $menu.Items.Add("Refresh")
    $refresh.Add_Click({ Show-Popup; Refresh-State })
    $menu.Items.Add("-") | Out-Null
    $quit = $menu.Items.Add("Quit")
    $quit.Add_Click({
        $script:IsQuitting = $true
        $script:NotifyIcon.Visible = $false
        [System.Windows.Forms.Application]::Exit()
    })

    $script:NotifyIcon = New-Object System.Windows.Forms.NotifyIcon
    $script:NotifyIcon.Icon = New-TrayIcon
    $script:NotifyIcon.Text = "Codex Reset Watcher"
    $script:NotifyIcon.Visible = $true
    $script:NotifyIcon.ContextMenuStrip = $menu
    $script:NotifyIcon.Add_MouseUp({
        param($sender, $eventArgs)
        if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            if ($script:Form.Visible) { $script:Form.Hide() } else { Show-Popup }
        }
    })

    Show-Popup
    [System.Windows.Forms.Application]::Run()
}

function Test-UiRender {
    $parserFixture = [pscustomobject]@{
        models = @(
            [pscustomobject]@{
                model_slug = "gpt-5.3-codex-spark"
                windows = @(
                    [pscustomobject]@{
                        used_percent = 0
                        limit_window_seconds = 18000
                    }
                )
            }
        )
    }
    $parsedWindows = @(Convert-UsageDisplays $parserFixture)
    if (-not ($parsedWindows | Where-Object { $_.Title -eq "GPT-5.3-Codex-Spark 5 hour usage limit" })) {
        throw "Model-specific usage title was not preserved."
    }

    $script:Form = New-Object System.Windows.Forms.Form
    $script:Content = New-Object System.Windows.Forms.Panel
    $script:Content.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:Content.AutoScroll = $false
    $script:Form.Controls.Add($script:Content)

    $script:State = [pscustomobject]@{
        AccountLabel = "test@example.com"
        LastChecked = Get-Date
        AvailableCount = 2
        UsageWindows = @(
            [pscustomobject]@{ Title = "5 hour usage limit"; RemainingPercent = 32; LimitWindowSeconds = 18000; ResetDate = (Get-Date).AddHours(2) },
            [pscustomobject]@{ Title = "Weekly usage limit"; RemainingPercent = 19; LimitWindowSeconds = 604800; ResetDate = (Get-Date).AddDays(1) },
            [pscustomobject]@{ Title = "GPT-5.3-Codex-Spark 5 hour usage limit"; RemainingPercent = 100; LimitWindowSeconds = 18000; ResetDate = $null }
        )
        UsageError = $null
        Credits = @(
            [pscustomobject]@{ Id = "one"; ExpiresAt = (Get-Date).AddDays(1); ExpiresAtRaw = $null },
            [pscustomobject]@{ Id = "two"; ExpiresAt = (Get-Date).AddDays(8); ExpiresAtRaw = $null }
        )
        Error = $null
    }
    Render-State $script:State
    $count = $script:Content.Controls.Count
    $script:Form.Dispose()
    $script:Form = $null
    $script:Content = $null
    if ($count -le 0) { throw "UI render produced no controls." }
    Write-Host "Windows bonus-expiry UI smoke test OK ($count controls)."
}

if ($Check) {
    $script:State = Get-State
    Write-State $script:State
    exit 0
}

if ($UiSmokeTest) {
    Test-UiRender
    exit 0
}

Initialize-App
