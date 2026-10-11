# ALM Accelerator Migration Kit

Tools and guidance for moving Power Platform teams off the deprecated **ALM Accelerator
for Power Platform** onto pipelines you own: Azure DevOps or GitHub Actions.

> **This repository is the free, MIT-licensed assessment and migration guide.**
> Ready-made pipeline templates for Azure DevOps and GitHub Actions, with supporting
> automation, are in development as a separate paid add-on.
> [Register your interest](../../issues/new?template=interest.yml) to hear when it's ready
> and to tell me what you need.

## Quick start

Requires PowerShell 7+. No extra modules are needed.

```powershell
# 1. Configure (see .env.example for the variable names)
$env:TENANT_ID     = '<tenant-guid>'
$env:CLIENT_ID     = '<app-registration-guid>'
$env:CLIENT_SECRET = '<secret-value>'
$env:DATAVERSE_URL = 'https://<org>.crm.dynamics.com'

# 2. Assess an environment and your pipeline repo
./scripts/assess-alm-accelerator.ps1 -RepoPath ../your-alm-repo -OutputPath ./assessment-output

# Or scan only the repo, without connecting to Dataverse
./scripts/assess-alm-accelerator.ps1 -SkipDataverse -RepoPath ../your-alm-repo
```

The script is read-only. It reports:

- ALM Accelerator solutions installed, detected by name pattern
- Connection references, with connector type and whether each one is bound
- Environment variables, marked as set, default-only or unset. Values are never printed.
- Azure DevOps and GitHub Actions pipeline files, flagging ones built from ALM
  Accelerator templates

With `-OutputPath`, the script writes `assessment.html` (open it in any browser, no
internet needed), `assessment.md` and `assessment.json`.

Then follow [docs/migration-guide.md](docs/migration-guide.md).

## Repository layout

```
scripts/        assess-alm-accelerator.ps1
docs/           migration guide, static-analysis notes
tests/unit/     Pester tests (no network), run in CI
tests/integration/  live-environment wrapper, manual only
```

## Development

```powershell
Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser
Install-Module PSScriptAnalyzer -Scope CurrentUser

Invoke-Pester ./tests/unit
Invoke-ScriptAnalyzer -Path ./scripts -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
```

Never commit secrets, `.env` files or output from live runs. Keep real values in a gitignored `.env.testing`.
