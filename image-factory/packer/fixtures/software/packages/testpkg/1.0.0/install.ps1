# Fixture install script. Not a real installer: it writes one marker file into Program
# Files, so that a completed machine-wide install leaves something a validation can check
# (ADR 0003, "What installed correctly means"). It changes nothing else.
#
# Self-contained on purpose. In the lock shape the package tooling reads today a package is
# exactly one file (ADR 0003, "Interim lock shape"), and the powershell handler runs that
# file, so this script is the whole package and cannot rely on a payload beside it.
$ErrorActionPreference = 'Stop'

$target = Join-Path -Path $env:ProgramFiles -ChildPath 'testpkg'
New-Item -ItemType Directory -Path $target -Force | Out-Null
Set-Content -LiteralPath (Join-Path -Path $target -ChildPath 'testpkg-1.0.0.txt') -Value 'testpkg 1.0.0 fixture' -Encoding ASCII

exit 0
