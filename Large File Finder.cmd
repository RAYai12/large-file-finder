@echo off
rem Double-click launcher - bypasses execution policy for this one script only.
rem Do not add -WindowStyle Hidden here: it hides the app window too, not just the console.
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0LargeFileFinder.ps1" -HideConsole %*
