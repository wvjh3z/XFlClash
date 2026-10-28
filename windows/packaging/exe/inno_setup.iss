; Both brands use this shared prerequisite gate before app files are replaced.
#define XbBundle "{{SOURCE_DIR}}"
; xboard-service-identity: injected before packaging
#define XbServiceName "UNCONFIGURED"
#define XbDataSlug "UNCONFIGURED"
#include "..\windows\packaging\exe\vc_runtime.iss"

[Files]
Source: "{#XbRoot}tool\windows\stop_brand_installation.ps1"; Flags: dontcopy
Source: "{#XbRoot}tool\windows\stop_brand_installation.ps1"; DestDir: "{app}\maintenance"; Flags: ignoreversion
Source: "{#XbRoot}tool\windows\remove_brand_user_data.ps1"; DestDir: "{app}\maintenance"; Flags: ignoreversion

[Setup]
MinVersion=10.0
AppId={{APP_ID}}
; xboard-installer-version:start
#error "Run inject_desktop_brand with the product version and actual build number before packaging"
; xboard-installer-version:end
AppName={{DISPLAY_NAME}}
AppPublisher={{PUBLISHER_NAME}}
; xboard-installer-links:start
; xboard-installer-links:end
DefaultDirName={{INSTALL_DIR_NAME}}
DisableProgramGroupPage=yes
UsePreviousTasks=no
OutputDir=.
OutputBaseFilename={{OUTPUT_BASE_FILENAME}}
Compression=lzma
SolidCompression=yes
SetupIconFile={{SETUP_ICON_FILE}}
WizardStyle=modern
PrivilegesRequired={{PRIVILEGES_REQUIRED}}
ArchitecturesAllowed={{ARCH}}
ArchitecturesInstallIn64BitMode={{ARCH}}

[CustomMessages]
chineseSimplified.XbBuildLabel=构建
english.XbBuildLabel=build
chineseSimplified.XbOwnedInstallError=无法安全关闭当前客户端，请先退出此客户端后重试。
english.XbOwnedInstallError=Cannot stop this installation safely. Close this client and retry.
chineseSimplified.XbDataBrand={{DISPLAY_NAME}}
english.XbDataBrand={{DISPLAY_NAME}}
chineseSimplified.XbRemoveData=是否删除 %1 的本地配置与缓存（含其中保存的登录信息）？其他品牌和原版 FlClash 的数据会保留。
english.XbRemoveData=Delete local settings, login information and cache for %1? Other brands and original FlClash data will be retained.
chineseSimplified.XbDataUserUnknown=无法确认当前桌面用户与卸载账户一致，已保留所有用户数据。
english.XbDataUserUnknown=The desktop user could not be matched to the uninstall account. All user data was retained.
chineseSimplified.XbDataIncomplete=部分数据未清理，可能存在占用、权限问题或不安全的目录链接。请检查以下品牌目录（不要删除其父目录）：
english.XbDataIncomplete=Some data was retained because of active files, permissions or unsafe directory links. Check these brand directories; do not delete their parent:

[Code]
function StopOwnedInstallation(): Boolean;
var
  ResultCode: Integer;
  PowerShellPath: String;
  ScriptPath: String;
begin
  if IsUninstaller then
    ScriptPath := ExpandConstant('{app}\maintenance\stop_brand_installation.ps1')
  else
  begin
    ExtractTemporaryFile('stop_brand_installation.ps1');
    ScriptPath := ExpandConstant('{tmp}\stop_brand_installation.ps1');
  end;
  if not FileExists(ScriptPath) then
  begin
    Result := False;
    exit;
  end;
  PowerShellPath := ExpandConstant('{sysnative}\WindowsPowerShell\v1.0\powershell.exe');
  if not FileExists(PowerShellPath) then
    PowerShellPath := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
  Result := Exec(PowerShellPath,
    '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' +
    ScriptPath + '" -InstallDirectory "' +
    ExpandConstant('{app}') + '" -ServiceName "{#XbServiceName}"',
    ExpandConstant('{tmp}'), SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Result := Result and (ResultCode = 0);
end;

function PointsIntoApp(Value: String): Boolean;
begin
  Result := Pos(Lowercase(AddBackslash(ExpandConstant('{app}'))), Lowercase(Value)) > 0;
end;

// The value name is appName and the schemes are protocolSchemes, both in
// lib/common.
procedure RemoveUserRegistrations;
var
  Schemes: TArrayOfString;
  Value: String;
  i: Integer;
begin
  if RegQueryStringValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run', '{{APP_NAME}}', Value) and PointsIntoApp(Value) then
  begin
    RegDeleteValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run', '{{APP_NAME}}');
    RegDeleteValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run', '{{APP_NAME}}');
  end;

  Schemes := ['XBOARD_SCHEME'];
  for i := 0 to GetArrayLength(Schemes)-1 do
  begin
    if RegQueryStringValue(HKCU, 'Software\Classes\' + Schemes[i] + '\shell\open\command', '', Value) and PointsIntoApp(Value) then
    begin
      RegDeleteKeyIncludingSubkeys(HKCU, 'Software\Classes\' + Schemes[i]);
    end;
  end;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := XbPrepareVCRuntime(NeedsRestart);
  if Result <> '' then exit;
  if not StopOwnedInstallation() then
    Result := CustomMessage('XbOwnedInstallError');
end;

function InitializeUninstall(): Boolean;
begin
  Result := StopOwnedInstallation();
end;

// Called only after the user confirms an interactive uninstall, while the
// installed maintenance script still exists. Never delete data during update.
procedure RemoveUserData;
var
  PowerShellPath, ScriptPath, RetainedPaths: String;
  ResultCode: Integer;
  Started: Boolean;
begin
  ScriptPath := ExpandConstant('{app}\maintenance\remove_brand_user_data.ps1');
  PowerShellPath := ExpandConstant('{sysnative}\WindowsPowerShell\v1.0\powershell.exe');
  if not FileExists(PowerShellPath) then
    PowerShellPath := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
  ResultCode := 20;
  Started := False;
  if FileExists(ScriptPath) then
    Started := Exec(PowerShellPath,
      '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' +
      ScriptPath + '" -Brand "{#XbDataSlug}"',
      ExpandConstant('{app}'), SW_HIDE, ewWaitUntilTerminated, ResultCode);
  if Started and (ResultCode = 0) then exit;
  Log('Brand user data retained; cleanup exit code=' + IntToStr(ResultCode));
  if Started and (ResultCode = 10) then
    MsgBox(CustomMessage('XbDataUserUnknown'), mbInformation, MB_OK)
  else
  begin
    RetainedPaths := ExpandConstant('{userappdata}\com.cloud.app\{#XbDataSlug}') + #13#10 +
      ExpandConstant('{localappdata}\com.cloud.app\{#XbDataSlug}');
    MsgBox(CustomMessage('XbDataIncomplete') + #13#10 + RetainedPaths, mbInformation, MB_OK);
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if (CurUninstallStep = usUninstall) and not UninstallSilent then
  begin
    if MsgBox(FmtMessage(CustomMessage('XbRemoveData'), [CustomMessage('XbDataBrand')]),
        mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES then
      RemoveUserData;
  end;
  if CurUninstallStep = usPostUninstall then
    RemoveUserRegistrations;
end;

[Languages]
{% for locale in LOCALES %}
{% if locale.lang == 'en' %}Name: "english"; MessagesFile: "compiler:Default.isl"{% endif %}
{% if locale.lang == 'hy' %}Name: "armenian"; MessagesFile: "compiler:Languages\\Armenian.isl"{% endif %}
{% if locale.lang == 'bg' %}Name: "bulgarian"; MessagesFile: "compiler:Languages\\Bulgarian.isl"{% endif %}
{% if locale.lang == 'ca' %}Name: "catalan"; MessagesFile: "compiler:Languages\\Catalan.isl"{% endif %}
{% if locale.lang == 'zh' %}
Name: "chineseSimplified"; MessagesFile: {% if locale.file %}{{ locale.file }}{% else %}"compiler:Languages\\ChineseSimplified.isl"{% endif %}
{% endif %}
{% if locale.lang == 'co' %}Name: "corsican"; MessagesFile: "compiler:Languages\\Corsican.isl"{% endif %}
{% if locale.lang == 'cs' %}Name: "czech"; MessagesFile: "compiler:Languages\\Czech.isl"{% endif %}
{% if locale.lang == 'da' %}Name: "danish"; MessagesFile: "compiler:Languages\\Danish.isl"{% endif %}
{% if locale.lang == 'nl' %}Name: "dutch"; MessagesFile: "compiler:Languages\\Dutch.isl"{% endif %}
{% if locale.lang == 'fi' %}Name: "finnish"; MessagesFile: "compiler:Languages\\Finnish.isl"{% endif %}
{% if locale.lang == 'fr' %}Name: "french"; MessagesFile: "compiler:Languages\\French.isl"{% endif %}
{% if locale.lang == 'de' %}Name: "german"; MessagesFile: "compiler:Languages\\German.isl"{% endif %}
{% if locale.lang == 'he' %}Name: "hebrew"; MessagesFile: "compiler:Languages\\Hebrew.isl"{% endif %}
{% if locale.lang == 'is' %}Name: "icelandic"; MessagesFile: "compiler:Languages\\Icelandic.isl"{% endif %}
{% if locale.lang == 'it' %}Name: "italian"; MessagesFile: "compiler:Languages\\Italian.isl"{% endif %}
{% if locale.lang == 'ja' %}Name: "japanese"; MessagesFile: "compiler:Languages\\Japanese.isl"{% endif %}
{% if locale.lang == 'no' %}Name: "norwegian"; MessagesFile: "compiler:Languages\\Norwegian.isl"{% endif %}
{% if locale.lang == 'pl' %}Name: "polish"; MessagesFile: "compiler:Languages\\Polish.isl"{% endif %}
{% if locale.lang == 'pt' %}Name: "portuguese"; MessagesFile: "compiler:Languages\\Portuguese.isl"{% endif %}
{% if locale.lang == 'ru' %}Name: "russian"; MessagesFile: "compiler:Languages\\Russian.isl"{% endif %}
{% if locale.lang == 'sk' %}Name: "slovak"; MessagesFile: "compiler:Languages\\Slovak.isl"{% endif %}
{% if locale.lang == 'sl' %}Name: "slovenian"; MessagesFile: "compiler:Languages\\Slovenian.isl"{% endif %}
{% if locale.lang == 'es' %}Name: "spanish"; MessagesFile: "compiler:Languages\\Spanish.isl"{% endif %}
{% if locale.lang == 'tr' %}Name: "turkish"; MessagesFile: "compiler:Languages\\Turkish.isl"{% endif %}
{% if locale.lang == 'uk' %}Name: "ukrainian"; MessagesFile: "compiler:Languages\\Ukrainian.isl"{% endif %}
{% endfor %}

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: {% if CREATE_DESKTOP_ICON != true %}unchecked{% else %}checkedonce{% endif %}
[Files]
Source: "{{SOURCE_DIR}}\\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; NOTE: Don't use "Flags: ignoreversion" on any shared system files

[Icons]
Name: "{autoprograms}\\{{DISPLAY_NAME}}"; Filename: "{app}\\{{EXECUTABLE_NAME}}"
Name: "{autodesktop}\\{{DISPLAY_NAME}}"; Filename: "{app}\\{{EXECUTABLE_NAME}}"; Tasks: desktopicon
[Run]
Filename: "{app}\\{{EXECUTABLE_NAME}}"; Description: "{cm:LaunchProgram,{{DISPLAY_NAME}}}"; Flags: {% if PRIVILEGES_REQUIRED == 'admin' %}runascurrentuser{% endif %} nowait postinstall skipifsilent
