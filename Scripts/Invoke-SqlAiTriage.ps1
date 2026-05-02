param(
    [string]$SqlInstance = "localhost",
    [string]$Database = "StackOverflow2013",
    [string]$SqlFolder = "C:\SqlAiTriage\Sql",
    [string]$OutputFolder = "C:\SqlAiTriage\Reports",
    [string]$LogFolder = "C:\SqlAiTriage\Logs",
    [string]$Model = "gpt-5.1",

    [decimal]$MinimumSeverityScore = 25,
    [int]$SuppressSameIssueHours = 24
)

$ErrorActionPreference = "Stop"

# Detect if -TrustServerCertificate is supported
$SupportsTrustCert = $false

try {
    $cmd = Get-Command Invoke-Sqlcmd -ErrorAction Stop

    if ($cmd.Parameters.ContainsKey("TrustServerCertificate")) {
        $SupportsTrustCert = $true
    }
}
catch {
    Write-Warning "Invoke-Sqlcmd not found. Ensure SqlServer module is installed."
}


if (-not $env:OPENAI_API_KEY) {
    throw "OPENAI_API_KEY environment variable is not set."
}

New-Item -ItemType Directory -Force -Path $OutputFolder | Out-Null
New-Item -ItemType Directory -Force -Path $LogFolder | Out-Null

$HistoryFile = Join-Path $LogFolder "issue-history.json"

if (Test-Path $HistoryFile) {
    $IssueHistory = Get-Content $HistoryFile -Raw | ConvertFrom-Json
    if ($null -eq $IssueHistory) { $IssueHistory = @() }
} else {
    $IssueHistory = @()
}

if ($IssueHistory -isnot [array]) {
    $IssueHistory = @($IssueHistory)
}

function Get-IssueKey {
    param([string]$DetectorName,[object]$Issue)

    # Prefer detector-provided IssueKey
    if ($Issue.PSObject.Properties.Name -contains "IssueKey" -and
        -not [string]::IsNullOrWhiteSpace($Issue.IssueKey)) {
        return [string]$Issue.IssueKey
    }

    switch -Wildcard ($DetectorName) {
        "*QueryStorePlanRegression*" {
            $queryId = $Issue.query_id

            $worstPlanId = $null
            if ($Issue.worst_plan -and $Issue.worst_plan.plan_id) {
                $worstPlanId = $Issue.worst_plan.plan_id
            }
            elseif ($Issue.worst_plan_id) {
                $worstPlanId = $Issue.worst_plan_id
            }

            return "$DetectorName|query_id=$queryId|worst_plan_id=$worstPlanId"
        }
        "*Blocking*" {
            return "$DetectorName|blocked_session=$($Issue.blocked_session_id)|blocking_session=$($Issue.blocking_session_id)"
        }
        "*MemoryGrant*ResourceSemaphore*" {
            return "$DetectorName|session_id=$($Issue.session_id)|request_id=$($Issue.request_id)|issue_type=$($Issue.issue_type)"
        }
        "*TopCpuQueries*" {
            return "$DetectorName|query_id=$($Issue.query_id)|plan_id=$($Issue.plan_id)"
        }
        default {
            $json = $Issue | ConvertTo-Json -Compress -Depth 20
            $sha256 = [System.Security.Cryptography.SHA256]::Create()
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
            $hashBytes = $sha256.ComputeHash($bytes)
            $hash = [System.BitConverter]::ToString($hashBytes).Replace("-", "")
            return "$DetectorName|$hash"
        }
    }
}

function Get-SeverityScore {
    param([string]$DetectorName,[object]$Issue)

    # ✅ Prefer detector-provided SeverityScore
    if ($Issue.PSObject.Properties.Name -contains "SeverityScore" -and
        $null -ne $Issue.SeverityScore) {
        return [decimal]$Issue.SeverityScore
    }

    switch -Wildcard ($DetectorName) {
        "*QueryStorePlanRegression*" {
            if ($Issue.regression) {
                $duration = if ($Issue.regression.duration_multiplier) { [decimal]$Issue.regression.duration_multiplier } else { 1 }
                $cpu      = if ($Issue.regression.cpu_multiplier)      { [decimal]$Issue.regression.cpu_multiplier }      else { 1 }
                $reads    = if ($Issue.regression.reads_multiplier)    { [decimal]$Issue.regression.reads_multiplier }    else { 1 }
            }
            else {
                $duration = if ($Issue.duration_multiplier) { [decimal]$Issue.duration_multiplier } else { 1 }
                $cpu      = if ($Issue.cpu_multiplier)      { [decimal]$Issue.cpu_multiplier }      else { 1 }
                $reads    = if ($Issue.reads_multiplier)    { [decimal]$Issue.reads_multiplier }    else { 1 }
            }

            return [math]::Round(($duration * 0.50) + ($cpu * 0.25) + ($reads * 0.25), 2)
        }
        "*MemoryGrant*ResourceSemaphore*" {
            $waitSeconds = if ($Issue.wait_seconds) { [decimal]$Issue.wait_seconds } else { 0 }
            $requestedMb = if ($Issue.requested_memory_mb) { [decimal]$Issue.requested_memory_mb } else { 0 }
            $grantedMb = if ($Issue.granted_memory_mb) { [decimal]$Issue.granted_memory_mb } else { 0 }
            $wastePercent = if ($Issue.memory_waste_percent) { [decimal]$Issue.memory_waste_percent } else { 0 }

            $score =
                ($waitSeconds / 10) +
                ($requestedMb / 256) +
                ($grantedMb / 512) +
                ($wastePercent / 10)

            return [math]::Round($score, 2)
        }
        "*TopCpuQueries*" {
            $totalCpuMs = if ($Issue.total_cpu_ms) { [decimal]$Issue.total_cpu_ms } else { 0 }
            $avgCpuMs   = if ($Issue.avg_cpu_ms)   { [decimal]$Issue.avg_cpu_ms }   else { 0 }
            $executions = if ($Issue.executions)   { [decimal]$Issue.executions }   else { 1 }
            $reads      = if ($Issue.avg_logical_reads) { [decimal]$Issue.avg_logical_reads } else { 0 }

            $score =
                ($totalCpuMs / 1000) +
                ($avgCpuMs / 100) +
                ($executions / 100) +
                ($reads / 100000)

            return [math]::Round($score, 2)
        }

        default {
            return 10
        }
    }
}

function Test-RecentlyReported {
    param([array]$IssueHistory,[string]$IssueKey,[int]$SuppressSameIssueHours)

    $cutoffUtc = (Get-Date).ToUniversalTime().AddHours(-1 * $SuppressSameIssueHours)

    $recent = $IssueHistory | Where-Object {
        $_.IssueKey -eq $IssueKey -and ([datetime]$_.LastSeenUtc) -ge $cutoffUtc
    }

    return $null -ne $recent
}

function Save-IssueHistory {
    param([array]$IssueHistory,[string]$HistoryFile)

    $IssueHistory |
        ConvertTo-Json -Depth 20 |
        Set-Content -Path $HistoryFile -Encoding UTF8
}

function Invoke-OpenAiAnalysis {
    param(
        [string]$Model,
        [string]$DetectorName,
        [object]$Issue,
        [decimal]$SeverityScore
    )

    $issueJson = $Issue | ConvertTo-Json -Depth 20

    $prompt = @"
Analyze this SQL Server monitoring issue.

Detector:
$DetectorName

SeverityScore:
$SeverityScore

Return:
1. Summary
2. Why it matters
3. Evidence from the JSON
4. Likely causes
5. What to check next
6. Safe next steps
7. What NOT to do

JSON:
$issueJson
"@

    $body = @{
        model = $Model
        input = $prompt
    } | ConvertTo-Json -Depth 20

    $headers = @{
        "Authorization" = "Bearer $env:OPENAI_API_KEY"
        "Content-Type"  = "application/json"
    }

    $response = Invoke-RestMethod `
        -Uri "https://api.openai.com/v1/responses" `
        -Method Post `
        -Headers $headers `
        -Body $body `
        -ErrorAction Stop

    if ($response.output_text) {
        return $response.output_text
    }

    $textParts = @()

    foreach ($outputItem in $response.output) {
        foreach ($contentItem in $outputItem.content) {
            if ($contentItem.text) {
                $textParts += $contentItem.text
            }
        }
    }

    if ($textParts.Count -gt 0) {
        return ($textParts -join "`r`n")
    }

    return "AI response was received, but no text output was found. Raw response: $($response | ConvertTo-Json -Depth 20)"
}

$sqlFiles = Get-ChildItem -Path $SqlFolder -Filter "*.sql" | Sort-Object Name

foreach ($file in $sqlFiles) {

    Write-Host ""
    Write-Host "Running detector: $($file.Name)"

    $detectorName = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)

    if ($SupportsTrustCert) {
        $sqlResult = Invoke-Sqlcmd `
            -ServerInstance $SqlInstance `
            -Database $Database `
            -InputFile $file.FullName `
            -TrustServerCertificate `
            -ErrorAction Stop
    }
    else {
        $sqlResult = Invoke-Sqlcmd `
            -ServerInstance $SqlInstance `
            -Database $Database `
            -InputFile $file.FullName `
            -ErrorAction Stop
    }

    if (-not $sqlResult -or -not $sqlResult.JsonOutput) {
        Write-Host "No issue found."
        continue
    }

    if ([string]::IsNullOrWhiteSpace($sqlResult.JsonOutput)) {
        Write-Host "No issue found."
        continue
    }

    $issues = $sqlResult.JsonOutput | ConvertFrom-Json

    if ($null -eq $issues) {
        Write-Host "No issue found."
        continue
    }

    if ($issues -isnot [array]) {
        $issues = @($issues)
    }

    foreach ($issue in $issues) {

        $issueKey = Get-IssueKey -DetectorName $detectorName -Issue $issue
        $severityScore = Get-SeverityScore -DetectorName $detectorName -Issue $issue

        Write-Host "IssueKey: $issueKey"
        Write-Host "SeverityScore: $severityScore"

        if ($severityScore -lt $MinimumSeverityScore) {
            Write-Host "Skipped: low severity."
            continue
        }

        if (Test-RecentlyReported -IssueHistory $IssueHistory -IssueKey $issueKey -SuppressSameIssueHours $SuppressSameIssueHours) {
            Write-Host "Skipped: already reported."
            continue
        }

        Write-Host "Sending to AI..."

        $analysis = Invoke-OpenAiAnalysis -Model $Model -DetectorName $detectorName -Issue $issue -SeverityScore $severityScore

        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $safeDetectorName = $detectorName -replace '[^\w\-]', '_'
        $reportFile = Join-Path $OutputFolder "$timestamp-$safeDetectorName.md"

        $rawJson = $issue | ConvertTo-Json -Depth 20

        $report = @"
# SQL Server AI Triage Report

## Detector
$detectorName

## Severity Score
$severityScore

## Issue Key
$issueKey

## AI Analysis
$analysis

## Raw JSON
$rawJson
"@

        $report | Set-Content -Path $reportFile -Encoding UTF8

        Write-Host "Saved: $reportFile"

        $IssueHistory += [pscustomobject]@{
            IssueKey      = $issueKey
            DetectorName  = $detectorName
            SeverityScore = $severityScore
            FirstSeenUtc  = (Get-Date).ToUniversalTime().ToString("o")
            LastSeenUtc   = (Get-Date).ToUniversalTime().ToString("o")
            DatabaseName  = $Database
            SqlInstance   = $SqlInstance
            ReportFile    = $reportFile
        }

        Save-IssueHistory -IssueHistory $IssueHistory -HistoryFile $HistoryFile
    }
}
