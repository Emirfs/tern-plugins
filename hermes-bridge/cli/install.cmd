@echo off
rem Installs the tern-bridge command: copies tern_bridge.py and the tern-bridge.cmd shim into
rem %USERPROFILE%\.local\bin (on the user PATH). Run again after updating the plugin.
setlocal
set "BIN=%USERPROFILE%\.local\bin"
if not exist "%BIN%" mkdir "%BIN%"
copy /y "%~dp0tern_bridge.py" "%BIN%\tern_bridge.py" >nul || exit /b 1
copy /y "%~dp0tern-bridge.cmd" "%BIN%\tern-bridge.cmd" >nul || exit /b 1
echo installed %BIN%\tern-bridge.cmd
echo ;%PATH%; | find /i ";%BIN%;" >nul || echo note: %BIN% is not on PATH in this shell; add it to the user PATH
