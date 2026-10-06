#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$flutterProject = Split-Path -Parent $PSScriptRoot
$androidProject = Join-Path $flutterProject 'android'
$localProperties = Join-Path $androidProject 'local.properties'

# Flutter generates Windows drive letters without escaping the colon. Keep
# these machine-local paths valid for Android lint; never suppress PropertyEscape.
if (Test-Path -LiteralPath $localProperties) {
    $propertyText = Get-Content -LiteralPath $localProperties -Raw
    Set-Content -LiteralPath $localProperties -Value ($propertyText -replace '(?<!\\):', '\:') -Encoding ASCII
}

Push-Location $androidProject
try {
    # Lint does not track local.properties as an input, so refresh its report.
    & .\gradlew.bat :app:lintAnalyzeDebug --rerun :app:lintReportDebug --rerun :app:lintDebug
    if ($LASTEXITCODE -ne 0) { throw "Android lint failed with exit code $LASTEXITCODE" }
} finally {
    Pop-Location
}
