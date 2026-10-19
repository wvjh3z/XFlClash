@echo off
setlocal DisableDelayedExpansion
set "DART=dart.exe"
if defined FLUTTER_ROOT set "DART=%FLUTTER_ROOT%\bin\cache\dart-sdk\bin\dart.exe"
"%DART%" "%~dp0bootstrap.dart" %*
exit /b %ERRORLEVEL%
