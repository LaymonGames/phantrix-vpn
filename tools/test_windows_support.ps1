param(
  [ValidateSet('Debug', 'Release')]
  [string]$Configuration = 'Debug'
)

$ErrorActionPreference = 'Stop'
$buildDirectory = Join-Path $PSScriptRoot '..\build\windows\x64'
$cmakeCommand = Get-Command cmake -ErrorAction SilentlyContinue
if ($null -ne $cmakeCommand) {
  $cmakePath = $cmakeCommand.Source
} else {
  $cmakePath = Join-Path ${env:ProgramFiles(x86)} `
    'Microsoft Visual Studio\2022\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
}
if (-not (Test-Path -LiteralPath $cmakePath)) {
  throw "CMake was not found at $cmakePath."
}

& $cmakePath --build $buildDirectory --config $Configuration --target phantrix_ovpn_support_test
if ($LASTEXITCODE -ne 0) {
  throw "Building the Windows tunnel support tests failed with exit code $LASTEXITCODE."
}

$executables = @(Get-ChildItem -Path $buildDirectory -Filter 'phantrix_ovpn_support_test.exe' -File -Recurse |
  Where-Object { $_.Directory.Name -eq $Configuration })
if ($executables.Count -ne 1) {
  throw "Expected one tunnel support test executable, found $($executables.Count)."
}

& $executables[0].FullName
if ($LASTEXITCODE -ne 0) {
  throw "Windows tunnel support tests failed with exit code $LASTEXITCODE."
}
