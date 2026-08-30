@echo off
setlocal enabledelayedexpansion
pushd "%~dp0"

set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "!VSWHERE!" echo vswhere.exe not found - install Visual Studio Build Tools. && exit /b 1

set VSPATH=
for /f "usebackq tokens=*" %%i in (`""!VSWHERE!" -latest -products * -property installationPath"`) do set "VSPATH=%%i"
if "!VSPATH!"=="" echo No Visual Studio installation found. && exit /b 1

call "%VSPATH%\Common7\Tools\VsDevCmd.bat" -arch=x86 -host_arch=x64 -no_logo >nul 2>&1
if errorlevel 1 exit /b 1

set MLFLAGS=/nologo /c /coff /W3 /safeseh /Isrc
set LINKFLAGS=/nologo /SUBSYSTEM:WINDOWS /OPT:REF /OPT:ICF /RELEASE /MERGE:.rdata=.text
if /i "%1"=="debug" (
    set MLFLAGS=%MLFLAGS% /Zi
    set LINKFLAGS=%LINKFLAGS% /DEBUG
)

if not exist build mkdir build

set OBJS=
for %%f in (main ui iso9660 theme vfs isowrite preview eltorito dragdrop worker udf udfwrite container strutil xdvdfs opera deflate) do (
    ml %MLFLAGS% /Fo build\%%f.obj src\%%f.asm || exit /b 1
    set OBJS=!OBJS! build\%%f.obj
)

rc /nologo /fo build\foximg.res res\foximg.rc || exit /b 1

link %LINKFLAGS% /OUT:build\FoxImg.exe %OBJS% build\foximg.res || exit /b 1

for %%f in (build\FoxImg.exe) do echo Built %%f (%%~zf bytes)
