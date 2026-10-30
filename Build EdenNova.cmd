@echo off
setlocal
cd /d "%~dp0"
echo EdenNova local APK builder
echo Downloads verified build tools and Eden source, then builds on this PC.
echo Nothing is uploaded. First build can take 30-60 minutes or longer.
echo Android SDK terms: https://developer.android.com/studio/terms
echo The setup installs SDK packages and accepts their license for this build.
echo Close this window to cancel, or press any key to begin.
pause >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Build.ps1"
set "BUILD_RESULT=%errorlevel%"
if not "%BUILD_RESULT%"=="0" (
  echo.
  echo Build failed. Read the message above and the logs folder.
) else (
  echo.
  echo Done. Your APK and build details are in the output folder.
)
pause
exit /b %BUILD_RESULT%
