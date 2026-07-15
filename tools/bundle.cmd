@echo off
setlocal

powershell -NoProfile -Command ^
  "$files = Get-ChildItem -Path '*.c','*.h','Makefile' -ErrorAction SilentlyContinue; if ($files) { Compress-Archive -Path $files.FullName -DestinationPath 'bundle.zip' -Force; Write-Host 'Created bundle.zip' } else { Write-Host 'No matching files found - nothing to zip' }"

powershell -NoProfile -Command ^
  "Get-ChildItem -Path 'bundle.zip','*.c','*.h','Makefile' -ErrorAction SilentlyContinue | Format-Table Name, LastWriteTime, Length -AutoSize"
endlocal