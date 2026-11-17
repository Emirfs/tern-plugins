@echo off
rem tern-bridge shim: runs tern_bridge.py beside it (install.cmd puts both in %USERPROFILE%\.local\bin).
where python >nul 2>nul || goto py
python "%~dp0tern_bridge.py" %*
exit /b %errorlevel%
:py
py -3 "%~dp0tern_bridge.py" %*
