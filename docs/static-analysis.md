# Static analysis notes

CI runs PSScriptAnalyzer (Error and Warning severity) over `scripts/` and
`tests/integration/`, using `PSScriptAnalyzerSettings.psd1`. These rules are excluded on
purpose:

| Rule | Why it's excluded |
|---|---|
| `PSAvoidUsingWriteHost` | Both scripts are interactive tools that print a colour-coded report for a human. Their data result goes to `-OutputPath` files, not the pipeline. |
| `PSAvoidUsingConvertToSecureStringWithPlainText` | `CLIENT_SECRET` arrives as a plain environment variable, which is the documented configuration method. It is converted to a `SecureString` once, at the entry point, and turned back into plain text only inside the token request body. That value is cleared afterwards. |
| `PSUseShouldProcessForStateChangingFunctions` | `New-AssessmentReport` only builds an in-memory object and changes no state. |

Unit tests (`tests/unit/`) aren't linted. Pester's `BeforeAll`/`It` scoping triggers
false positives such as `PSUseDeclaredVarsMoreThanAssignments`.
