$VERSION = "1.2.0"
# Single line: Model | tokens | %used | %remain | think | 5h bar @reset | 7d bar @reset | extra

# Read input from stdin
$input = @($Input) -join "`n"

if (-not $input) {
    Write-Host -NoNewline "Claude"
    exit 0
}

# ANSI escape - use [char]0x1b for PowerShell 5 compatibility ("`e" is PS7+ only)
$esc = [char]0x1b

# ANSI colors matching oh-my-posh theme
$blue   = "${esc}[38;2;0;153;255m"
$orange = "${esc}[38;2;255;176;85m"
$green  = "${esc}[38;2;0;160;0m"
$cyan   = "${esc}[38;2;46;149;153m"
$red    = "${esc}[38;2;255;85;85m"
$yellow = "${esc}[38;2;230;200;0m"
$white  = "${esc}[38;2;220;220;220m"
$dim    = "${esc}[2m"
$reset  = "${esc}[0m"

# Format token counts (e.g., 50k / 200k)
function Format-Tokens([long]$num) {
    if ($num -ge 1000000) { return "{0:F1}m" -f ($num / 1000000) }
    elseif ($num -ge 1000) { return "{0:F0}k" -f ($num / 1000) }
    else { return "$num" }
}

# Format number with commas (e.g., 134,938)
function Format-Commas([long]$num) {
    return $num.ToString("N0")
}

# Return color escape based on usage percentage
function Get-UsageColor([int]$pct) {
    if ($pct -ge 90) { return $red }
    elseif ($pct -ge 70) { return $orange }
    elseif ($pct -ge 50) { return $yellow }
    else { return $green }
}

# Null coalescing helper for PowerShell 5 compatibility (?? is PS7+ only)
function Coalesce($value, $default) {
    if ($null -ne $value) { return $value } else { return $default }
}

# Return $true if $a > $b using semantic versioning
function Test-VersionGreaterThan([string]$a, [string]$b) {
    try {
        $va = [version]($a -replace '^v', '')
        $vb = [version]($b -replace '^v', '')
        return $va -gt $vb
    } catch {
        return $false
    }
}

# ===== Extract data from JSON =====
$data = $input | ConvertFrom-Json

$modelName = if ($data.model.display_name) { $data.model.display_name } else { "Claude" }

# Context window
$size = if ($data.context_window.context_window_size) { [long]$data.context_window.context_window_size } else { 200000 }
if ($size -eq 0) { $size = 200000 }

# Token usage
$inputTokens = if ($data.context_window.current_usage.input_tokens) { [long]$data.context_window.current_usage.input_tokens } else { 0 }
$cacheCreate = if ($data.context_window.current_usage.cache_creation_input_tokens) { [long]$data.context_window.current_usage.cache_creation_input_tokens } else { 0 }
$cacheRead   = if ($data.context_window.current_usage.cache_read_input_tokens) { [long]$data.context_window.current_usage.cache_read_input_tokens } else { 0 }
$current = $inputTokens + $cacheCreate + $cacheRead

$usedTokens  = Format-Tokens $current
$totalTokens = Format-Tokens $size

if ($size -gt 0) {
    $pctUsed = [math]::Floor($current * 100 / $size)
} else {
    $pctUsed = 0
}
$pctRemain = 100 - $pctUsed

$usedComma   = Format-Commas $current
$remainComma = Format-Commas ($size - $current)

# Config directory (respects CLAUDE_CONFIG_DIR override)
$claudeConfigDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE ".claude" }

# Check reasoning effort
$effortLevel = "medium"
if ($env:CLAUDE_CODE_EFFORT_LEVEL) {
    $effortLevel = $env:CLAUDE_CODE_EFFORT_LEVEL
} else {
    $settingsPath = Join-Path $claudeConfigDir "settings.json"
    if (Test-Path $settingsPath) {
        try {
            $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
            if ($settings.effortLevel) { $effortLevel = $settings.effortLevel }
        } catch {}
    }
}

# ===== Build single-line output =====
$out = ""
$out += "${blue}${modelName}${reset}"

# Current working directory
$cwd = $data.cwd
if ($cwd) {
    $displayDir = Split-Path $cwd -Leaf
    $gitBranch = $null
    try {
        $gitBranch = git -C $cwd rev-parse --abbrev-ref HEAD 2>$null
    } catch {}
    $out += " ${dim}|${reset} "
    $out += "${cyan}${displayDir}${reset}"
    if ($gitBranch) {
        $out += "${dim}@${reset}${green}${gitBranch}${reset}"
        try {
            $numstat = git -C $cwd diff --numstat 2>$null
            if ($numstat) {
                $added = 0; $deleted = 0
                foreach ($line in $numstat) {
                    $parts = $line -split '\s+'
                    if ($parts[0] -match '^\d+$') { $added += [int]$parts[0] }
                    if ($parts[1] -match '^\d+$') { $deleted += [int]$parts[1] }
                }
                if (($added + $deleted) -gt 0) {
                    $out += " ${dim}(${reset}${green}+${added}${reset} ${red}-${deleted}${reset}${dim})${reset}"
                }
            }
        } catch {}
    }
}

$out += " ${dim}|${reset} "
$out += "${orange}${usedTokens}/${totalTokens}${reset} ${dim}(${reset}${green}${pctUsed}%${reset}${dim})${reset}"
$out += " ${dim}|${reset} "
$out += "effort: "
switch ($effortLevel) {
    "low"    { $out += "${dim}${effortLevel}${reset}" }
    "medium" { $out += "${orange}med${reset}" }
    "max"    { $out += "${red}${effortLevel}${reset}" }
    default  { $out += "${green}${effortLevel}${reset}" }
}

# ===== OAuth token resolution =====
function Get-OAuthToken {
    # 1. Explicit env var override
    if ($env:CLAUDE_CODE_OAUTH_TOKEN) {
        return $env:CLAUDE_CODE_OAUTH_TOKEN
    }

    # 2. Windows Credential Manager (via cmdkey/CredentialManager)
    try {
        if (Get-Command "cmdkey.exe" -ErrorAction SilentlyContinue) {
            # Try reading from Windows Credential Manager using PowerShell
            $credPath = Join-Path $env:LOCALAPPDATA "Claude Code\credentials.json"
            if (Test-Path $credPath) {
                $creds = Get-Content $credPath -Raw | ConvertFrom-Json
                $token = $creds.claudeAiOauth.accessToken
                if ($token -and $token -ne "null") { return $token }
            }
        }
    } catch {}

    # 3. Credentials file (cross-platform fallback)
    $credsFile = Join-Path $claudeConfigDir ".credentials.json"
    if (Test-Path $credsFile) {
        try {
            $creds = Get-Content $credsFile -Raw | ConvertFrom-Json
            $token = $creds.claudeAiOauth.accessToken
            if ($token -and $token -ne "null") { return $token }
        } catch {}
    }

    return $null
}

# ===== Usage limits with caching =====
$cacheDir = Join-Path $env:TEMP "claude"
$cacheFile = Join-Path $cacheDir "statusline-usage-cache.json"
$cacheMaxAge = 60  # seconds between API calls

if (-not (Test-Path $cacheDir)) { New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null }

$needsRefresh = $true
$usageData = $null

# Check cache
if (Test-Path $cacheFile) {
    $cacheMtime = (Get-Item $cacheFile).LastWriteTime
    $cacheAge = ((Get-Date) - $cacheMtime).TotalSeconds
    if ($cacheAge -lt $cacheMaxAge) {
        $needsRefresh = $false
        $usageData = Get-Content $cacheFile -Raw
    }
}

# Fetch fresh data if cache is stale
if ($needsRefresh) {
    $token = Get-OAuthToken
    if ($token) {
        try {
            $headers = @{
                "Accept"         = "application/json"
                "Content-Type"   = "application/json"
                "Authorization"  = "Bearer $token"
                "anthropic-beta" = "oauth-2025-04-20"
                "User-Agent"     = "claude-code/2.1.34"
            }
            $response = Invoke-RestMethod -Uri "https://api.anthropic.com/api/oauth/usage" `
                -Headers $headers -Method Get -TimeoutSec 10 -ErrorAction Stop
            $usageData = $response | ConvertTo-Json -Depth 10
            $usageData | Set-Content $cacheFile -Force
        } catch {}
    }
    # Fall back to stale cache
    if (-not $usageData -and (Test-Path $cacheFile)) {
        $usageData = Get-Content $cacheFile -Raw
    }
}

# Format ISO reset time to compact local time
function Format-ResetTime([string]$isoStr, [string]$style) {
    if (-not $isoStr -or $isoStr -eq "null") { return $null }
    try {
        $dt = [DateTimeOffset]::Parse($isoStr).LocalDateTime
        switch ($style) {
            "time"     { return $dt.ToString("h:mmtt").ToLower() }
            "datetime" { return $dt.ToString("MMM d, h:mmtt").ToLower() }
            default    { return $dt.ToString("MMM d").ToLower() }
        }
    } catch { return $null }
}

$sep = " ${dim}|${reset} "

if ($usageData) {
    try {
        $usage = if ($usageData -is [string]) { $usageData | ConvertFrom-Json } else { $usageData }

        # ---- 5-hour (current) ----
        $fiveHourPct = [math]::Floor([double](Coalesce $usage.five_hour.utilization 0))
        $fiveHourResetIso = $usage.five_hour.resets_at
        $fiveHourReset = Format-ResetTime $fiveHourResetIso "time"
        $fiveHourColor = Get-UsageColor $fiveHourPct

        $out += "${sep}${white}5h${reset} ${fiveHourColor}${fiveHourPct}%${reset}"
        if ($fiveHourReset) { $out += " ${dim}@${fiveHourReset}${reset}" }

        # ---- 7-day (weekly) ----
        $sevenDayPct = [math]::Floor([double](Coalesce $usage.seven_day.utilization 0))
        $sevenDayResetIso = $usage.seven_day.resets_at
        $sevenDayReset = Format-ResetTime $sevenDayResetIso "datetime"
        $sevenDayColor = Get-UsageColor $sevenDayPct

        $out += "${sep}${white}7d${reset} ${sevenDayColor}${sevenDayPct}%${reset}"
        if ($sevenDayReset) { $out += " ${dim}@${sevenDayReset}${reset}" }

        # ---- Extra usage ----
        $extraEnabled = $usage.extra_usage.is_enabled
        if ($extraEnabled -eq $true) {
            $extraPct = [math]::Floor([double](Coalesce $usage.extra_usage.utilization 0))
            $extraUsedRaw = $usage.extra_usage.used_credits
            $extraLimitRaw = $usage.extra_usage.monthly_limit

            if ($null -ne $extraUsedRaw -and $null -ne $extraLimitRaw) {
                $extraUsed = "{0:F2}" -f ([double]$extraUsedRaw / 100)
                $extraLimit = "{0:F2}" -f ([double]$extraLimitRaw / 100)
                $extraColor = Get-UsageColor $extraPct
                $out += "${sep}${white}extra${reset} ${extraColor}`$${extraUsed}/`$${extraLimit}${reset}"
            } else {
                $out += "${sep}${white}extra${reset} ${green}enabled${reset}"
            }
        }
    } catch {}
}

# ===== Update check (cached, 24h TTL) =====
$versionCacheFile = Join-Path $cacheDir "statusline-version-cache.json"
$versionCacheMaxAge = 86400  # 24 hours

$versionNeedsRefresh = $true
$versionData = $null

if (Test-Path $versionCacheFile) {
    $vcMtime = (Get-Item $versionCacheFile).LastWriteTime
    $vcAge = ((Get-Date) - $vcMtime).TotalSeconds
    if ($vcAge -lt $versionCacheMaxAge) {
        $versionNeedsRefresh = $false
    }
    $versionData = Get-Content $versionCacheFile -Raw
}

if ($versionNeedsRefresh) {
    # Touch cache immediately (thundering herd protection)
    if (Test-Path $versionCacheFile) {
        (Get-Item $versionCacheFile).LastWriteTime = Get-Date
    } else {
        New-Item -ItemType File -Path $versionCacheFile -Force | Out-Null
    }
    try {
        $vcResponse = Invoke-RestMethod -Uri "https://api.github.com/repos/daniel3303/ClaudeCodeStatusLine/releases/latest" `
            -Headers @{ "Accept" = "application/vnd.github+json" } -Method Get -TimeoutSec 5 -ErrorAction Stop
        $versionData = $vcResponse | ConvertTo-Json -Depth 10
        $versionData | Set-Content $versionCacheFile -Force
    } catch {}
}

$updateLine = ""
if ($versionData) {
    try {
        $vcParsed = if ($versionData -is [string]) { $versionData | ConvertFrom-Json } else { $versionData }
        $latestTag = $vcParsed.tag_name
        if ($latestTag -and (Test-VersionGreaterThan $latestTag $VERSION)) {
            $updateLine = "`n${dim}Update available: ${latestTag} → https://github.com/daniel3303/ClaudeCodeStatusLine${reset}"
        }
    } catch {}
}

# Output
Write-Host -NoNewline "$out$updateLine"

exit 0
