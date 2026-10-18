; Included from the rendered dist/*.iss. No secrets, brand-specific IDs or DLL copies.
#define XbRoot AddBackslash(ExpandFileName(AddBackslash(SourcePath) + ".."))
#define XbRuntimeTools XbRoot + "tool\windows\"
#define XbRuntimePayload XbRoot + "build\windows-prerequisites\vc_redist.x64.exe"
#define XbPowerShell GetEnv("SystemRoot") + "\System32\WindowsPowerShell\v1.0\powershell.exe"
#if Exec(XbPowerShell, "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File """ + XbRuntimeTools + "prepare_vc_runtime.ps1"" -Root """ + XbRoot + "."" -Bundle """ + ExpandFileName(AddBackslash(SourcePath) + XbBundle) + """", XbRoot, 1, 0) != 0
  #error "VC runtime preparation failed; do not publish an installer without verified prerequisites"
#endif

[Files]
; Place prerequisites before the solid-compressed app files. Temporary extraction
; only: shared runtime lifetime never belongs to this application's uninstaller.
Source: "{#XbRuntimePayload}"; DestName: "xb_vc_redist.x64.exe"; Flags: dontcopy nocompression
Source: "{#XbRuntimeTools}vc_runtime.ps1"; DestName: "xb_vc_runtime.ps1"; Flags: dontcopy
Source: "{#XbRuntimeTools}vc_runtime.json"; DestName: "xb_vc_runtime.json"; Flags: dontcopy

[CustomMessages]
chineseSimplified.XbVcTitle=检查必要组件
chineseSimplified.XbVcProgress=正在检查或安装 Microsoft Visual C++ 运行库，请稍候……
chineseSimplified.XbVcFailed=必要组件安装未完成（代码 %1）。客户端尚未安装或更新。%n%2%n诊断日志（如已生成）：%3 及其 .wrapper.txt 文件
chineseSimplified.XbVcRetry=请检查系统权限和磁盘空间，排除问题后重新运行安装程序。
chineseSimplified.XbVcReboot=运行库更新需要重启。请保存工作，手动重启电脑后重新运行此安装程序。
chineseSimplified.XbVcBusy=系统正在安装其他程序，请等待完成后重试。
chineseSimplified.XbVcTimeout=运行库安装超过等待时间，可能仍在后台继续。请等待系统安装完成后重试，不要同时重复安装。
chineseSimplified.XbVcDamaged=系统中较新的运行库文件不完整。请在“应用和功能”中修复 Microsoft Visual C++ x64 运行库后重试。
chineseSimplified.XbVcShell=无法运行系统 PowerShell 或必要组件脚本，请检查系统限制与安全软件的拦截记录。
english.XbVcTitle=Checking prerequisites
english.XbVcProgress=Checking or installing Microsoft Visual C++ Runtime. Please wait...
english.XbVcFailed=Prerequisite installation did not complete (code %1). The app has not been installed or updated.%n%2%nDiagnostic logs (if generated): %3 and its .wrapper.txt file
english.XbVcRetry=Check system permissions and free disk space, then run this installer again.
english.XbVcReboot=The runtime update requires a restart. Save your work, restart Windows manually, then run this installer again.
english.XbVcBusy=Another installation is in progress. Wait for it to finish and retry.
english.XbVcTimeout=The runtime installer exceeded the wait limit and may still be running. Wait for Windows installation to finish before retrying.
english.XbVcDamaged=A newer system runtime has missing or outdated files. Repair Microsoft Visual C++ x64 Runtime in Apps and Features, then retry.
english.XbVcShell=System PowerShell or the prerequisite script could not run. Check system policies and security software logs.

[Code]
var
  XbVcPage: TOutputProgressWizardPage;
  XbVcStopCode: Integer;
  XbVcLogPath: String;

function XbVcError(Code: Integer; LogPath: String): String;
var
  Hint: String;
begin
  Hint := CustomMessage('XbVcRetry');
  case Code of
    3010: Hint := CustomMessage('XbVcReboot');
    1618, -2147023278: Hint := CustomMessage('XbVcBusy');
    4004: Hint := CustomMessage('XbVcTimeout');
    4006: Hint := CustomMessage('XbVcDamaged');
    4005, 1: Hint := CustomMessage('XbVcShell');
  end;
  Result := FmtMessage(CustomMessage('XbVcFailed'), [IntToStr(Code), Hint, LogPath]);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Code: Integer;
  LogPath, Params, PowerShellPath: String;
begin
  Result := '';
  if XbVcLogPath = '' then
    XbVcLogPath := ExpandConstant('{%TEMP}\XFlclash-vc-runtime-') + GetDateTimeString('yyyymmdd-hhnnss', '-', ':') + '.log';
  LogPath := XbVcLogPath;
  if XbVcStopCode <> 0 then begin
    Result := XbVcError(XbVcStopCode, LogPath);
    exit;
  end;
  if XbVcPage = nil then
    XbVcPage := CreateOutputProgressPage(CustomMessage('XbVcTitle'), CustomMessage('XbVcProgress'));
  XbVcPage.SetText(CustomMessage('XbVcProgress'), '');
  XbVcPage.Show;
  try
    try
      ExtractTemporaryFile('xb_vc_redist.x64.exe');
      ExtractTemporaryFile('xb_vc_runtime.ps1');
      ExtractTemporaryFile('xb_vc_runtime.json');
      Params := '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' +
        ExpandConstant('{tmp}\xb_vc_runtime.ps1') + '" -ConfigPath "' +
        ExpandConstant('{tmp}\xb_vc_runtime.json') + '" -PayloadPath "' +
        ExpandConstant('{tmp}\xb_vc_redist.x64.exe') + '" -LogPath "' + LogPath + '"';
      // Sysnative selects x64 from a 32-bit Inno process. A native 64-bit
      // installer has no Sysnative alias and uses System32 directly.
      PowerShellPath := ExpandConstant('{sysnative}\WindowsPowerShell\v1.0\powershell.exe');
      if not FileExists(PowerShellPath) then
        PowerShellPath := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
      if not Exec(PowerShellPath,
        Params, '', SW_HIDE, ewWaitUntilTerminated, Code) then begin
        Log('Cannot start prerequisite checker: ' + SysErrorMessage(Code));
        Code := 4005;
      end;
      Log('VC runtime prerequisite result: ' + IntToStr(Code) + '; log: ' + LogPath);
      if Code <> 0 then begin
        // Stop before copying app files. Do not request automatic OS reboot,
        // including for silent installations. A fresh setup run must check again.
        XbVcStopCode := Code;
        Result := XbVcError(Code, LogPath);
      end;
    except
      Log(GetExceptionMessage);
      Result := XbVcError(4005, LogPath);
    end;
  finally
    XbVcPage.Hide;
  end;
end;
