#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot '..' '..' 'scripts' 'assess-alm-accelerator.ps1')

    $script:Fixtures = Join-Path $PSScriptRoot 'fixtures'
    function Get-Fixture([string]$Name) {
        Get-Content -Raw -LiteralPath (Join-Path $script:Fixtures $Name)
    }
    $script:DefaultPattern = @('ALM\s*Accelerator', 'CenterofExcellenceALMAccelerator', 'ALMAccelerator')
}

Describe 'Test-AlmAcceleratorSolutionName' {
    It 'matches <Unique> / <Friendly>' -ForEach @(
        @{ Unique = 'CenterofExcellenceALMAccelerator'; Friendly = '' }
        @{ Unique = 'something'; Friendly = 'ALM Accelerator for Power Platform' }
        @{ Unique = 'almacceleratorsamplesolution'; Friendly = $null }
    ) {
        Test-AlmAcceleratorSolutionName -UniqueName $Unique -FriendlyName $Friendly -Pattern $DefaultPattern | Should -BeTrue
    }

    It 'does not match <Unique> / <Friendly>' -ForEach @(
        @{ Unique = 'contoso_Expenses'; Friendly = 'Expense Tracker' }
        @{ Unique = 'fabrikam_AlmTools'; Friendly = 'Team ALM Tools' }
        @{ Unique = ''; Friendly = '' }
        @{ Unique = $null; Friendly = $null }
    ) {
        Test-AlmAcceleratorSolutionName -UniqueName $Unique -FriendlyName $Friendly -Pattern $DefaultPattern | Should -BeFalse
    }

    It 'honours a custom pattern' {
        Test-AlmAcceleratorSolutionName -UniqueName 'contoso_RenamedAccel' -FriendlyName '' -Pattern 'RenamedAccel' | Should -BeTrue
    }
}

Describe 'Select-AlmAcceleratorSolution' {
    It 'selects only ALM Accelerator solutions from fixture data' {
        $rows = (Get-Fixture 'solutions.json' | ConvertFrom-Json).value
        $result = @(Select-AlmAcceleratorSolution -Solution $rows -Pattern $DefaultPattern)
        $result.UniqueName | Should -Be @('CenterofExcellenceALMAccelerator', 'ALMAcceleratorSampleSolution')
        $result[0].IsManaged | Should -BeTrue
        $result[1].IsManaged | Should -BeFalse
    }

    It 'returns nothing when no solution matches (no false positive)' {
        $rows = (Get-Fixture 'solutions.json' | ConvertFrom-Json).value |
            Where-Object { $_.uniquename -notmatch 'ALM' }
        @(Select-AlmAcceleratorSolution -Solution $rows -Pattern $DefaultPattern).Count | Should -Be 0
    }

    It 'handles an empty solution list' {
        @(Select-AlmAcceleratorSolution -Solution @() -Pattern $DefaultPattern).Count | Should -Be 0
    }
}

Describe 'ConvertTo-ConnectionReferenceRecord' {
    BeforeAll {
        $rows = (Get-Fixture 'connectionreferences.json' | ConvertFrom-Json).value
        $script:ConnRefs = @(ConvertTo-ConnectionReferenceRecord -ConnectionReference $rows)
    }

    It 'returns one record per connection reference' {
        $ConnRefs.Count | Should -Be 3
    }

    It 'extracts connector types' {
        $ConnRefs.Connector | Should -Be @('shared_commondataserviceforapps', 'shared_office365', '(unknown)')
    }

    It 'flags bound and unbound references' {
        $ConnRefs.IsBound | Should -Be @($true, $false, $false)
    }
}

Describe 'ConvertTo-EnvironmentVariableRecord' {
    BeforeAll {
        $rows = (Get-Fixture 'environmentvariables.json' | ConvertFrom-Json).value
        $script:EnvVars = @(ConvertTo-EnvironmentVariableRecord -Definition $rows)
    }

    It 'distinguishes set, default-only and unset' {
        $EnvVars.Status | Should -Be @('Set', 'Default only', 'Unset', 'Set', 'Unset')
    }

    It 'maps type option set values to names' {
        $EnvVars.Type | Should -Be @('String', 'Number', 'Boolean', 'Secret', 'Unknown (999)')
    }

    It 'never includes variable values in the output' {
        $json = $EnvVars | ConvertTo-Json -Depth 5
        $json | Should -Not -Match 'example\.invalid'
        $json | Should -Not -Match 'keyvault-reference'
    }

    It 'treats a definition without the expanded relationship as having no current value' {
        $row = [pscustomobject]@{ schemaname = 'x'; displayname = 'x'; type = 100000000; defaultvalue = $null }
        (ConvertTo-EnvironmentVariableRecord -Definition @($row)).Status | Should -Be 'Unset'
    }
}

Describe 'Get-PipelineKind' {
    It 'classifies <Path> as <Expected>' -ForEach @(
        @{ Path = '.github/workflows/ci.yml'; Content = 'on: push'; Expected = 'GitHubActions' }
        @{ Path = 'sub\.github\workflows\deploy.yaml'; Content = ''; Expected = 'GitHubActions' }
        @{ Path = 'azure-pipelines.yml'; Content = ''; Expected = 'AzureDevOps' }
        @{ Path = 'build/azure-pipelines-release.yaml'; Content = ''; Expected = 'AzureDevOps' }
        @{ Path = 'Pipelines/x.yml'; Content = "steps:`n- task: PowerPlatformToolInstaller@2"; Expected = 'AzureDevOps' }
        @{ Path = 'Pipelines/y.yml'; Content = "trigger: none`nstages:`n- stage: Build"; Expected = 'AzureDevOps' }
        @{ Path = 'Templates/t.yml'; Content = "parameters:`n- name: a`nsteps:`n- script: echo"; Expected = 'AzureDevOps' }
    ) {
        Get-PipelineKind -RelativePath $Path -Content $Content | Should -Be $Expected
    }

    It 'ignores <Path>' -ForEach @(
        @{ Path = 'src/config.yml'; Content = 'foo: bar' }
        @{ Path = '.github/dependabot.yml'; Content = "version: 2`nupdates: []" }
        @{ Path = 'README.md'; Content = 'steps:' }
        @{ Path = 'docker-compose.yaml'; Content = "services:`n  web: {}" }
    ) {
        Get-PipelineKind -RelativePath $Path -Content $Content | Should -BeNullOrEmpty
    }
}

Describe 'Test-AlmAcceleratorPipelineContent' {
    It 'detects ALM Accelerator template references' {
        Test-AlmAcceleratorPipelineContent -Content '- template: ../coe-alm-accelerator-templates/Pipelines/Templates/build-deploy-validation.yml' | Should -BeTrue
    }
    It 'returns false for ordinary pipelines and empty content' {
        Test-AlmAcceleratorPipelineContent -Content "steps:`n- script: dotnet build" | Should -BeFalse
        Test-AlmAcceleratorPipelineContent -Content '' | Should -BeFalse
    }
}

Describe 'Find-PipelineFile' {
    BeforeEach {
        $script:Repo = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory -Path $Repo | Out-Null
        function Add-RepoFile([string]$Rel, [string]$Text) {
            $full = Join-Path $script:Repo $Rel
            New-Item -ItemType Directory -Path (Split-Path $full) -Force | Out-Null
            Set-Content -LiteralPath $full -Value $Text
        }
    }

    It 'finds Azure DevOps pipelines only' {
        Add-RepoFile 'Pipelines/build-deploy-validation-App.yml' "trigger: none`nstages:`n- template: ../coe-alm-accelerator-templates/x.yml"
        $r = @(Find-PipelineFile -Path $Repo)
        $r.Count | Should -Be 1
        $r[0].Kind | Should -Be 'AzureDevOps'
        $r[0].FromAlmAccelerator | Should -BeTrue
        $r[0].Path | Should -Be 'Pipelines/build-deploy-validation-App.yml'
    }

    It 'finds GitHub Actions workflows only' {
        Add-RepoFile '.github/workflows/ci.yml' "on: push`njobs: {}"
        $r = @(Find-PipelineFile -Path $Repo)
        $r.Count | Should -Be 1
        $r[0].Kind | Should -Be 'GitHubActions'
    }

    It 'finds both kinds without one suppressing the other' {
        Add-RepoFile '.github/workflows/ci.yml' "on: push`njobs: {}"
        Add-RepoFile 'azure-pipelines.yml' "pool: default`nsteps:`n- script: echo"
        $r = @(Find-PipelineFile -Path $Repo)
        ($r | Where-Object Kind -EQ 'AzureDevOps').Count | Should -Be 1
        ($r | Where-Object Kind -EQ 'GitHubActions').Count | Should -Be 1
    }

    It 'returns nothing for a repo with neither' {
        Add-RepoFile 'src/app.json' '{}'
        Add-RepoFile 'config/settings.yml' 'foo: bar'
        @(Find-PipelineFile -Path $Repo).Count | Should -Be 0
    }

    It 'skips .git and node_modules' {
        Add-RepoFile 'node_modules/pkg/azure-pipelines.yml' 'pool: x'
        Add-RepoFile '.git/azure-pipelines.yml' 'pool: x'
        @(Find-PipelineFile -Path $Repo).Count | Should -Be 0
    }

    It 'throws a clear error for a missing path' {
        { Find-PipelineFile -Path (Join-Path $TestDrive 'does-not-exist') } | Should -Throw -ExpectedMessage '*does not exist*'
    }
}

Describe 'Resolve-DataverseUrl' {
    It 'normalises <In>' -ForEach @(
        @{ In = 'https://orgabc.crm.dynamics.com/'; Out = 'https://orgabc.crm.dynamics.com' }
        @{ In = ' https://orgabc.crm6.dynamics.com/main.aspx '; Out = 'https://orgabc.crm6.dynamics.com' }
    ) {
        Resolve-DataverseUrl -Url $In | Should -Be $Out
    }

    It 'rejects <In>' -ForEach @(
        @{ In = '' }
        @{ In = 'http://orgabc.crm.dynamics.com' }
        @{ In = 'orgabc.crm.dynamics.com' }
    ) {
        { Resolve-DataverseUrl -Url $In } | Should -Throw
    }
}

Describe 'Resolve-AuthErrorMessage' {
    It 'explains an invalid secret' {
        $m = Resolve-AuthErrorMessage -ResponseBody (Get-Fixture 'auth-error-7000215.json')
        $m | Should -Match 'secret is wrong'
        $m | Should -Match 'AADSTS7000215'
    }
    It 'explains an expired secret' {
        Resolve-AuthErrorMessage -ResponseBody (Get-Fixture 'auth-error-7000222.json') | Should -Match 'expired'
    }
    It 'falls back to a generic hint for an unknown or empty body' {
        Resolve-AuthErrorMessage -ResponseBody 'not json' | Should -Match 'Check TENANT_ID, CLIENT_ID and CLIENT_SECRET'
        Resolve-AuthErrorMessage -ResponseBody $null | Should -Match 'Authentication failed'
    }
    It 'never echoes the raw response body' {
        Resolve-AuthErrorMessage -ResponseBody (Get-Fixture 'auth-error-7000222.json') | Should -Not -Match "app '"
    }
}

Describe 'Resolve-DataverseErrorMessage' {
    It 'explains missing privileges' {
        $m = Resolve-DataverseErrorMessage -StatusCode 403 -ResponseBody (Get-Fixture 'dataverse-error-privilege.json') -Operation 'read solutions'
        $m | Should -Match 'lacks the required privileges'
        $m | Should -Match 'read solutions'
        $m | Should -Match 'prvReadSolution'
    }
    It 'explains a missing Application User' {
        Resolve-DataverseErrorMessage -StatusCode 403 -ResponseBody (Get-Fixture 'dataverse-error-not-member.json') |
            Should -Match 'no Application User'
    }
    It 'explains 401' {
        Resolve-DataverseErrorMessage -StatusCode 401 -ResponseBody '' | Should -Match '401'
    }
    It 'handles other status codes' {
        Resolve-DataverseErrorMessage -StatusCode 500 -ResponseBody $null | Should -Match 'HTTP 500'
    }
}

Describe 'Report' {
    BeforeAll {
        $script:Sol = @(Select-AlmAcceleratorSolution -Pattern $DefaultPattern -Solution (Get-Fixture 'solutions.json' | ConvertFrom-Json).value)
        $script:Cr = @(ConvertTo-ConnectionReferenceRecord -ConnectionReference (Get-Fixture 'connectionreferences.json' | ConvertFrom-Json).value)
        $script:Ev = @(ConvertTo-EnvironmentVariableRecord -Definition (Get-Fixture 'environmentvariables.json' | ConvertFrom-Json).value)
        $script:Pf = @(
            [pscustomobject]@{ Path = 'azure-pipelines.yml'; Kind = 'AzureDevOps'; FromAlmAccelerator = $true }
            [pscustomobject]@{ Path = '.github/workflows/ci.yml'; Kind = 'GitHubActions'; FromAlmAccelerator = $false }
        )
    }

    It 'summarises counts' {
        $r = New-AssessmentReport -EnvironmentHost 'org.example' -Solution $Sol -ConnectionReference $Cr `
            -EnvironmentVariable $Ev -PipelineFile $Pf -DataverseScanned $true -RepoScanned $true
        $r.AlmAcceleratorFound | Should -BeTrue
        $r.Summary.AlmAcceleratorSolutions | Should -Be 2
        $r.Summary.UnboundConnectionReferences | Should -Be 2
        $r.Summary.EnvironmentVariablesUnset | Should -Be 2
        $r.Summary.AzureDevOpsPipelineFiles | Should -Be 1
        $r.Summary.GitHubActionsWorkflowFiles | Should -Be 1
        $r.Summary.AlmAcceleratorPipelineFiles | Should -Be 1
    }

    It 'handles an empty assessment' {
        $r = New-AssessmentReport -EnvironmentHost $null -Solution @() -ConnectionReference @() `
            -EnvironmentVariable @() -PipelineFile @() -DataverseScanned $true -RepoScanned $true
        $r.AlmAcceleratorFound | Should -BeFalse
        $md = ConvertTo-AssessmentMarkdown -Report $r
        $md | Should -Match 'Not found'
        $md | Should -Match 'No Azure DevOps or GitHub Actions pipeline files found'
    }

    It 'renders markdown tables' {
        $r = New-AssessmentReport -EnvironmentHost 'org.example' -Solution $Sol -ConnectionReference $Cr `
            -EnvironmentVariable $Ev -PipelineFile $Pf -DataverseScanned $true -RepoScanned $true
        $md = ConvertTo-AssessmentMarkdown -Report $r
        $md | Should -Match '\| CenterofExcellenceALMAccelerator \|'
        $md | Should -Match '\| contoso_BatchSize \| Batch Size \| Number \| Default only \|'
        $md | Should -Match '\| \.github/workflows/ci\.yml \| GitHubActions \| False \|'
    }

    It 'marks sections that were not scanned' {
        $r = New-AssessmentReport -PipelineFile $Pf -DataverseScanned $false -RepoScanned $true
        $md = ConvertTo-AssessmentMarkdown -Report $r
        $md | Should -Match 'Dataverse not scanned'
        $md | Should -Not -Match 'Connection references'
    }
}

Describe 'ConvertTo-AssessmentHtml' {
    BeforeAll {
        $script:Sol = @(Select-AlmAcceleratorSolution -Pattern $DefaultPattern -Solution (Get-Fixture 'solutions.json' | ConvertFrom-Json).value)
        $script:Cr = @(ConvertTo-ConnectionReferenceRecord -ConnectionReference (Get-Fixture 'connectionreferences.json' | ConvertFrom-Json).value)
        $script:Ev = @(ConvertTo-EnvironmentVariableRecord -Definition (Get-Fixture 'environmentvariables.json' | ConvertFrom-Json).value)
        $script:Pf = @([pscustomobject]@{ Path = '.github/workflows/ci.yml'; Kind = 'GitHubActions'; FromAlmAccelerator = $false })
    }

    It 'renders a self-contained page with the report data' {
        $r = New-AssessmentReport -EnvironmentHost 'org.example' -Solution $Sol -ConnectionReference $Cr `
            -EnvironmentVariable $Ev -PipelineFile $Pf -DataverseScanned $true -RepoScanned $true
        $html = ConvertTo-AssessmentHtml -Report $r
        $html | Should -Match '^<!doctype html>'
        $html | Should -Match 'CenterofExcellenceALMAccelerator'
        $html | Should -Match 'contoso_BatchSize'
        $html | Should -Match 'GitHubActions'
        $html | Should -Not -Match '<script'
        $html | Should -Not -Match '(src|href)="https?:'
    }

    It 'reports a clean environment' {
        $r = New-AssessmentReport -Solution @() -ConnectionReference @() -EnvironmentVariable @() `
            -PipelineFile @() -DataverseScanned $true -RepoScanned $true
        $html = ConvertTo-AssessmentHtml -Report $r
        $html | Should -Match 'Not found'
        $html | Should -Match 'No Azure DevOps or GitHub Actions pipeline files found'
    }

    It 'marks sections that were not scanned' {
        $r = New-AssessmentReport -PipelineFile $Pf -DataverseScanned $false -RepoScanned $true
        $html = ConvertTo-AssessmentHtml -Report $r
        $html | Should -Match 'Dataverse not scanned'
        $html | Should -Not -Match 'Connection references'
    }

    It 'HTML-encodes values' {
        $evil = @([pscustomobject]@{ Path = '<script>alert(1)</script>.yml'; Kind = 'AzureDevOps'; FromAlmAccelerator = $false })
        $r = New-AssessmentReport -PipelineFile $evil -DataverseScanned $false -RepoScanned $true
        $html = ConvertTo-AssessmentHtml -Report $r
        $html | Should -Not -Match '<script>alert'
        $html | Should -Match '&lt;script&gt;'
    }
}

Describe 'Invoke-Assessment input validation' {
    It 'lists every missing setting' {
        { Invoke-Assessment -SolutionNamePattern $DefaultPattern } |
            Should -Throw -ExpectedMessage '*TENANT_ID, CLIENT_ID, CLIENT_SECRET, DATAVERSE_URL*'
    }
    It 'rejects -SkipDataverse without -RepoPath' {
        { Invoke-Assessment -SkipDataverse -SolutionNamePattern $DefaultPattern } | Should -Throw -ExpectedMessage '*Nothing to do*'
    }
}
