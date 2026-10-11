# Integration tests (manual, live environment)

These scripts hit a real Dataverse environment. They are **never run in CI**.
Run them locally against a Dataverse developer environment, with an Entra app registration and a Dataverse Application User (see [the migration guide](../../docs/migration-guide.md), section 3).

## Setup

1. Copy `.env.example` at the repo root to `.env.testing` (gitignored) and fill it in,
   or export the same variables in your shell.
2. Check `git status` doesn't list `.env.testing` before you commit anything.

## Running

```powershell
# Full assessment, including a repository scan
./tests/integration/Invoke-LiveAssessment.ps1 -RepoPath ../path/to/alm-repo

# Test matrix #9: wrong client secret must fail with a clear message
./tests/integration/Invoke-LiveAssessment.ps1 -Scenario BadSecret
```

Each run writes `run.log`, `assessment.json` and `assessment.md` to
`tests/integration/output/<timestamp>-<scenario>/`, which is gitignored. That output
can contain tenant-specific names and GUIDs, so genericize it before copying any of it
into a committed file.

## Test matrix

| # | Scenario | How to set it up | Pass/Fail | Notes |
|---|---|---|---|---|
| 1 | ALM Accelerator installed | Install the ALM Accelerator solution in the test environment, run `Normal` | Pass | Tested with an empty stub solution carrying the real unique name. The real managed solution needs Creator Kit Core installed first (import fails otherwise). |
| 2 | ALM Accelerator not installed | Run `Normal` against a clean environment | Pass | No false positive, including with unrelated test solutions present. |
| 3 | Connection references present | Import any solution containing connection references | Pass | Built-in `msdyn_` references also listed, as unbound. |
| 4 | Environment variables, set and unset | Create one with a current value, one default-only, one with neither | Pass | Set, Default only and Unset all distinguished. |
| 5 | Repo has ADO pipelines | `-RepoPath` to a repo with `azure-pipelines*.yml` or ALM Accelerator pipelines | Pass | Local throwaway repo, `-SkipDataverse`. |
| 6 | Repo has GHA workflows | `-RepoPath` to a repo with `.github/workflows/*.yml` | Pass | Also confirmed against this repo. |
| 7 | Repo has both | `-RepoPath` to a repo with both | Pass | Neither platform suppresses the other. |
| 8 | Repo has neither | `-RepoPath` to a repo with no pipeline YAML | Pass | Reports cleanly. A non-pipeline YAML file was not flagged. |
| 9 | Auth failure | `-Scenario BadSecret` | Pass | Exit 1, clear message with AADSTS code, no stack trace. |
| 10 | Insufficient privileges | Give the Application User a role without Read on Solution (e.g. Basic User), run `Normal` | Pass | Basic User gives a 403 naming the missing privilege, exit 1, no partial result. System Customizer works. |
Scenarios 5–8 don't need Dataverse. You can also check them with
`./scripts/assess-alm-accelerator.ps1 -SkipDataverse -RepoPath <path>`.
