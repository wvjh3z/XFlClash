"""Run production Inno diagnostic functions in a harmless Windows-only harness.

No app or VC installation; strips only packaging directives, retains all Code.
This supplements, rather than replaces, the complete maker/ISCC preflight.
"""
from pathlib import Path
import argparse
import json
import subprocess

ROOT = Path(__file__).resolve().parents[2]
HARNESS = r'''
procedure AssertDiagnostic(Condition: Boolean; Name: String);
begin
  if not Condition then RaiseException('FAIL ' + Name);
  Log('PASS ' + Name);
end;

procedure TestChecker(ScriptPath: String; Expected: Integer; Name: String);
var
  Output: TExecOutput;
  Code: Integer;
  Started: Boolean;
  Params, Joined: String;
  I: Integer;
begin
  Params := '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "' +
    XbVcCommand(ScriptPath, 'unused', 'unused', 'unused') + '"';
  Started := ExecAndCaptureOutput(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
    Params, ExpandConstant('{src}'), SW_HIDE, ewWaitUntilTerminated, Code, Output);
  AssertDiagnostic(Started and (Code = Expected), Name + ' raw exit');
  if Name = 'valid' then begin
    Joined := '';
    for I := 0 to GetArrayLength(Output.StdOut) - 1 do begin
      Joined := Joined + Output.StdOut[I];
      XbVcReadProtocol(Output.StdOut[I]);
    end;
    AssertDiagnostic(Pos('中文', Joined) > 0, 'UTF8 capture');
    AssertDiagnostic(XbVcHasReport and (XbVcReportedCode = 1) and
      XbVcHasRedist and (XbVcRedistCode = 1) and (XbVcKind = 'redist-exit'), 'protocol');
  end else
    AssertDiagnostic(GetArrayLength(Output.StdErr) > 0, Name + ' stderr');
end;

procedure TestClassification;
var
  MessageText: String;
  NeedsRestart: Boolean;
begin
  XbVcHasReport := False;
  XbVcHasRedist := False;
  MessageText := XbVcError(1, XbVcLogPath);
  AssertDiagnostic(Pos(CustomMessage('XbVcShell'), MessageText) = 0, 'missing protocol exit1 neutral');
  MessageText := XbVcError(4004, XbVcLogPath);
  AssertDiagnostic(Pos(CustomMessage('XbVcTimeout'), MessageText) = 0, 'missing protocol collision neutral');
  XbVcHasReport := True;
  XbVcReportedCode := 4004;
  XbVcKind := 'redist-exit';
  XbVcHasRedist := True;
  XbVcRedistCode := 4004;
  MessageText := XbVcError(1, XbVcLogPath);
  AssertDiagnostic(Pos(CustomMessage('XbVcShell'), MessageText) = 0, 'mismatched protocol neutral');
  MessageText := XbVcError(4004, XbVcLogPath);
  AssertDiagnostic(Pos(CustomMessage('XbVcRedist'), MessageText) > 0, 'redist collision classified');
  XbVcKind := 'redist-timeout';
  XbVcHasRedist := False;
  MessageText := XbVcError(4004, XbVcLogPath);
  AssertDiagnostic(Pos(CustomMessage('XbVcTimeout'), MessageText) > 0, 'matching timeout classified');
  XbVcReportedCode := 1;
  XbVcKind := 'redist-exit';
  XbVcHasRedist := True;
  XbVcRedistCode := 1;
  MessageText := XbVcError(1, XbVcLogPath);
  AssertDiagnostic(Pos(CustomMessage('XbVcRedist'), MessageText) > 0, 'matching redist exit1 classified');
  XbVcLocalFailureCode := 4005;
  MessageText := XbVcError(4005, XbVcLogPath);
  AssertDiagnostic(Pos(CustomMessage('XbVcShell'), MessageText) > 0, 'local launch error classified');
  XbVcLocalFailureCode := 4009;
  MessageText := XbVcError(4009, XbVcLogPath);
  AssertDiagnostic(Pos(CustomMessage('XbVcPrepare'), MessageText) > 0, 'local preparation error classified');
  XbVcLocalFailureCode := 0;
  XbVcStopCode := 1;
  NeedsRestart := False;
  MessageText := XbPrepareVCRuntime(NeedsRestart);
  AssertDiagnostic((MessageText <> '') and (XbVcStopCode = 1) and not NeedsRestart,
    'cached failure still blocks without reboot');
  AssertDiagnostic(XbVcPage = nil, 'cached failure does not execute checker');
  XbVcStopCode := 0;
end;

procedure InitializeWizard;
var
  Lines: TArrayOfString;
  Summary, ScriptDir: String;
begin
  Summary := ExpandConstant('{src}\native-result.txt');
  try
    ScriptDir := ExpandConstant('{src}\中文 space '' path');
    TestChecker(ScriptDir + '\valid.ps1', 1, 'valid');
    TestChecker(ScriptDir + '\invalid.ps1', 1, 'parse-error');
    TestChecker(ScriptDir + '\missing.ps1', 1, 'missing-entry');
    SetArrayLength(Lines, 1);
    Lines[0] := 'test';
    AssertDiagnostic(not XbVcSaveLines(ExpandConstant('{src}'), Lines), 'unwritable log');
    XbVcLogPath := ExpandConstant('{src}\diagnostic.log');
    XbVcStage := 'redist-wait';
    XbVcRawCode := 1;
    XbVcHasRawCode := True;
    XbVcLaunchStatus := 'started';
    TestClassification;
    XbVcBuildDiagnostic(1);
    XbVcShowCopyButton;
    XbVcCopyDiagnostics(nil);
    if ExpandConstant('{param:locktest|0}') = '1' then
      AssertDiagnostic(XbVcCopyButton.Caption = CustomMessage('XbVcCopy'), 'clipboard lock reports failure')
    else
      AssertDiagnostic(XbVcCopyButton.Caption = CustomMessage('XbVcCopied'), 'clipboard copy');
    Lines[0] := 'PASS: raw exits; UTF8; protocol; classification; parse error; missing entry; unwritable log; clipboard';
    SaveStringsToUTF8File(Summary, Lines, False);
  except
    SetArrayLength(Lines, 1);
    Lines[0] := 'FAIL: ' + GetExceptionMessage;
    SaveStringsToUTF8File(Summary, Lines, False);
  end;
end;
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--iscc', default=r'C:\Program Files (x86)\Inno Setup 6\ISCC.exe')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    source = (ROOT / 'windows/packaging/exe/vc_runtime.iss').read_text(encoding='utf-8-sig')
    source = source[source.index('[CustomMessages]'):]
    # Both sets of production messages and complete production Pascal code.
    language = ROOT / 'windows/packaging/exe/ChineseSimplified.isl'
    header = '\n'.join([
        '[Setup]', 'AppName=VC diagnostic harness', 'AppVersion=1',
        'DefaultDirName={tmp}\\xb-vc-harness', 'PrivilegesRequired=lowest',
        'Uninstallable=no', 'CreateAppDir=no', 'OutputDir=.',
        'OutputBaseFilename=diagnostic-harness', '[Languages]',
        'Name: english; MessagesFile: compiler:Default.isl',
        'Name: chineseSimplified; MessagesFile: "' + str(language) + '"', '',
    ])
    script = args.output / 'harness.iss'
    script.write_text(header + source + HARNESS, encoding='utf-8-sig')
    fixtures = args.output / "中文 space ' path"
    fixtures.mkdir()
    (fixtures / 'valid.ps1').write_text(
        "[Console]::Out.WriteLine('中文'); "
        "[Console]::Out.WriteLine('XBVC_KIND=redist-exit'); "
        "[Console]::Out.WriteLine('XBVC_REDIST_EXIT=1'); "
        "[Console]::Out.WriteLine('XBVC_RESULT=1'); exit 1", encoding='utf-8-sig')
    (fixtures / 'invalid.ps1').write_text('function {', encoding='utf-8-sig')
    result = subprocess.run([args.iscc, str(script)], capture_output=True)
    (args.output / 'compile.stdout').write_bytes(result.stdout)
    (args.output / 'compile.stderr').write_bytes(result.stderr)
    report = {'compile_exit': result.returncode, 'cases': [],
              'client_build': False, 'vc_installation': False}
    if result.returncode == 0:
        driver = ROOT / 'tool/test/windows_vc_diagnostics_driver.ps1'
        for language in ('english', 'chineseSimplified'):
            for mode in ('normal', 'locked'):
                try:
                    run = subprocess.run(['powershell', '-NoLogo', '-NoProfile', '-STA',
                        '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', str(driver),
                        '-Directory', str(args.output.resolve()), '-Language', language,
                        '-Mode', mode], capture_output=True, timeout=90)
                except subprocess.TimeoutExpired as error:
                    # The runner's kill-on-close job owns the harness descendants.
                    # A forced timeout cannot claim clipboard restoration succeeded.
                    report['driver_timeout'] = True
                    run = subprocess.CompletedProcess([], 124, error.stdout or b'', error.stderr or b'')
                prefix = args.output / (language + '-' + mode)
                prefix.with_suffix('.stdout').write_bytes(run.stdout)
                prefix.with_suffix('.stderr').write_bytes(run.stderr)
                report['cases'].append({'language': language, 'mode': mode, 'exit': run.returncode})
                if report.get('driver_timeout'):
                    break
            if report.get('driver_timeout'):
                break
    report['passed'] = (result.returncode == 0 and len(report['cases']) == 4
                        and all(case['exit'] == 0 for case in report['cases']))
    (args.output / 'report.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(report))
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
