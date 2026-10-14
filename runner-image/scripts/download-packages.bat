@echo off

REM ---------------------------------------------------------------------------
REM download-packages.bat
REM Reads a package-runner lock file and copies verified aritifacts on Windows
REM Requires cmd.exe, Windows Powershell 5.1, yq v4
REM ---------------------------------------------------------------------------
setlocal EnableExtensions EnableDelayedExpansion

:: Initialize variables
set "LOCK_FILE="
set "OUTPUT_DIR=packages"
set "MOUNT_ROOT=%PACKAGE_CONTENT_MOUNT_ROOT%"
set "PS_EXE=%SystemRoot%\System32\WindowsPowershell\v1.0\powershell.exe"

if "%~1"=="" goto :usage


:: If PACKAGE_CONTENT_MOUNT_ROOT is not set, default to current directory\packages
if not defined MOUNT_ROOT set "MOUNT_ROOT=\\fileshare\Shared\image-factory\package-content"

:: Parse arguments
:parse_args
if "%~1"=="" goto :validate
if /I "%~1"=="--lock" (
    if "%~2"=="" goto :usage
    set "LOCK_FILE=%~2"
    shift
    shift
    goto :parse_args
)
if /I "%~1"=="--output" (
    if "%~2"=="" goto :usage
    set "OUTPUT_DIR=%~2"
    shift
    shift
    goto :parse_args
)
if /I "%~1"=="--mount-root" (
    if "%~2"=="" goto :usage
    set "MOUNT_ROOT=%~2"
    shift
    shift
    goto :parse_args
)
if /I "%~1"=="-h" goto :usage
if /I "%~1"=="--help" goto :usage
>&2 echo Unknown argument: %~1
goto :usage


:validate
if not defined LOCK_FILE goto :usage

where yq.exe >nul 2>&1
if errorlevel 1 (
    >&2 echo yq.exe is required and must be on PATH
    exit /b 1
)
if not exist "%LOCK_FILE%" (
    >&2 echo Lock file not found: %LOCK_FILE%
    exit /b 1
)

if "%MOUNT_ROOT%"=="" (
    >&2 echo Mount root not set. Use --mount-root or set PACKAGE_CONTENT_MOUNT_ROOT.
    exit /b 1
)

if not exist "%MOUNT_ROOT%" (
    >&2 echo Package repository mount not found: %MOUNT_ROOT%
    exit /b 1
)

echo output dir "%OUTPUT_DIR%"

REM Create output directory
if not exist "%OUTPUT_DIR%" mkdir "%OUTPUT_DIR%"
if errorlevel 1 (
    >&2 echo Unable to create output directory: %OUTPUT_DIR%
    exit /b 1
)

echo Starting package download from lock file %LOCK_FILE%
echo Output directory: %OUTPUT_DIR%
echo Mount root: %MOUNT_ROOT%
echo.

REM Get package count
call :yq_get ".packages | length" PACKAGE_COUNT
if "%PACKAGE_COUNT%"=="" set "PACKAGE_COUNT=0"
echo Found %PACKAGE_COUNT% packages to download

@REM  for /f "delims=" %%C in ('yq.exe eval ".packages | length" "%LOCK_FILE%"') do set "PACKAGE_COUNT=%%C"
@REM  if not defined PACKAGE_COUNT (
@REM      >&2 echo Could not read packages from lock file.
@REM      exit /b 1    
@REM  )
 
set /a FAILURES=0
set /a SUCCESS=0
set /a LAST_INDEX=PACKAGE_COUNT-1



REM Process each package
for /L %%I in (0,1,%LAST_INDEX%) do call :process_package %%I

echo.
echo --- Download Summary ---
echo Successful: %SUCCESS%
echo Failed: %FAILURES%

if %FAILURES% GTR 0 (
    >&2 echo Completed with %FAILURES% failure^(s^)
    exit /b 1
)

echo [OK] All %SUCCESS% packages downloaded are verified successfully.
exit /b 0

REM ---------------------------------------------------------------------------
REM :process_package "<index>" 
REM ---------------------------------------------------------------------------
:process_package
set "IDX=%~1"

call :yq_get ".packages[%IDX%].name" NAME
call :yq_get ".packages[%IDX%].version" VERSION
call :yq_get ".packages[%IDX%].artifact" ARTIFACT_EXISTS

@REM  if not "%ARTIFACT_EXISTS%"=="true" (
@REM      echo ARTIFACT CONTAINS: %ARTIFACT_EXISTS%
@REM      echo [WARN] SKIP: %NAME% %VERSION% -No artifact defined
@REM      exit /b 0
@REM  )

call :yq_get ".packages[%IDX%].artifact.repository" REPO
call :yq_get ".packages[%IDX%].artifact.path" REL_PATH
call :yq_get ".packages[%IDX%].artifact.filename" FILENAME
call :yq_get ".packages[%IDX%].artifact.sha256" EXPECTED_SHA256
call :yq_get ".packages[%IDX%].artifact.sizeBytes" EXPECTED_SIZE

if "%REPO%"=="" set "REPO=package-content"
if "%EXPECTED_SIZE%"=="" set "EXPECTED_SIZE=0"

echo ==^> Downloading: %NAME% v%VERSION%

REM Resolve source and destination paths (normalize / to \)
call :resolve_repo_root "%REPO%"
if not "%REL_PATH%"=="" set "REL_PATH=%REL_PATH:/=\%"
if "%REL_PATH%"=="" (
    set "SRC=%REPO_ROOT%\%FILENAME%"
) else (
    set "SRC=%REPO_ROOT%\%REL_PATH%\%FILENAME%"
)
set "DEST_DIR=%OUTPUT_DIR%\%NAME%\%VERSION%"
set "DEST=%DEST_DIR%\%FILENAME%"

REM Validate source exists
if not exist "%SRC%" (
    >&2 echo    [FAIL] Source artifact not found: %SRC%
    set /a FAILURES+=1
    exit /b 0
)

echo Destination dir %DEST_DIR%
REM Create destination directory
if not exist "%DEST_DIR%\" mkdir %DEST_DIR%

REM Copy the file
echo Copying: %FILENAME%
copy /Y "%SRC%" "%DEST%" >nul
if errorlevel 1 (
    >&2 echo    [FAIL] Copy Failed: %SRC%
    set /a FAILURES+=1
    exit /b 0
)

REM Verify size
for %%F in (%DEST%) do set "ACTUAL_SIZE=%%~zF"
if not "%EXPECTED_SIZE%"=="0" if not "%ACTUAL_SIZE%"=="%EXPECTED_SIZE%" (
    >&2 echo    [FAIL] Size mismatch ^(expected %EXPECTED_SIZE%, got %ACTUAL_SIZE%)
    del /F /Q "%DEST%" >nul 2>&1
    set /a FAILURES+=1
    exit /b 0 
)

REM Verify SHA256 if provided
if "%EXPECTED_SHA256%"=="" goto package_ok
echo    Verifying SHA256...
call :sha256_of "%DEST%"
if /I not "%ACTUAL_SHAT256%"=="%EXPECTED_SHA256%" (
    >&2 echo    [FAIL] SHA256 mismatch ^(expected %EXPECTED_SHA256%, got %ACTUAL_SHA256%^)
    del /F /Q "%DEST%" >NUL 2>&1
    set /a FAILURES+=1
    exit /b 0
)

:package_ok
echo    [OK] SUCCESS: Downloaded to %DEST%
set /a SUCCESS+=1
exit /b 0


REM ---------------------------------------------------------------------------
REM :yq_get "<expression>" <VAR> - "null" is returned as empty
REM ---------------------------------------------------------------------------
:yq_get
set "_YQ_VAL="
for /f "usebackq delims=" %%V in (`yq eval "%~1" "%LOCK_FILE%"`) do set "_YQ_VAL=%%V"
if "%_YQ_VAL%"=="null" set "_YQ_VAL="
set "%~2=%_YQ_VAL%"
exit /b 0

REM ---------------------------------------------------------------------------
REM :resolve_repo_root "<repo>"
REM For now only the default package-content repository is supported
REM ---------------------------------------------------------------------------
:resolve_repo_root
set "REPO_ROOT=%MOUNT_ROOT%"
exit /b 0

REM ---------------------------------------------------------------------------
REM :sha256_of "<file>" sets ACTUAL_SHA256 via Powershell
REM Path is passed through an env var to avoid quoting issues 
REM ---------------------------------------------------------------------------
:sha256_of
set "ACTUAL_SHA256="
set "PKG_HASH_FILE=%~1"
for /f "usebackq delims=" %%H in (`%PS_EXE% -NoLogo -NoProfile -NonInteractive -Command "(Get-FileHash -Algorithm SHA256 -LiteralPath $env:PKG_HASH_FILE).Hash.ToLower()"`) do set "ACTUAL_SHA256=%H"
exit /b 0


@REM  :: Check results
@REM  if %failures% gtr 0 (
@REM      echo Completed with %failures% failure(s) >&2
@REM      exit /b 1
@REM  )

@REM  echo All packages downloaded and verified.
@REM  endlocal

:: Usage function
:usage
echo.
echo Usage: %~nx0 --lock ^<lock.yaml^> [--output ^<package-root-dir^>] [--mount-root ^<path^>]
echo.
echo   --lock          Path to the package-runner lock file (yaml)
echo   --output        Directory to copy resolved package artifacts into
echo                     (default: packages)
echo   --mount-root    Local mount point for the package-content repository
echo                     (default: %%PACKAGE_CONTENT_MOUNT_ROOT%% or %%CD%%\packages)
echo.
exit /b 1