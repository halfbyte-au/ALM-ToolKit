# PSScriptAnalyzer settings used by CI and local linting:
#   Invoke-ScriptAnalyzer -Path ./scripts -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
#
# Deliberate exclusions (see docs/static-analysis.md for the reasoning):
#   PSAvoidUsingWriteHost                          - interactive, colour-coded console report for humans
#   PSAvoidUsingConvertToSecureStringWithPlainText - CLIENT_SECRET arrives as a plain env var; it is
#                                                    converted to SecureString once, at the entry point
#   PSUseShouldProcessForStateChangingFunctions    - New-AssessmentReport only builds an in-memory object
@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        'PSAvoidUsingWriteHost',
        'PSAvoidUsingConvertToSecureStringWithPlainText',
        'PSUseShouldProcessForStateChangingFunctions'
    )
}
