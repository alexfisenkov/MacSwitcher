#ifndef AppVersion
#define AppVersion "0.1.0-alpha.1"
#endif
#define AppName "MacSwitcher"
#define AppPublisher "Alexander Fisenkov"
#define AppExe "MacSwitcher.Windows.exe"

[Setup]
AppId={{39557FE2-AB10-4BCF-AFC6-2F6A713E5EB5}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={localappdata}\Programs\MacSwitcher
DefaultGroupName=MacSwitcher
PrivilegesRequired=lowest
OutputDir=..\artifacts
OutputBaseFilename=MacSwitcher-Windows-{#AppVersion}-Setup
SetupIconFile=..\assets\MacSwitcher.ico
UninstallDisplayIcon={app}\{#AppExe}
ArchitecturesAllowed=x86 x64 arm64
ArchitecturesInstallIn64BitMode=x64 arm64
MinVersion=6.1sp1
DisableProgramGroupPage=yes
CloseApplications=no
AppMutex=Local\MacSwitcher.Windows.Mutex
Uninstallable=yes

[Files]
Source: "..\publish\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\MacSwitcher"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\MacSwitcher"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Создать значок на рабочем столе"; GroupDescription: "Дополнительные значки:"; Flags: unchecked

[Run]
Filename: "{app}\{#AppExe}"; Description: "Запустить MacSwitcher"; Flags: nowait postinstall skipifsilent

[Code]
function Net462Installed(): Boolean;
var
  Release: Cardinal;
begin
  Result := RegQueryDWordValue(HKLM, 'SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full', 'Release', Release) and (Release >= 394802);
end;

function InitializeSetup(): Boolean;
var
  ErrorCode: Integer;
begin
  Result := Net462Installed();
  if not Result then begin
    if MsgBox('.NET Framework 4.6.2 или новее не найден. Открыть официальный сайт Microsoft для загрузки?', mbError, MB_YESNO) = IDYES then
      ShellExec('open', 'https://dotnet.microsoft.com/download/dotnet-framework/net462', '', '', SW_SHOWNORMAL, ewNoWait, ErrorCode);
    MsgBox('Установите .NET Framework 4.6.2 или новее, затем запустите установщик снова.', mbInformation, MB_OK);
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
    RegDeleteValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run', 'MacSwitcher');
end;
