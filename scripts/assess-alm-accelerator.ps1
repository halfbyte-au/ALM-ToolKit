<#
.SYNOPSIS
    Inventories an ALM Accelerator for Power Platform installation and the
    pipeline files in a local repository, as the first step of a migration.

.DESCRIPTION
    Read-only. Connects to a Dataverse environment with an Entra app
    registration (client-credentials flow, raw REST - no PowerShell module
    dependencies) and reports:

      * ALM Accelerator solutions, detected by name pattern
      * Connection references and their connector types
      * Environment variables, distinguishing set / default-only / unset
      * Azure DevOps and GitHub Actions pipeline files in a local repo

    Nothing in the environment or repository is modified.

    Credentials are taken from parameters or, when a parameter is omitted,
    from the environment variables TENANT_ID, CLIENT_ID, CLIENT_SECRET and
    DATAVERSE_URL.

.PARAMETER TenantId
    Microsoft Entra tenant ID. Defaults to $env:TENANT_ID.

.PARAMETER ClientId
    App registration (client) ID. Defaults to $env:CLIENT_ID.

.PARAMETER ClientSecret
    App registration client secret as a SecureString. Defaults to
    $env:CLIENT_SECRET.

.PARAMETER DataverseUrl
    Environment URL, e.g. https://orgxxxxx.crm.dynamics.com.
    Defaults to $env:DATAVERSE_URL.

.PARAMETER RepoPath
    Path to a local clone of the repository holding the ALM Accelerator
    pipelines. Optional; the repository scan is skipped when omitted.

.PARAMETER SkipDataverse
    Only scan the repository; do not connect to Dataverse.

.PARAMETER OutputPath
    Folder to write assessment.json, assessment.md and assessment.html into. Optional.

.PARAMETER SolutionNamePattern
    Regular expressions matched (case-insensitively) against solution unique
    and display names to detect ALM Accelerator solutions. Override only if
    your installation was renamed.

.EXAMPLE
    ./assess-alm-accelerator.ps1 -RepoPath ../my-alm-repo -OutputPath ./assessment-output

.EXAMPLE
    ./assess-alm-accelerator.ps1 -SkipDataverse -RepoPath ../my-alm-repo
#>
[CmdletBinding()]
param(
    [string]$TenantId = $env:TENANT_ID,
    [string]$ClientId = $env:CLIENT_ID,
    [securestring]$ClientSecret,
    [string]$DataverseUrl = $env:DATAVERSE_URL,
    [string]$RepoPath,
    [switch]$SkipDataverse,
    [string]$OutputPath,
    [string[]]$SolutionNamePattern = @(
        'ALM\s*Accelerator',
        'CenterofExcellenceALMAccelerator',
        'ALMAccelerator'
    )
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:DataverseApiVersion = 'v9.2'

# Friendly names for environmentvariabledefinition.type option set values.
$script:EnvironmentVariableTypes = @{
    100000000 = 'String'
    100000001 = 'Number'
    100000002 = 'Boolean'
    100000003 = 'JSON'
    100000004 = 'Data source'
    100000005 = 'Secret'
}

# Content markers that indicate a pipeline file came from the ALM Accelerator
# pipeline templates rather than being hand-written.
$script:AlmAcceleratorPipelineMarkers = @(
    'coe-alm-accelerator-templates',
    'coe-alm-templates',
    'export-solution-to-git',
    'import-unmanaged-to-dev-environment',
    'delete-unmanaged-solution-and-components',
    'build-deploy-'
)

class AssessmentException : System.Exception {
    AssessmentException([string]$message) : base($message) {}
}

#region Pure logic (unit tested, no network)

function Test-AlmAcceleratorSolutionName {
    <#
    .SYNOPSIS
        Returns $true when a solution's unique or display name matches any
        ALM Accelerator name pattern.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowEmptyString()][AllowNull()][string]$UniqueName,
        [AllowEmptyString()][AllowNull()][string]$FriendlyName,
        [Parameter(Mandatory)][string[]]$Pattern
    )

    foreach ($p in $Pattern) {
        if (($UniqueName -and $UniqueName -match "(?i)$p") -or
            ($FriendlyName -and $FriendlyName -match "(?i)$p")) {
            return $true
        }
    }
    return $false
}

function Select-AlmAcceleratorSolution {
    <#
    .SYNOPSIS
        Filters Dataverse solution rows down to the ALM Accelerator ones.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][object[]]$Solution = @(),
        [Parameter(Mandatory)][string[]]$Pattern
    )

    foreach ($s in $Solution) {
        if (Test-AlmAcceleratorSolutionName -UniqueName $s.uniquename -FriendlyName $s.friendlyname -Pattern $Pattern) {
            [pscustomobject]@{
                UniqueName  = $s.uniquename
                DisplayName = $s.friendlyname
                Version     = $s.version
                IsManaged   = [bool]$s.ismanaged
                InstalledOn = $s.installedon
            }
        }
    }
}

function Get-ConnectorName {
    <#
    .SYNOPSIS
        Extracts the connector name from a connector ID such as
        /providers/Microsoft.PowerApps/apis/shared_commondataserviceforapps.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][AllowNull()][string]$ConnectorId)

    if ([string]::IsNullOrWhiteSpace($ConnectorId)) { return '(unknown)' }
    return ($ConnectorId.TrimEnd('/') -split '/')[-1]
}

function ConvertTo-ConnectionReferenceRecord {
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$ConnectionReference = @())

    foreach ($c in $ConnectionReference) {
        [pscustomobject]@{
            LogicalName = $c.connectionreferencelogicalname
            DisplayName = $c.connectionreferencedisplayname
            Connector   = Get-ConnectorName -ConnectorId $c.connectorid
            IsBound     = -not [string]::IsNullOrWhiteSpace($c.connectionid)
        }
    }
}

function Get-EnvironmentVariableStatus {
    <#
    .SYNOPSIS
        'Set' when a current value exists, 'Default only' when only the
        definition's default is present, otherwise 'Unset'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()][AllowNull()][string]$DefaultValue,
        [AllowEmptyCollection()][AllowNull()][object[]]$Value
    )

    $current = @($Value | Where-Object { $null -ne $_ -and -not [string]::IsNullOrEmpty($_.value) })
    if ($current.Count -gt 0) { return 'Set' }
    if (-not [string]::IsNullOrEmpty($DefaultValue)) { return 'Default only' }
    return 'Unset'
}

function ConvertTo-EnvironmentVariableRecord {
    <#
    .SYNOPSIS
        Normalises environmentvariabledefinition rows (with the expanded
        value relationship). Values themselves are never included in the
        report - only whether one is present - so output is safe to share.
    #>
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Definition = @())

    foreach ($d in $Definition) {
        $values = @()
        if ($d.PSObject.Properties.Name -contains 'environmentvariabledefinition_environmentvariablevalue') {
            $values = @($d.environmentvariabledefinition_environmentvariablevalue)
        }
        $typeName = $script:EnvironmentVariableTypes[[int]$d.type]
        if (-not $typeName) { $typeName = "Unknown ($($d.type))" }

        [pscustomobject]@{
            SchemaName  = $d.schemaname
            DisplayName = $d.displayname
            Type        = $typeName
            Status      = Get-EnvironmentVariableStatus -DefaultValue $d.defaultvalue -Value $values
        }
    }
}

function Get-PipelineKind {
    <#
    .SYNOPSIS
        Classifies a YAML file as 'GitHubActions', 'AzureDevOps' or $null.
    .PARAMETER RelativePath
        Path relative to the repository root, using / or \ separators.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [AllowEmptyString()][AllowNull()][string]$Content
    )

    $path = $RelativePath -replace '\\', '/'
    if ($path -notmatch '(?i)\.ya?ml$') { return $null }

    if ($path -match '(?i)(^|/)\.github/workflows/[^/]+$') { return 'GitHubActions' }
    if ($path -match '(?i)(^|/)\.github/') { return $null }

    if ($path -match '(?i)(^|/)azure-pipelines[^/]*$') { return 'AzureDevOps' }

    if ($Content) {
        # Azure DevOps task references look like "- task: Name@1".
        if ($Content -match '(?m)^\s*-?\s*task:\s*[\w.\-]+@\d+') { return 'AzureDevOps' }
        $hasStructure = $Content -match '(?m)^(stages|jobs|steps):'
        $hasAdoKeyword = $Content -match '(?m)^(trigger|pr|pool|resources|variables|extends):'
        if ($hasStructure -and $hasAdoKeyword) { return 'AzureDevOps' }
        # Template files (stages/jobs/steps with parameters) are also ADO.
        if ($hasStructure -and $Content -match '(?m)^parameters:') { return 'AzureDevOps' }
    }
    return $null
}

function Test-AlmAcceleratorPipelineContent {
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowEmptyString()][AllowNull()][string]$Content)

    if (-not $Content) { return $false }
    foreach ($marker in $script:AlmAcceleratorPipelineMarkers) {
        if ($Content -match [regex]::Escape($marker)) { return $true }
    }
    return $false
}

function Resolve-DataverseUrl {
    <#
    .SYNOPSIS
        Validates and normalises a Dataverse environment URL.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][AllowNull()][string]$Url)

    if ([string]::IsNullOrWhiteSpace($Url)) {
        throw [AssessmentException]::new('Dataverse URL is missing. Pass -DataverseUrl or set DATAVERSE_URL (e.g. https://orgxxxxx.crm.dynamics.com).')
    }
    $uri = $null
    if (-not [uri]::TryCreate($Url.Trim(), [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https') {
        throw [AssessmentException]::new("Dataverse URL '$Url' is not a valid https URL (expected e.g. https://orgxxxxx.crm.dynamics.com).")
    }
    return "https://$($uri.Host)"
}

function Resolve-AuthErrorMessage {
    <#
    .SYNOPSIS
        Turns an Entra token endpoint error body into an actionable message.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][AllowNull()][string]$ResponseBody)

    $code = $null
    $description = $null
    if ($ResponseBody) {
        try {
            $json = $ResponseBody | ConvertFrom-Json
            $description = $json.error_description
            if ($description -match '(AADSTS\d+)') { $code = $Matches[1] }
            elseif ($json.error_codes) { $code = "AADSTS$($json.error_codes[0])" }
        }
        catch {
            $description = $ResponseBody
        }
    }

    $advice = switch ($code) {
        'AADSTS7000215' { 'The client secret is wrong. Copy the secret VALUE (not the secret ID) from the app registration''s Certificates & secrets page.' }
        'AADSTS7000222' { 'The client secret has expired. Create a new secret on the app registration and update CLIENT_SECRET.' }
        'AADSTS700016' { 'No app registration with this client ID exists in the tenant. Check CLIENT_ID and TENANT_ID.' }
        'AADSTS90002' { 'The tenant was not found. Check TENANT_ID.' }
        'AADSTS900023' { 'The tenant ID is malformed. Check TENANT_ID.' }
        'AADSTS900021' { 'The tenant ID is not valid. Check TENANT_ID.' }
        'AADSTS500011' { 'The Dataverse resource was not found in this tenant. Check DATAVERSE_URL belongs to the same tenant as the app registration.' }
        default { 'Check TENANT_ID, CLIENT_ID and CLIENT_SECRET.' }
    }

    $message = "Authentication failed. $advice"
    if ($code) { $message += " [$code]" }
    return $message
}

function Resolve-DataverseErrorMessage {
    <#
    .SYNOPSIS
        Turns a Dataverse Web API error into an actionable message.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [int]$StatusCode,
        [AllowEmptyString()][AllowNull()][string]$ResponseBody,
        [string]$Operation = 'query Dataverse'
    )

    $apiMessage = $null
    $apiCode = $null
    if ($ResponseBody) {
        try {
            $json = $ResponseBody | ConvertFrom-Json
            $apiMessage = $json.error.message
            $apiCode = $json.error.code
        }
        catch { $apiMessage = $null }
    }

    # 0x80072560: the app has a token but no Application User in this environment.
    if ($apiCode -eq '0x80072560' -or $apiMessage -match 'not a member of the organization') {
        return "Could not $Operation. The app registration has no Application User in this Dataverse environment. Add it in Power Platform admin center > Environment > Settings > Users + permissions > Application users, and assign a security role."
    }
    if ($StatusCode -eq 401) {
        return "Could not $Operation. Dataverse rejected the access token (401). Check DATAVERSE_URL is the environment the Application User was created in."
    }
    if ($StatusCode -eq 403 -or $apiCode -eq '0x80040220' -or $apiMessage -match '(?i)privilege') {
        $detail = if ($apiMessage) { " Dataverse said: $apiMessage" } else { '' }
        return "Could not $Operation. The Application User lacks the required privileges (403). Assign it a security role with organization-level Read on Solution, Connection Reference and Environment Variable Definition/Value (System Administrator or System Customizer works).$detail"
    }
    if ($StatusCode -eq 404) {
        return "Could not $Operation. The endpoint was not found (404). Check DATAVERSE_URL points at a Dataverse environment."
    }
    $suffix = if ($apiMessage) { " Dataverse said: $apiMessage" } else { '' }
    return "Could not $Operation (HTTP $StatusCode).$suffix"
}

function New-AssessmentReport {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$EnvironmentHost,
        [AllowNull()][object[]]$Solution,
        [AllowNull()][object[]]$ConnectionReference,
        [AllowNull()][object[]]$EnvironmentVariable,
        [AllowNull()][object[]]$PipelineFile,
        [bool]$DataverseScanned,
        [bool]$RepoScanned
    )

    $sol = @($Solution | Where-Object { $_ })
    $cr = @($ConnectionReference | Where-Object { $_ })
    $ev = @($EnvironmentVariable | Where-Object { $_ })
    $pf = @($PipelineFile | Where-Object { $_ })

    [pscustomobject]@{
        GeneratedUtc          = (Get-Date).ToUniversalTime().ToString('o')
        Environment           = $EnvironmentHost
        DataverseScanned      = $DataverseScanned
        RepoScanned           = $RepoScanned
        AlmAcceleratorFound   = $sol.Count -gt 0
        AlmAcceleratorSolutions = $sol
        ConnectionReferences  = $cr
        EnvironmentVariables  = $ev
        PipelineFiles         = $pf
        Summary               = [pscustomobject]@{
            AlmAcceleratorSolutions      = $sol.Count
            ConnectionReferences         = $cr.Count
            UnboundConnectionReferences  = @($cr | Where-Object { -not $_.IsBound }).Count
            EnvironmentVariables         = $ev.Count
            EnvironmentVariablesUnset    = @($ev | Where-Object { $_.Status -eq 'Unset' }).Count
            AzureDevOpsPipelineFiles     = @($pf | Where-Object { $_.Kind -eq 'AzureDevOps' }).Count
            GitHubActionsWorkflowFiles   = @($pf | Where-Object { $_.Kind -eq 'GitHubActions' }).Count
            AlmAcceleratorPipelineFiles  = @($pf | Where-Object { $_.FromAlmAccelerator }).Count
        }
    }
}

function ConvertTo-AssessmentMarkdown {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][object]$Report)

    $sb = [System.Text.StringBuilder]::new()
    $s = $Report.Summary
    [void]$sb.AppendLine('# ALM Accelerator Assessment')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("Generated (UTC): $($Report.GeneratedUtc)")
    if ($Report.Environment) { [void]$sb.AppendLine("Environment: $($Report.Environment)") }
    [void]$sb.AppendLine()

    [void]$sb.AppendLine('## ALM Accelerator solutions')
    [void]$sb.AppendLine()
    if (-not $Report.DataverseScanned) {
        [void]$sb.AppendLine('_Dataverse not scanned._')
    }
    elseif (-not $Report.AlmAcceleratorFound) {
        [void]$sb.AppendLine('Not found. No installed solution matches the ALM Accelerator name patterns.')
    }
    else {
        [void]$sb.AppendLine('| Unique name | Display name | Version | Managed |')
        [void]$sb.AppendLine('|---|---|---|---|')
        foreach ($x in $Report.AlmAcceleratorSolutions) {
            [void]$sb.AppendLine("| $($x.UniqueName) | $($x.DisplayName) | $($x.Version) | $($x.IsManaged) |")
        }
    }
    [void]$sb.AppendLine()

    if ($Report.DataverseScanned) {
        [void]$sb.AppendLine("## Connection references ($($s.ConnectionReferences), $($s.UnboundConnectionReferences) unbound)")
        [void]$sb.AppendLine()
        if ($s.ConnectionReferences -eq 0) {
            [void]$sb.AppendLine('None.')
        }
        else {
            [void]$sb.AppendLine('| Logical name | Display name | Connector | Bound |')
            [void]$sb.AppendLine('|---|---|---|---|')
            foreach ($x in $Report.ConnectionReferences) {
                [void]$sb.AppendLine("| $($x.LogicalName) | $($x.DisplayName) | $($x.Connector) | $($x.IsBound) |")
            }
        }
        [void]$sb.AppendLine()

        [void]$sb.AppendLine("## Environment variables ($($s.EnvironmentVariables), $($s.EnvironmentVariablesUnset) unset)")
        [void]$sb.AppendLine()
        if ($s.EnvironmentVariables -eq 0) {
            [void]$sb.AppendLine('None.')
        }
        else {
            [void]$sb.AppendLine('| Schema name | Display name | Type | Status |')
            [void]$sb.AppendLine('|---|---|---|---|')
            foreach ($x in $Report.EnvironmentVariables) {
                [void]$sb.AppendLine("| $($x.SchemaName) | $($x.DisplayName) | $($x.Type) | $($x.Status) |")
            }
        }
        [void]$sb.AppendLine()
    }

    [void]$sb.AppendLine('## Pipeline files')
    [void]$sb.AppendLine()
    if (-not $Report.RepoScanned) {
        [void]$sb.AppendLine('_Repository not scanned._')
    }
    elseif (@($Report.PipelineFiles).Count -eq 0) {
        [void]$sb.AppendLine('No Azure DevOps or GitHub Actions pipeline files found.')
    }
    else {
        [void]$sb.AppendLine("Azure DevOps: $($s.AzureDevOpsPipelineFiles) | GitHub Actions: $($s.GitHubActionsWorkflowFiles) | From ALM Accelerator templates: $($s.AlmAcceleratorPipelineFiles)")
        [void]$sb.AppendLine()
        [void]$sb.AppendLine('| Path | Kind | ALM Accelerator template |')
        [void]$sb.AppendLine('|---|---|---|')
        foreach ($x in $Report.PipelineFiles) {
            [void]$sb.AppendLine("| $($x.Path) | $($x.Kind) | $($x.FromAlmAccelerator) |")
        }
    }
    return $sb.ToString()
}

function ConvertTo-AssessmentHtml {
    <#
    .SYNOPSIS
        Renders the report as one self-contained HTML page (inline CSS, no scripts,
        no external requests). All values are HTML-encoded.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][object]$Report)

    $s = $Report.Summary
    $enc = { param($v) [System.Net.WebUtility]::HtmlEncode([string]$v) }

    $card = {
        param($Label, $Value, $Tone)
        "<div class=`"card $Tone`"><div class=`"num`">$(& $enc $Value)</div><div class=`"lbl`">$(& $enc $Label)</div></div>"
    }
    $table = {
        param([string[]]$Headers, [object[]]$Rows)
        $t = [System.Text.StringBuilder]::new()
        [void]$t.Append('<table><thead><tr>')
        foreach ($h in $Headers) { [void]$t.Append("<th>$(& $enc $h)</th>") }
        [void]$t.Append('</tr></thead><tbody>')
        foreach ($r in $Rows) {
            [void]$t.Append('<tr>')
            foreach ($c in $r) { [void]$t.Append("<td>$(& $enc $c)</td>") }
            [void]$t.Append('</tr>')
        }
        [void]$t.Append('</tbody></table>')
        $t.ToString()
    }

    $body = [System.Text.StringBuilder]::new()

    # Summary cards
    [void]$body.Append('<div class="cards">')
    if ($Report.DataverseScanned) {
        $almText = if ($Report.AlmAcceleratorFound) { 'Installed' } else { 'Not found' }
        $almTone = if ($Report.AlmAcceleratorFound) { 'warn' } else { 'ok' }
        [void]$body.Append((& $card 'ALM Accelerator' $almText $almTone))
        $crTone = if ($s.UnboundConnectionReferences -gt 0) { 'warn' } else { 'ok' }
        [void]$body.Append((& $card "Connection references ($($s.UnboundConnectionReferences) unbound)" $s.ConnectionReferences $crTone))
        $evTone = if ($s.EnvironmentVariablesUnset -gt 0) { 'warn' } else { 'ok' }
        [void]$body.Append((& $card "Environment variables ($($s.EnvironmentVariablesUnset) unset)" $s.EnvironmentVariables $evTone))
    }
    if ($Report.RepoScanned) {
        [void]$body.Append((& $card 'Azure DevOps pipeline files' $s.AzureDevOpsPipelineFiles 'info'))
        [void]$body.Append((& $card 'GitHub Actions workflow files' $s.GitHubActionsWorkflowFiles 'info'))
    }
    [void]$body.Append('</div>')

    # ALM Accelerator solutions
    [void]$body.Append('<h2>ALM Accelerator solutions</h2>')
    if (-not $Report.DataverseScanned) {
        [void]$body.Append('<p class="muted">Dataverse not scanned.</p>')
    }
    elseif (-not $Report.AlmAcceleratorFound) {
        [void]$body.Append('<p>Not found. No installed solution matches the ALM Accelerator name patterns.</p>')
    }
    else {
        $rows = @($Report.AlmAcceleratorSolutions | ForEach-Object { , @($_.UniqueName, $_.DisplayName, $_.Version, $_.IsManaged) })
        [void]$body.Append((& $table @('Unique name', 'Display name', 'Version', 'Managed') $rows))
    }

    if ($Report.DataverseScanned) {
        [void]$body.Append('<h2>Connection references</h2>')
        if ($s.ConnectionReferences -eq 0) { [void]$body.Append('<p>None.</p>') }
        else {
            $rows = @($Report.ConnectionReferences | ForEach-Object { , @($_.LogicalName, $_.DisplayName, $_.Connector, $(if ($_.IsBound) { 'Bound' } else { 'Unbound' })) })
            [void]$body.Append((& $table @('Logical name', 'Display name', 'Connector', 'Connection') $rows))
        }

        [void]$body.Append('<h2>Environment variables</h2>')
        if ($s.EnvironmentVariables -eq 0) { [void]$body.Append('<p>None.</p>') }
        else {
            $rows = @($Report.EnvironmentVariables | ForEach-Object { , @($_.SchemaName, $_.DisplayName, $_.Type, $_.Status) })
            [void]$body.Append((& $table @('Schema name', 'Display name', 'Type', 'Status') $rows))
            [void]$body.Append('<p class="muted">Values are never shown.</p>')
        }
    }

    [void]$body.Append('<h2>Pipeline files</h2>')
    if (-not $Report.RepoScanned) { [void]$body.Append('<p class="muted">Repository not scanned.</p>') }
    elseif (@($Report.PipelineFiles).Count -eq 0) { [void]$body.Append('<p>No Azure DevOps or GitHub Actions pipeline files found.</p>') }
    else {
        $rows = @($Report.PipelineFiles | ForEach-Object { , @($_.Path, $_.Kind, $(if ($_.FromAlmAccelerator) { 'Yes' } else { 'No' })) })
        [void]$body.Append((& $table @('Path', 'Kind', 'From ALM Accelerator template') $rows))
    }

    $envLine = if ($Report.Environment) { " &middot; Environment: $(& $enc $Report.Environment)" } else { '' }
    $css = @'
:root{--bg:#fff;--fg:#1b1f24;--muted:#5b6570;--line:#d8dee4;--card:#f6f8fa;--ok:#1a7f37;--warn:#9a6700;--info:#0969da}
@media (prefers-color-scheme:dark){:root{--bg:#0d1117;--fg:#e6edf3;--muted:#8b949e;--line:#30363d;--card:#161b22;--ok:#3fb950;--warn:#d29922;--info:#58a6ff}}
body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.5 system-ui,-apple-system,Segoe UI,sans-serif}
main{max-width:960px;margin:0 auto;padding:24px 16px}
h1{margin:0 0 4px;font-size:24px}h2{margin:32px 0 8px;font-size:18px}
.muted{color:var(--muted)}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:12px;margin-top:20px}
.card{background:var(--card);border:1px solid var(--line);border-left:4px solid var(--info);border-radius:6px;padding:12px 14px}
.card.ok{border-left-color:var(--ok)}.card.warn{border-left-color:var(--warn)}
.num{font-size:26px;font-weight:600}.lbl{color:var(--muted);font-size:13px}
table{width:100%;border-collapse:collapse;display:block;overflow-x:auto}
th,td{text-align:left;padding:6px 10px;border-bottom:1px solid var(--line);white-space:nowrap}
th{color:var(--muted);font-weight:600;font-size:13px}
'@

    return @"
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>ALM Accelerator Assessment</title><style>$css</style></head>
<body><main>
<h1>ALM Accelerator Assessment</h1>
<div class="muted">Generated (UTC): $(& $enc $Report.GeneratedUtc)$envLine</div>
$($body.ToString())
</main></body></html>
"@
}

#endregion

#region I/O (filesystem and network)

function Find-PipelineFile {
    <#
    .SYNOPSIS
        Scans a local repository for Azure DevOps and GitHub Actions YAML.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw [AssessmentException]::new("Repository path '$Path' does not exist or is not a folder.")
    }
    $root = (Resolve-Path -LiteralPath $Path).ProviderPath.TrimEnd([IO.Path]::DirectorySeparatorChar)

    $files = Get-ChildItem -LiteralPath $root -Recurse -File -Force -Include '*.yml', '*.yaml' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '[\\/](\.git|node_modules)[\\/]' }

    foreach ($f in $files) {
        $relative = $f.FullName.Substring($root.Length).TrimStart('\', '/') -replace '\\', '/'
        $content = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction SilentlyContinue
        $kind = Get-PipelineKind -RelativePath $relative -Content $content
        if ($kind) {
            [pscustomobject]@{
                Path               = $relative
                Kind               = $kind
                FromAlmAccelerator = Test-AlmAcceleratorPipelineContent -Content $content
            }
        }
    }
}

function Get-HttpErrorDetail {
    param([System.Management.Automation.ErrorRecord]$ErrorRecord)

    $status = 0
    $response = $ErrorRecord.Exception.PSObject.Properties['Response']
    if ($response -and $response.Value) { $status = [int]$response.Value.StatusCode }
    $body = if ($ErrorRecord.ErrorDetails) { $ErrorRecord.ErrorDetails.Message } else { $null }
    return @{ StatusCode = $status; Body = $body }
}

function Get-DataverseAccessToken {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][securestring]$ClientSecret,
        [Parameter(Mandatory)][string]$ResourceUrl
    )

    $body = @{
        grant_type    = 'client_credentials'
        client_id     = $ClientId
        client_secret = [System.Net.NetworkCredential]::new('', $ClientSecret).Password
        scope         = "$ResourceUrl/.default"
    }
    $uri = "https://login.microsoftonline.com/$([uri]::EscapeDataString($TenantId))/oauth2/v2.0/token"
    try {
        $response = Invoke-RestMethod -Method Post -Uri $uri -Body $body -ContentType 'application/x-www-form-urlencoded'
        return $response.access_token
    }
    catch {
        $detail = Get-HttpErrorDetail -ErrorRecord $_
        if ($detail.StatusCode -eq 0 -and -not $detail.Body) {
            throw [AssessmentException]::new("Could not reach login.microsoftonline.com: $($_.Exception.Message)")
        }
        throw [AssessmentException]::new((Resolve-AuthErrorMessage -ResponseBody $detail.Body))
    }
    finally {
        $body.client_secret = $null
    }
}

function Invoke-DataverseQuery {
    <#
    .SYNOPSIS
        GETs a Web API resource, following @odata.nextLink paging. Any error
        is terminating so the report is never silently partial.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$AccessToken,
        [Parameter(Mandatory)][string]$Query,
        [Parameter(Mandatory)][string]$Operation
    )

    $headers = @{
        Authorization      = "Bearer $AccessToken"
        Accept             = 'application/json'
        'OData-MaxVersion' = '4.0'
        'OData-Version'    = '4.0'
        Prefer             = 'odata.maxpagesize=500'
    }
    $uri = "$BaseUrl/api/data/$($script:DataverseApiVersion)/$Query"
    while ($uri) {
        try {
            $page = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers
        }
        catch {
            $detail = Get-HttpErrorDetail -ErrorRecord $_
            if ($detail.StatusCode -eq 0 -and -not $detail.Body) {
                throw [AssessmentException]::new("Could not $Operation. Network error reaching $BaseUrl : $($_.Exception.Message)")
            }
            throw [AssessmentException]::new((Resolve-DataverseErrorMessage -StatusCode $detail.StatusCode -ResponseBody $detail.Body -Operation $Operation))
        }
        if ($page.PSObject.Properties.Name -contains 'value') {
            foreach ($row in $page.value) { $row }
        }
        else {
            $page
        }
        $next = $page.PSObject.Properties['@odata.nextLink']
        $uri = if ($next) { $next.Value } else { $null }
    }
}

#endregion

function Invoke-Assessment {
    [CmdletBinding()]
    param(
        [string]$TenantId,
        [string]$ClientId,
        [securestring]$ClientSecret,
        [string]$DataverseUrl,
        [string]$RepoPath,
        [switch]$SkipDataverse,
        [string]$OutputPath,
        [string[]]$SolutionNamePattern
    )

    if ($SkipDataverse -and -not $RepoPath) {
        throw [AssessmentException]::new('Nothing to do: -SkipDataverse was given without -RepoPath.')
    }

    $environmentHost = $null
    $solutions = @(); $connRefs = @(); $envVars = @()
    if (-not $SkipDataverse) {
        $missing = @()
        if ([string]::IsNullOrWhiteSpace($TenantId)) { $missing += 'TENANT_ID' }
        if ([string]::IsNullOrWhiteSpace($ClientId)) { $missing += 'CLIENT_ID' }
        if (-not $ClientSecret -or $ClientSecret.Length -eq 0) { $missing += 'CLIENT_SECRET' }
        if ([string]::IsNullOrWhiteSpace($DataverseUrl)) { $missing += 'DATAVERSE_URL' }
        if ($missing) {
            throw [AssessmentException]::new("Missing configuration: $($missing -join ', '). Set these environment variables (see .env.example) or pass the matching parameters. Use -SkipDataverse to scan only a repository.")
        }

        $baseUrl = Resolve-DataverseUrl -Url $DataverseUrl
        $environmentHost = ([uri]$baseUrl).Host

        Write-Host "Authenticating to $environmentHost ..."
        $token = Get-DataverseAccessToken -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret -ResourceUrl $baseUrl

        $q = @{ BaseUrl = $baseUrl; AccessToken = $token }
        [void](Invoke-DataverseQuery @q -Query 'WhoAmI' -Operation 'verify the Application User (WhoAmI)')

        Write-Host 'Reading solutions ...'
        $allSolutions = @(Invoke-DataverseQuery @q -Operation 'read solutions' `
                -Query 'solutions?$select=uniquename,friendlyname,version,ismanaged,installedon&$filter=isvisible eq true')
        $solutions = @(Select-AlmAcceleratorSolution -Solution $allSolutions -Pattern $SolutionNamePattern)

        Write-Host 'Reading connection references ...'
        $connRefs = @(ConvertTo-ConnectionReferenceRecord -ConnectionReference @(
                Invoke-DataverseQuery @q -Operation 'read connection references' `
                    -Query 'connectionreferences?$select=connectionreferencelogicalname,connectionreferencedisplayname,connectorid,connectionid'))

        Write-Host 'Reading environment variables ...'
        $envVars = @(ConvertTo-EnvironmentVariableRecord -Definition @(
                Invoke-DataverseQuery @q -Operation 'read environment variables' `
                    -Query 'environmentvariabledefinitions?$select=schemaname,displayname,type,defaultvalue&$expand=environmentvariabledefinition_environmentvariablevalue($select=value)'))
    }

    $pipelineFiles = @()
    if ($RepoPath) {
        Write-Host "Scanning repository $RepoPath ..."
        $pipelineFiles = @(Find-PipelineFile -Path $RepoPath | Sort-Object Kind, Path)
    }

    $report = New-AssessmentReport -EnvironmentHost $environmentHost -Solution $solutions `
        -ConnectionReference $connRefs -EnvironmentVariable $envVars -PipelineFile $pipelineFiles `
        -DataverseScanned (-not $SkipDataverse) -RepoScanned ([bool]$RepoPath)

    $markdown = ConvertTo-AssessmentMarkdown -Report $report
    if ($OutputPath) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
        $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutputPath 'assessment.json') -Encoding utf8
        $markdown | Set-Content -LiteralPath (Join-Path $OutputPath 'assessment.md') -Encoding utf8
        ConvertTo-AssessmentHtml -Report $report | Set-Content -LiteralPath (Join-Path $OutputPath 'assessment.html') -Encoding utf8
        Write-Host "Wrote assessment.json, assessment.md and assessment.html to $OutputPath"
    }
    Write-Host ''
    Write-Host $markdown
    return $report
}

# Run only when executed, not when dot-sourced by the unit tests.
if ($MyInvocation.InvocationName -ne '.') {
    if (-not $PSBoundParameters.ContainsKey('ClientSecret') -and $env:CLIENT_SECRET) {
        $ClientSecret = ConvertTo-SecureString -String $env:CLIENT_SECRET -AsPlainText -Force
    }
    try {
        Invoke-Assessment -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret `
            -DataverseUrl $DataverseUrl -RepoPath $RepoPath -SkipDataverse:$SkipDataverse `
            -OutputPath $OutputPath -SolutionNamePattern $SolutionNamePattern | Out-Null
    }
    catch [AssessmentException] {
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
    catch {
        Write-Host "ERROR: Unexpected failure: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host 'Re-run with -Verbose and include the output when reporting an issue.' -ForegroundColor Red
        Write-Verbose ($_ | Out-String)
        exit 1
    }
}
