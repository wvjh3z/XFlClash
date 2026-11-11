; Included from the rendered dist/*.iss. No secrets, brand-specific IDs or DLL copies.
#define XbRoot AddBackslash(ExtractFileDir(RemoveBackslashUnlessRoot(SourcePath)))
#define XbRuntimeTools XbRoot + "tool\windows\"
#define XbRuntimePayload XbRoot + "build\windows-prerequisites\vc_redist.x64.exe"
#define XbPowerShell GetEnv("SystemRoot") + "\System32\WindowsPowerShell\v1.0\powershell.exe"
#if Exec(XbPowerShell, "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File """ + XbRuntimeTools + "prepare_vc_runtime.ps1"" -Root """ + XbRoot + "."" -Bundle """ + (AddBackslash(SourcePath) + XbBundle) + """", XbRoot, 1, 0) != 0
  #error "VC runtime preparation failed; do not publish an installer without verified prerequisites"
#endif

[Files]
; Place prerequisites before the solid-compressed app files. Temporary extraction
; only: shared runtime lifetime never belongs to this application's uninstaller.
Source: "{#XbRuntimePayload}"; DestName: "xb_vc_redist.x64.exe"; Flags: dontcopy nocompression
Source: "{#XbRuntimeTools}vc_runtime.ps1"; DestName: "xb_vc_runtime.ps1"; Flags: dontcopy
Source: "{#XbRoot}build\windows-prerequisites\vc_runtime.json"; DestName: "xb_vc_runtime.json"; Flags: dontcopy

[CustomMessages]
chineseSimplified.XbVcTitle=检查必要组件
chineseSimplified.XbVcDescription=安装前检查运行环境。
chineseSimplified.XbVcProgress=正在检查或安装 Microsoft Visual C++ 运行库，请稍候……
chineseSimplified.XbVcFailed=必要组件安装未完成（代码 %1）。客户端尚未安装或更新。%n%2%n%4%n诊断日志（如已生成）：%3 及同前缀的 .wrapper.txt / .stdout.txt / .stderr.txt / .diagnostic.txt 文件
chineseSimplified.XbVcRetry=请检查系统权限和磁盘空间，排除问题后重新运行安装程序。
chineseSimplified.XbVcReboot=运行库更新需要重启。请保存工作，手动重启电脑后重新运行此安装程序。
chineseSimplified.XbVcBusy=系统正在安装其他程序，请等待完成后重试。
chineseSimplified.XbVcTimeout=运行库安装超过等待时间，可能仍在后台继续。请等待系统安装完成后重试，不要同时重复安装。
chineseSimplified.XbVcDamaged=系统中较新的运行库文件不完整。请在“应用和功能”中修复 Microsoft Visual C++ x64 运行库后重试。
chineseSimplified.XbVcShell=必要组件检查器未能启动或正常执行。请查看安装日志中的系统错误及脚本日志；如系统报告权限限制，再检查相关策略。
chineseSimplified.XbVcLaunch=无法启动内置 VC++ 运行库安装程序。请查看 .wrapper.txt 中的启动阶段、工作目录和系统错误码，排查后重试。
chineseSimplified.XbVcCheck=运行库检查脚本发生异常。请查看 .wrapper.txt 中的检测阶段和错误详情；这不表示电脑没有运行库。
chineseSimplified.XbVcPrepare=无法提取或准备必要组件。请查看安装日志并检查临时目录权限和磁盘空间。
chineseSimplified.XbVcPlatform=必要组件检查要求 Windows 10 或更新的系统，并使用 64 位 PowerShell。
chineseSimplified.XbVcPayload=内置运行库文件校验失败。请重新下载完整安装包后重试。
chineseSimplified.XbVcVerify=运行库安装程序已返回，但重新检测仍不满足最低要求。请查看检测日志中的注册版本和 DLL 版本。
chineseSimplified.XbVcRedist=VC++ 运行库安装程序已启动，但返回失败。请根据原始退出码及运行库日志排查。
chineseSimplified.XbVcDetails=失败阶段：%1%n原始代码：%2%n错误摘要：%3
chineseSimplified.XbVcUnknown=未取得
chineseSimplified.XbVcNoError=未取得具体错误文本，请提供诊断信息及日志。
chineseSimplified.XbVcUnclassified=未能确认失败来自检查器还是运行库安装程序。请保留原始代码，并提供诊断信息及日志。
chineseSimplified.XbVcCopy=复制诊断信息
chineseSimplified.XbVcCopied=已复制诊断信息
chineseSimplified.XbVcCopyFailed=无法访问剪贴板，请直接提供诊断日志文件。
chineseSimplified.XbVcStagePrepare=准备/提取组件
chineseSimplified.XbVcStageShell=启动/执行 PowerShell 检查器
chineseSimplified.XbVcStageInit=初始化检查脚本
chineseSimplified.XbVcStagePolicy=读取运行库规则
chineseSimplified.XbVcStageCheck=检测现有运行库
chineseSimplified.XbVcStagePayload=校验内置运行库文件
chineseSimplified.XbVcStageLaunch=启动 VC++ 运行库安装程序
chineseSimplified.XbVcStageWait=等待 VC++ 运行库安装程序
chineseSimplified.XbVcStageVerify=安装后复核运行库
english.XbVcTitle=Checking prerequisites
english.XbVcDescription=Check the runtime requirements before installation.
english.XbVcProgress=Checking or installing Microsoft Visual C++ Runtime. Please wait...
english.XbVcFailed=Prerequisite installation did not complete (code %1). The app has not been installed or updated.%n%2%n%4%nDiagnostic logs (if generated): %3 and matching .wrapper.txt / .stdout.txt / .stderr.txt / .diagnostic.txt files
english.XbVcRetry=Check system permissions and free disk space, then run this installer again.
english.XbVcReboot=The runtime update requires a restart. Save your work, restart Windows manually, then run this installer again.
english.XbVcBusy=Another installation is in progress. Wait for it to finish and retry.
english.XbVcTimeout=The runtime installer exceeded the wait limit and may still be running. Wait for Windows installation to finish before retrying.
english.XbVcDamaged=A newer system runtime has missing or outdated files. Repair Microsoft Visual C++ x64 Runtime in Apps and Features, then retry.
english.XbVcShell=The prerequisite checker could not start or execute normally. Check the setup and script logs for the system error; check policies if access was denied.
english.XbVcLaunch=The embedded VC++ installer could not start. Check the launch stage, working directory and native error code in .wrapper.txt, then retry.
english.XbVcCheck=The runtime checker encountered an exception. Check the stage and error details in .wrapper.txt; this does not mean the runtime is missing.
english.XbVcPrepare=Prerequisites could not be extracted or prepared. Check the setup log, temporary directory permissions and free disk space.
english.XbVcPlatform=The prerequisite checker requires Windows 10 or later and 64-bit PowerShell.
english.XbVcPayload=The embedded runtime failed integrity verification. Download the complete setup again and retry.
english.XbVcVerify=The runtime installer returned, but verification still failed. Check the registered and DLL versions in the diagnostic log.
english.XbVcRedist=The VC++ runtime installer started but returned a failure. Check its original exit code and runtime log.
english.XbVcDetails=Stage: %1%nOriginal code: %2%nError summary: %3
english.XbVcUnknown=Unavailable
english.XbVcNoError=No specific error text was captured. Please provide the diagnostic details and logs.
english.XbVcUnclassified=The failure source could not be confirmed as the checker or runtime installer. Please provide the original code, diagnostics and logs.
english.XbVcCopy=Copy diagnostics
english.XbVcCopied=Diagnostics copied
english.XbVcCopyFailed=The clipboard is unavailable. Please provide the diagnostic log files instead.
english.XbVcStagePrepare=Prepare/extract prerequisites
english.XbVcStageShell=Start/execute PowerShell checker
english.XbVcStageInit=Initialize checker script
english.XbVcStagePolicy=Read runtime policy
english.XbVcStageCheck=Check existing runtime
english.XbVcStagePayload=Verify embedded runtime payload
english.XbVcStageLaunch=Start VC++ runtime installer
english.XbVcStageWait=Wait for VC++ runtime installer
english.XbVcStageVerify=Verify installed runtime

[Code]
var
  XbVcPage: TOutputProgressWizardPage;
  XbVcStopCode: Integer;
  XbVcLogPath: String;
  XbVcStage, XbVcKind, XbVcHost, XbVcErrorText: String;
  XbVcLaunchStatus, XbVcPowerShellPath, XbVcWorkingDir: String;
  XbVcRawCode, XbVcReportedCode, XbVcRedistCode: Integer;
  XbVcLocalFailureCode: Integer;
  XbVcHasRawCode, XbVcHasReport, XbVcHasRedist: Boolean;
  XbVcCaptureError, XbVcStdoutSaved, XbVcStderrSaved: Boolean;
  XbVcDiagnosticText: String;
  XbVcCopyButton: TNewButton;
  XbVcCopyMemo: TNewMemo;

function XbVcOneLine(Value: String; Limit: Integer): String;
begin
  StringChangeEx(Value, #13, ' ', True);
  StringChangeEx(Value, #10, ' ', True);
  StringChangeEx(Value, #9, ' ', True);
  Result := Trim(Value);
  if Length(Result) > Limit then Result := Copy(Result, 1, Limit) + '...';
end;

function XbVcPsQuote(Value: String): String;
begin
  StringChangeEx(Value, '''', '''''', True);
  Result := '''' + Value + '''';
end;

function XbVcCommand(ScriptPath, ConfigPath, PayloadPath, LogPath: String): String;
begin
  // Set UTF-8 before the script is parsed/invoked, so script-entry errors can
  // also be decoded by Inno 6.7.1's UTF-8 output reader. Do not change OS policy.
  Result := '$ErrorActionPreference = ''Stop''; ' +
    'try { [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false) } catch {}; ' +
    'try { & ' + XbVcPsQuote(ScriptPath) +
    ' -ConfigPath ' + XbVcPsQuote(ConfigPath) +
    ' -PayloadPath ' + XbVcPsQuote(PayloadPath) +
    ' -LogPath ' + XbVcPsQuote(LogPath) +
    ' } catch { Write-Error -ErrorRecord $_ -ErrorAction Continue; exit 1 }; exit $LASTEXITCODE';
end;

function XbVcSaveLines(Path: String; Lines: TArrayOfString): Boolean;
begin
  try
    Result := SaveStringsToUTF8File(Path, Lines, False);
  except
    Result := False;
  end;
end;

function XbVcIsStage(Value: String): Boolean;
begin
  Result := (Value = 'initialization') or (Value = 'policy-read') or
    (Value = 'readiness-before') or (Value = 'payload-validation') or
    (Value = 'redist-launch') or (Value = 'redist-wait') or (Value = 'readiness-after');
end;

function XbVcIsKind(Value: String): Boolean;
begin
  Result := (Value = 'ready') or (Value = 'platform') or (Value = 'checker') or
    (Value = 'payload') or (Value = 'newer-runtime') or (Value = 'redist-launch') or
    (Value = 'redist-timeout') or (Value = 'redist-exit') or (Value = 'reboot') or
    (Value = 'verification');
end;

function XbVcParseCode(Value: String; var Code: Integer): Boolean;
begin
  Code := StrToIntDef(Value, 0);
  Result := Value = IntToStr(Code);
end;

procedure XbVcReadProtocol(Line: String);
var
  Value: String;
  Code: Integer;
begin
  if Pos('XBVC_STAGE=', Line) = 1 then begin
    Value := Copy(Line, 12, Length(Line));
    if XbVcIsStage(Value) then XbVcStage := Value;
  end else if Pos('XBVC_KIND=', Line) = 1 then begin
    Value := Copy(Line, 11, Length(Line));
    if XbVcIsKind(Value) then XbVcKind := Value;
  end else if Pos('XBVC_RESULT=', Line) = 1 then begin
    if XbVcParseCode(Copy(Line, 13, Length(Line)), Code) then begin
      XbVcReportedCode := Code;
      XbVcHasReport := True;
    end;
  end else if Pos('XBVC_REDIST_EXIT=', Line) = 1 then begin
    if XbVcParseCode(Copy(Line, 18, Length(Line)), Code) then begin
      XbVcRedistCode := Code;
      XbVcHasRedist := True;
    end;
  end else if Pos('XBVC_ERROR=', Line) = 1 then
    XbVcErrorText := XbVcOneLine(Copy(Line, 12, Length(Line)), 1200)
  else if Pos('XBVC_HOST=', Line) = 1 then
    XbVcHost := XbVcOneLine(Copy(Line, 11, Length(Line)), 600);
end;

function XbVcStageText: String;
begin
  Result := CustomMessage('XbVcStageShell');
  if XbVcStage = 'preparation' then Result := CustomMessage('XbVcStagePrepare')
  else if XbVcStage = 'initialization' then Result := CustomMessage('XbVcStageInit')
  else if XbVcStage = 'policy-read' then Result := CustomMessage('XbVcStagePolicy')
  else if XbVcStage = 'readiness-before' then Result := CustomMessage('XbVcStageCheck')
  else if XbVcStage = 'payload-validation' then Result := CustomMessage('XbVcStagePayload')
  else if XbVcStage = 'redist-launch' then Result := CustomMessage('XbVcStageLaunch')
  else if XbVcStage = 'redist-wait' then Result := CustomMessage('XbVcStageWait')
  else if XbVcStage = 'readiness-after' then Result := CustomMessage('XbVcStageVerify');
end;

function XbVcRawCodeText: String;
begin
  Result := CustomMessage('XbVcUnknown');
  if XbVcHasRawCode then begin
    if XbVcLaunchStatus = 'not-started' then Result := 'Win32=' + IntToStr(XbVcRawCode)
    else Result := 'PowerShell=' + IntToStr(XbVcRawCode);
  end;
  if XbVcHasRedist then Result := Result + '; VC=' + IntToStr(XbVcRedistCode);
end;

function XbVcClipboardSequence: Cardinal;
  external 'GetClipboardSequenceNumber@user32.dll stdcall';

procedure XbVcCopyDiagnostics(Sender: TObject);
var
  BeforeCopy: Cardinal;
begin
  try
    if XbVcCopyMemo = nil then begin
      XbVcCopyMemo := TNewMemo.Create(WizardForm);
      XbVcCopyMemo.Parent := WizardForm;
      XbVcCopyMemo.Visible := False;
      XbVcCopyMemo.ReadOnly := True;
    end;
    XbVcCopyMemo.Text := XbVcDiagnosticText;
    XbVcCopyMemo.SelectAll;
    // Inno's PS_MINIVCL omits TCustomEdit.CopyToClipboard. WM_COPY uses
    // the same native edit control without relying on that optional binding.
    BeforeCopy := XbVcClipboardSequence;
    SendMessage(XbVcCopyMemo.Handle, $0301, 0, 0);
    if XbVcClipboardSequence = BeforeCopy then
      RaiseException(CustomMessage('XbVcCopyFailed'));
    XbVcCopyButton.Caption := CustomMessage('XbVcCopied');
  except
    MsgBox(CustomMessage('XbVcCopyFailed'), mbError, MB_OK);
  end;
end;

procedure XbVcShowCopyButton;
begin
  if WizardSilent then exit;
  if XbVcCopyButton = nil then begin
    XbVcCopyButton := TNewButton.Create(WizardForm);
    XbVcCopyButton.Parent := WizardForm;
    XbVcCopyButton.SetBounds(ScaleX(8), WizardForm.CancelButton.Top,
      ScaleX(176), WizardForm.CancelButton.Height);
    XbVcCopyButton.Anchors := [akLeft, akBottom];
    XbVcCopyButton.OnClick := @XbVcCopyDiagnostics;
  end;
  XbVcCopyButton.Caption := CustomMessage('XbVcCopy');
  XbVcCopyButton.Visible := True;
end;

procedure XbVcBuildDiagnostic(Code: Integer);
var
  Version, Reported, Redist: String;
  Lines: TArrayOfString;
begin
  Version := CustomMessage('XbVcUnknown');
  if not GetVersionNumbersString(ExpandConstant('{srcexe}'), Version) then
    Version := CustomMessage('XbVcUnknown');
  Reported := CustomMessage('XbVcUnknown');
  Redist := CustomMessage('XbVcUnknown');
  if XbVcHasReport then Reported := IntToStr(XbVcReportedCode);
  if XbVcHasRedist then Redist := IntToStr(XbVcRedistCode);
  XbVcDiagnosticText := 'Installer: ' + ExtractFileName(ExpandConstant('{srcexe}')) + #13#10 +
    'Version: ' + Version + #13#10 + 'Windows: ' + GetWindowsVersionString + #13#10 +
    'Stage: ' + XbVcStage + ' (' + XbVcStageText + ')' + #13#10 +
    'Prerequisite result: ' + IntToStr(Code) + #13#10 +
    'Launch status: ' + XbVcLaunchStatus + #13#10 + 'Original code: ' + XbVcRawCodeText + #13#10 +
    'Script result: ' + Reported + '; kind=' + XbVcKind + #13#10 +
    'VC installer exit: ' + Redist + #13#10 + 'PowerShell context: ' + XbVcHost + #13#10 +
    'Error: ' + XbVcOneLine(XbVcErrorText, 1200) + #13#10 +
    'PowerShell: ' + XbVcPowerShellPath + #13#10 + 'Working directory: ' + XbVcWorkingDir + #13#10 +
    'Capture incomplete: ' + IntToStr(Ord(XbVcCaptureError)) + #13#10 +
    'Output files written: stdout=' + IntToStr(Ord(XbVcStdoutSaved)) +
      '; stderr=' + IntToStr(Ord(XbVcStderrSaved)) + #13#10 +
    'Logs: ' + XbVcLogPath + #13#10 + XbVcLogPath + '.wrapper.txt' + #13#10 +
    XbVcLogPath + '.stdout.txt' + #13#10 + XbVcLogPath + '.stderr.txt' + #13#10 +
    XbVcLogPath + '.diagnostic.txt';
  SetArrayLength(Lines, 1);
  Lines[0] := XbVcDiagnosticText;
  if not XbVcSaveLines(XbVcLogPath + '.diagnostic.txt', Lines) then
    XbVcDiagnosticText := XbVcDiagnosticText + #13#10 + 'Diagnostic summary file could not be written.';
end;

function XbVcFailureHint(Code: Integer): String;
var
  Hint: String;
begin
  Result := CustomMessage('XbVcUnclassified');
  // Installer-local errors have a known origin independent of script output.
  if (XbVcLocalFailureCode <> 0) and (XbVcLocalFailureCode = Code) then begin
    if Code = 4005 then Result := CustomMessage('XbVcShell')
    else if Code = 4009 then Result := CustomMessage('XbVcPrepare');
    exit;
  end;
  // Never infer an origin from a numeric code alone: the child can return any
  // of the same values used by the checker. Markers only classify diagnostics.
  if not XbVcHasReport or (XbVcReportedCode <> Code) then exit;
  Hint := Result;
  if (XbVcKind = 'redist-exit') and XbVcHasRedist and (XbVcRedistCode = Code) then begin
    Hint := CustomMessage('XbVcRedist');
    if (Code = 1618) or (Code = -2147023278) then Hint := CustomMessage('XbVcBusy');
  end else if (XbVcKind = 'reboot') and (Code = 3010) and XbVcHasRedist and
    ((XbVcRedistCode = 3010) or (XbVcRedistCode = 1641)) then Hint := CustomMessage('XbVcReboot')
  else if (XbVcKind = 'redist-timeout') and (Code = 4004) then Hint := CustomMessage('XbVcTimeout')
  else if (XbVcKind = 'newer-runtime') and (Code = 4006) then Hint := CustomMessage('XbVcDamaged')
  else if (XbVcKind = 'redist-launch') and (Code = 4007) then Hint := CustomMessage('XbVcLaunch')
  else if (XbVcKind = 'checker') and (Code = 4008) then Hint := CustomMessage('XbVcCheck')
  else if (XbVcKind = 'platform') and (Code = 4001) then Hint := CustomMessage('XbVcPlatform')
  else if (XbVcKind = 'payload') and (Code = 4002) then Hint := CustomMessage('XbVcPayload')
  else if (XbVcKind = 'verification') and (Code = 4003) then Hint := CustomMessage('XbVcVerify');
  Result := Hint;
end;

function XbVcError(Code: Integer; LogPath: String): String;
var
  Hint, Detail, ErrorText: String;
begin
  Hint := XbVcFailureHint(Code);
  ErrorText := XbVcOneLine(XbVcErrorText, 240);
  if ErrorText = '' then ErrorText := CustomMessage('XbVcNoError');
  Detail := FmtMessage(CustomMessage('XbVcDetails'), [XbVcStageText, XbVcRawCodeText, ErrorText]);
  try
    XbVcBuildDiagnostic(Code);
  except
    XbVcDiagnosticText := 'Prerequisite result: ' + IntToStr(Code) + #13#10 + Detail + #13#10 +
      'Diagnostic summary unavailable; log prefix: ' + LogPath;
  end;
  try
    XbVcShowCopyButton;
  except
    // A diagnostic UI failure must not replace the prerequisite result.
  end;
  Result := FmtMessage(CustomMessage('XbVcFailed'), [IntToStr(Code), Hint, LogPath, Detail]);
end;

function XbPrepareVCRuntime(var NeedsRestart: Boolean): String;
var
  Code: Integer;
  LogPath, Params, PowerShellPath: String;
  Started: Boolean;
  Output: TExecOutput;
  I: Integer;
begin
  Result := '';
  if XbVcLogPath = '' then
    XbVcLogPath := ExpandConstant('{%TEMP}\XFlclash-vc-runtime-') +
      GetDateTimeString('yyyymmdd-hhnnss', '-', ':') + '-' +
      ExtractFileName(RemoveBackslashUnlessRoot(ExpandConstant('{tmp}'))) + '.log';
  LogPath := XbVcLogPath;
  if XbVcStopCode <> 0 then begin
    Result := XbVcError(XbVcStopCode, LogPath);
    exit;
  end;
  if XbVcPage = nil then
    XbVcPage := CreateOutputProgressPage(CustomMessage('XbVcTitle'), CustomMessage('XbVcDescription'));
  XbVcPage.SetText(CustomMessage('XbVcProgress'), '');
  XbVcPage.Show;
  try
    try
      XbVcStage := 'preparation';
      XbVcLaunchStatus := 'not-attempted';
      XbVcLocalFailureCode := 0;
      XbVcKind := '';
      XbVcHost := '';
      XbVcErrorText := '';
      XbVcHasRawCode := False;
      XbVcHasReport := False;
      XbVcHasRedist := False;
      XbVcCaptureError := False;
      XbVcStdoutSaved := False;
      XbVcStderrSaved := False;
      ExtractTemporaryFile('xb_vc_redist.x64.exe');
      ExtractTemporaryFile('xb_vc_runtime.ps1');
      ExtractTemporaryFile('xb_vc_runtime.json');
      Params := '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "' +
        XbVcCommand(ExpandConstant('{tmp}\xb_vc_runtime.ps1'),
          ExpandConstant('{tmp}\xb_vc_runtime.json'),
          ExpandConstant('{tmp}\xb_vc_redist.x64.exe'), LogPath) + '"';
      // Inno 6.7.1: Sysnative selects x64 from the 32-bit installer.
      // Keep it only as the executable path, NEVER the working directory.
      PowerShellPath := ExpandConstant('{sysnative}\WindowsPowerShell\v1.0\powershell.exe');
      if not FileExists(PowerShellPath) then
        PowerShellPath := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
      XbVcPowerShellPath := PowerShellPath;
      XbVcWorkingDir := ExpandConstant('{tmp}');
      XbVcStage := 'checker-execution';
      XbVcLaunchStatus := 'unknown';
      SetArrayLength(Output.StdOut, 0);
      SetArrayLength(Output.StdErr, 0);
      Output.Error := False;
      try
        Started := ExecAndCaptureOutput(PowerShellPath,
          Params, ExpandConstant('{tmp}'), SW_HIDE, ewWaitUntilTerminated, Code, Output);
        XbVcRawCode := Code;
        XbVcHasRawCode := True;
        if Started then XbVcLaunchStatus := 'started'
        else begin
          XbVcLaunchStatus := 'not-started';
          XbVcStage := 'checker-launch';
          XbVcErrorText := SysErrorMessage(Code);
          Log('Cannot start prerequisite checker: ' + XbVcErrorText);
          Code := 4005;
          XbVcLocalFailureCode := Code;
        end;
      except
        // Execution state can be uncertain after a capture API exception. Never
        // retry with plain Exec: that could start another runtime installer.
        XbVcErrorText := GetExceptionMessage;
        Output.Error := True;
        Code := 4005;
        XbVcLocalFailureCode := Code;
      end;
      XbVcCaptureError := Output.Error;
      XbVcStdoutSaved := XbVcSaveLines(LogPath + '.stdout.txt', Output.StdOut);
      XbVcStderrSaved := XbVcSaveLines(LogPath + '.stderr.txt', Output.StdErr);
      try
        for I := 0 to GetArrayLength(Output.StdOut) - 1 do XbVcReadProtocol(Output.StdOut[I]);
        for I := 0 to GetArrayLength(Output.StdErr) - 1 do
          if (XbVcErrorText = '') and (Trim(Output.StdErr[I]) <> '') then
            XbVcErrorText := XbVcOneLine(Output.StdErr[I], 1200);
      except
        // Diagnostics cannot replace a completed checker result.
        XbVcCaptureError := True;
        XbVcHasReport := False;
        XbVcHasRedist := False;
      end;
      Log('VC runtime prerequisite result: ' + IntToStr(Code) + '; log: ' + LogPath);
      if Code <> 0 then begin
        // Stop before copying app files. Do not request automatic OS reboot,
        // including for silent installations. A fresh setup run must check again.
        XbVcStopCode := Code;
        Result := XbVcError(Code, LogPath);
      end;
    except
      XbVcErrorText := GetExceptionMessage;
      Log(XbVcErrorText);
      XbVcStopCode := 4009;
      XbVcLocalFailureCode := XbVcStopCode;
      Result := XbVcError(4009, LogPath);
    end;
  finally
    XbVcPage.Hide;
  end;
end;
