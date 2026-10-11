# Migrating off the ALM Accelerator for Power Platform

> **Status: draft, not yet verified against a live environment.** Steps marked
> **⚠ verify** will be checked against a real Dataverse environment during Phase 1
> testing, and this guide will be corrected to match what's actually observed.

This guide takes a Power Platform team from the deprecated ALM Accelerator for Power
Platform to a pipeline setup you own and maintain: Azure DevOps pipelines or GitHub
Actions, built on Microsoft's supported Power Platform tooling.

---

## 1. Why migrate

The ALM Accelerator was a community-supported CoE Starter Kit component: a canvas app,
a Dataverse solution, and a set of Azure DevOps pipeline templates. Microsoft has
deprecated it. It won't get fixes for platform changes, and its pipeline templates
depend on template repos and conventions that are no longer maintained.

The building blocks underneath it are still supported and actively maintained:

- **Power Platform Build Tools** for Azure DevOps
- **GitHub Actions for Power Platform** (`microsoft/powerplatform-actions`)
- **Power Platform CLI** (`pac`)
- **Deployment settings files** for connection references and environment variables
- **Power Platform Pipelines** (in-product), for teams that don't need source control

Migrating means keeping those building blocks and dropping the accelerator-specific
layer on top of them.

## 2. Concept mapping

| ALM Accelerator concept | Replacement | Notes |
|---|---|---|
| ALM Accelerator canvas app (maker "commit / deploy" UI) | Pipeline run triggered manually or on PR; optional request app (Phase 5) | Makers lose the in-app button until a request app exists; pipelines can still be queued directly. |
| `export-solution-to-git` pipeline | Export pipeline/workflow: `pac solution export` + `pac solution unpack`, commit to a branch, open a PR | Same outcome; you own the YAML. |
| `build-deploy-validation-*` / `-test-*` / `-prod-*` pipelines | One build job producing a managed solution artifact, plus a deploy stage/job per environment | Azure DevOps stages with environments and approvals, or GHA jobs with environments and required reviewers. |
| `coe-alm-accelerator-templates` repo references | Templates vendored into your own repo | Removes the dependency on an unmaintained external repo. |
| Deployment profiles / user settings in the ALM Accelerator app | Pipeline variables per environment (ADO variable groups or GHA environment variables/secrets) | |
| `deploymentSettings.json` / `customDeploymentSettings.json` | `deploymentSettings.json` passed to `pac solution import --settings-file` | The standard format is compatible. Custom settings for team sharing and canvas-app sharing need separate steps. **⚠ verify** |
| Azure DevOps service connections per environment (Power Platform SPN) | Same for ADO; for GHA, app ID/secret or federated credentials stored as environment secrets | Reuse the existing app registrations where possible. |
| Connection references | Unchanged. Mapped per environment in `deploymentSettings.json` | The assessment script lists them all, including unbound ones. |
| Environment variables | Unchanged. Values per environment in `deploymentSettings.json` | The assessment script flags unset ones, which usually need a per-environment value. |
| ALM Accelerator Dataverse tables | Not needed after migration | Remove them at decommission (§4 step 8). |

## 3. Before you start

- A Microsoft Entra app registration with a Dataverse **Application User** in each
  environment you'll assess. For the assessment it needs Read access to solutions,
  connection references, environment variable definitions and values. The
  **System Customizer** role is enough (tested). A role without Read on Solution, such
  as Basic User, fails with a 403 that names the missing privilege.

  To create all three pieces at once (app registration, secret and Application User),
  run this as a Global or Power Platform admin. It prints the client secret **once**,
  so capture it straight into your secret store:

  ```powershell
  pac auth create --environment https://<org>.crm.dynamics.com
  pac admin create-service-principal --environment https://<org>.crm.dynamics.com `
      --name "alm-assessment" --role "System Customizer"
  ```

  Flags can change between `pac` versions. Check `pac admin create-service-principal`
  first. The default role is System Administrator, so pass `--role` to narrow it. The
  secret it creates is valid for one year.
- PowerShell 7+ on the machine running the assessment. No extra modules are needed.
- A local clone of the repository holding your current ALM Accelerator pipelines.
- A decision on your target platform: **Azure DevOps** or **GitHub Actions**. Both are
  fully supported by this kit.

## 4. Migration steps

### Step 1: Assess

```powershell
$env:TENANT_ID = '<tenant-guid>'
$env:CLIENT_ID = '<app-guid>'
$env:CLIENT_SECRET = '<secret-value>'
$env:DATAVERSE_URL = 'https://<org>.crm.dynamics.com'

./scripts/assess-alm-accelerator.ps1 -RepoPath ../your-alm-repo -OutputPath ./assessment-output
```

Run it against **each** environment in your path (dev, test, prod). It writes
`assessment.html` (open it in a browser), `assessment.md` and `assessment.json`. Keep
the report for each environment; they become your migration checklist.

The script is read-only. It changes nothing in Dataverse or in the repository.

### Step 2: Review the assessment

For each environment, confirm:

- **ALM Accelerator solutions.** Which version is installed, and is it managed?
- **Unbound connection references.** Each one needs a connection mapped in the target
  environment's `deploymentSettings.json`. Microsoft's own built-in references (names
  starting `msdyn_`) also show as unbound in a fresh environment. Ignore those.
- **Unset environment variables.** Each one needs a value per environment.
- **Pipeline files flagged as ALM Accelerator templates.** These are what you'll replace.
  Pipeline files that aren't flagged are your own, so keep them.

### Step 3: Build deployment settings

For each solution, generate a starting settings file:

```bash
pac solution create-settings --solution-zip <Solution>_managed.zip --settings-file deploymentSettings.json
```

Create one copy per target environment. Fill in `ConnectionId` for each connection
reference and `Value` for each environment variable, using the assessment output as the
checklist. If you're migrating from an existing `deploymentSettings.json` in your ALM
Accelerator repo, copy the values across. **⚠ verify** that the format still matches the
current `pac` version.

### Step 4: Create the new pipelines

Build these alongside the existing ones, without deleting anything yet:

- **Export:** export the unmanaged solution from dev, unpack it, commit it to a branch, and open a PR.
- **Build:** pack a managed solution from source and publish it as an artifact.
- **Deploy:** import the artifact into test, then prod, using the environment's settings file.
  Add approvals or required reviewers on the prod environment.

Ready-made templates for both platforms are planned for Phases 2 (Azure DevOps) and 3
(GitHub Actions).

### Step 5: Run both in parallel

Deploy one low-risk solution through the new pipeline to **test**, then check:

- The solution version matches the one the ALM Accelerator would have deployed.
- Connection references are bound and flows are turned on.
- Environment variable values are correct.

Re-run the assessment against test and compare it with the earlier output.

### Step 6: Cut over

1. Announce a freeze on ALM Accelerator deployments.
2. Deploy each solution through the new pipelines, in dependency order.
3. Disable the ALM Accelerator pipelines. Keep them for now; don't delete them.
4. Point makers at the new process (the pipeline run, or the request app once it exists).

### Step 7: Monitor

Run at least one full dev → test → prod cycle on the new pipelines before you
decommission anything.

### Step 8: Decommission

Once you're confident in the new pipelines:

- Delete the disabled ALM Accelerator pipelines and the `coe-alm-accelerator-templates` repo reference.
- Uninstall the ALM Accelerator solution from the environments where it's installed.
  **⚠ verify** the uninstall order if multiple solutions are installed.
- Remove ALM Accelerator–specific service connections and variable groups that are no longer used.

## 5. Rollback plan

Nothing in steps 1–5 changes the ALM Accelerator setup, so rolling back before cutover
just means you stop using the new pipelines.

After cutover (step 6), and until decommission (step 8):

1. Re-enable the disabled ALM Accelerator pipelines.
2. If a solution deployed by the new pipeline is broken, redeploy the last good managed
   version. You can use the ALM Accelerator pipeline's last successful run, or the
   previous artifact from the new build pipeline.
3. Record what failed before trying the cutover again.

After decommission, rollback means redeploying earlier managed artifacts through the new
pipelines. The ALM Accelerator isn't coming back at that point, which is why step 7
comes first.

A scripted rollback pattern is planned for Phase 6.

## 6. Troubleshooting the assessment script

| Message | Cause | Fix |
|---|---|---|
| `Missing configuration: ...` | Env vars or parameters not set | Set them. See `.env.example`. |
| `Authentication failed. The client secret is wrong. [AADSTS7000215]` | Secret ID was used instead of the secret value, or there's a typo | Copy the secret **value** from Certificates & secrets. |
| `... has expired [AADSTS7000222]` | Secret expired | Create a new secret. |
| `No app registration with this client ID ... [AADSTS700016]` | Wrong CLIENT_ID, or wrong tenant | Check both IDs. |
| `The tenant was not found [AADSTS90002]` | Wrong TENANT_ID | Use the Directory (tenant) ID from Entra. |
| `... has no Application User in this Dataverse environment` | App registration isn't added to the environment | Power Platform admin center → Environment → Settings → Application users → New app user. |
| `... lacks the required privileges (403)` | Application User has no suitable role | Assign System Customizer or System Administrator, or a custom role with org-level Read on the tables listed. |
| `Dataverse URL ... is not a valid https URL` | Wrong URL format | Use `https://<org>.crm<N>.dynamics.com`. |
| ALM Accelerator not detected, but you know it's installed | Solution was renamed | Pass `-SolutionNamePattern '<your pattern>'`. |
