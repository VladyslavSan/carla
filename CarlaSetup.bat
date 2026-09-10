@echo off
setlocal EnableDelayedExpansion

set skip_prerequisites=false
set launch=false
set interactive=false
set python_path=python
set python_root=

rem -- PARSE COMMAND LINE ARGUMENTS --

:parse
    if "%1"=="" (
        goto main
    )
    if "%1"=="--interactive" (
        set interactive=true
    ) else if "%1"=="-i" (
        set interactive=true
    ) else if "%1"=="--skip-prerequisites" (
        set skip_prerequisites=true
    ) else if "%1"=="-p" (
        set skip_prerequisites=true
    ) else if "%1"=="--launch" (
        set launch=true
    ) else if "%1"=="-l" (
        set launch=true
    ) else (
        echo %1 | findstr /B /C:"--python-root=" >nul
        if not errorlevel 1 (
            set python_root="%1"
            set python_root="!python_root:--python-root=!"
        ) else if "%1"=="--python-root" (
            set python_root=%2
            shift
        ) else if "%1"=="-pyroot" (
            set python_root=%2
            shift
        ) else (
            echo Unknown argument "%1"
            exit /b
        )
    )
    shift
    goto parse

rem -- MAIN --

:main

if not "%python_root%"=="" (
    set python_path=%python_root%\python
)

rem -- PREREQUISITES INSTALL STEP --

if %skip_prerequisites%==false (
    echo Installing prerequisites...
    call Util/SetupUtils/InstallPrerequisites.bat --python-path=%python_path% || exit /b
) else (
    echo Skipping prerequisites install step.
)

rem -- CLONE CONTENT --
if exist "%cd%\Unreal\CarlaUnreal\Content" (
    echo Found CARLA content.
) else (
    echo Could not find CARLA content. Downloading...
    mkdir %cd%\Unreal\CarlaUnreal\Content
    git ^
        -C %cd%\Unreal\CarlaUnreal\Content ^
        clone ^
        -b ue5-dev ^
        https://bitbucket.org/carla-simulator/carla-content.git ^
        Carla ^
    || exit /b
)

rem Activate VS terminal development environment:
rem Find whichever installed VS instance actually has the toolset CARLA
rem needs, instead of hardcoding a year/edition folder name -- a machine
rem can have multiple VS versions installed and the newest one is not
rem necessarily the one with the required (pinned) MSVC toolset.
rem NOTE: these tracking vars are deliberately NOT named vs_* / vc_* -- the
rem cleanup loop below wipes every VS*/VC*-prefixed variable to undo a
rem pre-existing dev environment, and it would wipe its own state too.
rem Relies on vswhere.exe already being on PATH -- if it isn't, this
rem silently finds nothing and falls into the "not found" branch below,
rem same as a genuinely missing toolset.
set "carla_setup_devenv_path="
for /f "usebackq tokens=*" %%i in (`vswhere -all -products * -requires Microsoft.VisualStudio.Component.VC.14.38.17.8.x86.x64 -property installationPath -latest 2^>nul`) do (
    set "carla_setup_devenv_path=%%i"
)

set "carla_setup_devenv_bat="
if not "!carla_setup_devenv_path!"=="" if exist "!carla_setup_devenv_path!\VC\Auxiliary\Build\vcvars64.bat" (
    set "carla_setup_devenv_bat=!carla_setup_devenv_path!\VC\Auxiliary\Build\vcvars64.bat"
)

if not "!carla_setup_devenv_bat!"=="" (
    rem If a different VS version's dev environment is already active in this
    rem shell (e.g. activated by the user's terminal profile), its leftover
    rem VS/VC/WindowsSDK variables make VsDevCmd.bat think it is already
    rem initialized for the wrong version and it silently no-ops instead of
    rem switching -- so cl.exe would keep resolving to the wrong toolset even
    rem though vcvars64.bat reports success. Clear them first.
    for /f "tokens=1 delims==" %%v in ('set 2^>nul ^| findstr /I /R "^VS ^VC ^WindowsSDK ^EXTERNAL_INCLUDE ^__VSCMD"') do (
        set "%%v="
    )
    echo Activating "x64 Native Tools Command Prompt" terminal environment for "!carla_setup_devenv_path!".
    call "!carla_setup_devenv_bat!" || exit /b
) else (
    echo Could not find a Visual Studio installation with the required VC++ toolset ^(14.38.17.8^), aborting setup...
    echo Run Util\SetupUtils\InstallPrerequisites.bat first, or add the missing component via the Visual Studio Installer.
    exit /b 1
)

rem -- DOWNLOAD + BUILD UNREAL ENGINE --
if exist "%CARLA_UNREAL_ENGINE_PATH%" (
    echo Found Unreal Engine 5 at "%CARLA_UNREAL_ENGINE_PATH%".
) else if exist ..\UnrealEngine5_carla (
    pushd ..\UnrealEngine5_carla
    set "CARLA_UNREAL_ENGINE_PATH=!cd!"
    setx CARLA_UNREAL_ENGINE_PATH "!cd!" >nul
    popd
    echo Found CARLA Unreal Engine clone at "!CARLA_UNREAL_ENGINE_PATH!".
) else (
    echo Could not find CARLA Unreal Engine, downloading...
    pushd ..
    git clone ^
        -b ue5-dev-carla ^
        https://github.com/CarlaUnreal/UnrealEngine.git ^
        UnrealEngine5_carla || exit /b
    pushd UnrealEngine5_carla
    set "CARLA_UNREAL_ENGINE_PATH=!cd!"
    setx CARLA_UNREAL_ENGINE_PATH "!cd!" >nul
    popd
    popd
)

rem The engine build (msbuild) is incremental, so re-running it is cheap even
rem if a previous run already finished. Skipping it just because the clone
rem directory exists is NOT safe: an interrupted build leaves the directory
rem in place while the Editor binary is still missing, which used to make
rem this script silently hand CARLA an incomplete (or, if the env var wasn't
rem set at all, completely empty) engine path.
if exist "!CARLA_UNREAL_ENGINE_PATH!\Engine\Binaries\Win64\UnrealEditor.exe" (
    echo Found built Unreal Engine 5 Editor at "!CARLA_UNREAL_ENGINE_PATH!".
) else (
    echo Building Unreal Engine 5 ^(incremental -- safe to re-run if interrupted^)...
    pushd "!CARLA_UNREAL_ENGINE_PATH!"
    echo Running Unreal Engine pre-build steps...
    call Setup.bat || exit /b
    call GenerateProjectFiles.bat || exit /b
    echo Building Unreal Engine 5...
    msbuild ^
        Engine\Intermediate\ProjectFiles\UE5.vcxproj ^
        /property:Configuration="Development_Editor" ^
        /property:Platform="x64" || exit /b
    popd
)

rem -- BUILD CARLA --
echo Configuring the CARLA CMake project...
cmake ^
    -G Ninja ^
    -S . ^
    -B Build ^
    --toolchain=CMake/Toolchain.cmake ^
    -DPython_ROOT_DIR=%python_root% ^
    -DPython3_ROOT_DIR=%python_root% ^
    -DCMAKE_BUILD_TYPE=Release ^
    -DCARLA_UNREAL_ENGINE_PATH=%CARLA_UNREAL_ENGINE_PATH% || exit /b
echo Building CARLA...
cmake --build Build || exit /b
echo Installing Python API...
cmake --build Build --target carla-python-api-install || exit /b
echo CARLA Python API build+install succeeded.

rem -- POST-BUILD STEPS --

if %launch%==true (
    echo Launching Carla Unreal Editor...
    cmake --build Build --target launch || exit /b
)
