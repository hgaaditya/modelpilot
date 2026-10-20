; Inno Setup 6 definition for the Model Pilot desktop app.
; Build from the repository root: ISCC.exe installer\ModelPilot.iss

#ifndef MyAppVersion
#define MyAppVersion "0.0.0"
#endif

[Setup]
AppId={{B42E2732-91D1-4BD9-9302-8D1D416915CE}
AppName=Model Pilot
AppVersion={#MyAppVersion}
AppPublisher=Model Pilot
DefaultDirName={localappdata}\LocalLLM
DefaultGroupName=Model Pilot
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=output
OutputBaseFilename=Model-Pilot-Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallFilesDir={app}\uninstall
Uninstallable=yes


[InstallDelete]
; Remove the old launcher; the upgrade migrates its owned shortcuts to the new branded entry point.
Type: files; Name: "{app}\LocalLLM.cmd"
; Removed product workflows from older releases. The installer owns these files, so an update
; deletes them rather than leaving unsupported launchers behind.
Type: files; Name: "{app}\claude-local.ps1"
Type: files; Name: "{app}\local-agent.ps1"
Type: files; Name: "{app}\local-llm.ps1"
Type: files; Name: "{app}\.agent-compat.json"


[Files]
Source: "..\ModelPilot.cmd"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\start.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\ui.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\tray.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\platform.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\llamaswap\config.example.yaml"; DestDir: "{app}\llamaswap"; Flags: ignoreversion
Source: "..\diagnose.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\bench\run.py"; DestDir: "{app}\bench"; Flags: ignoreversion
Source: "..\bench\tasks.jsonl"; DestDir: "{app}\bench"; Flags: ignoreversion
Source: "..\VERSION"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\supply-chain.json"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\THIRD-PARTY.md"; DestDir: "{app}"; Flags: ignoreversion

[Tasks]
Name: "desktopicon"; Description: "Create a Model Pilot &Desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked

[Icons]
Name: "{group}\Model Pilot"; Filename: "{app}\ModelPilot.cmd"; WorkingDir: "{app}"
Name: "{autodesktop}\Model Pilot"; Filename: "{app}\ModelPilot.cmd"; WorkingDir: "{app}"; Tasks: desktopicon

[Code]
function IsModelPilotLauncher(const FileName: String): Boolean;
var
  Shell, Shortcut: Variant;
  Target: String;
begin
  Result := False;
  if not FileExists(FileName) then Exit;
  try
    Shell := CreateOleObject('WScript.Shell');
    Shortcut := Shell.CreateShortcut(FileName);
    Target := ExpandFileName(Shortcut.TargetPath);
    Result := (CompareText(Target, ExpandConstant('{app}\ModelPilot.cmd')) = 0) or
      (CompareText(Target, ExpandConstant('{app}\LocalLLM.cmd')) = 0);
  except
    Result := False;
  end;
end;

procedure MigrateShortcut(const OldPath, NewPath: String);
var
  Shell, Shortcut: Variant;
begin
  if not IsModelPilotLauncher(OldPath) then Exit;
  if FileExists(NewPath) then begin
    if IsModelPilotLauncher(NewPath) then DeleteFile(OldPath);
  end else begin
    Shell := CreateOleObject('WScript.Shell');
    Shortcut := Shell.CreateShortcut(OldPath);
    Shortcut.TargetPath := ExpandConstant('{app}\ModelPilot.cmd');
    Shortcut.WorkingDirectory := ExpandConstant('{app}');
    Shortcut.Save();
    ForceDirectories(ExtractFileDir(NewPath));
    RenameFile(OldPath, NewPath);
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  OldProgramGroup: String;
begin
  if CurStep <> ssPostInstall then Exit;
  MigrateShortcut(ExpandConstant('{autodesktop}\LocalLLM.lnk'),
    ExpandConstant('{autodesktop}\Model Pilot.lnk'));
  MigrateShortcut(ExpandConstant('{userprograms}\LocalLLM.lnk'),
    ExpandConstant('{userprograms}\Model Pilot.lnk'));
  MigrateShortcut(ExpandConstant('{userprograms}\LocalLLM\LocalLLM.lnk'),
    ExpandConstant('{userprograms}\Model Pilot\Model Pilot.lnk'));
  OldProgramGroup := ExpandConstant('{userprograms}\LocalLLM');
  RemoveDir(OldProgramGroup);
end;



[Run]
Filename: "{app}\ModelPilot.cmd"; Parameters: "-RestartPanel"; Description: "Launch Model Pilot"; WorkingDir: "{app}"; Flags: postinstall shellexec skipifsilent

[UninstallDelete]
; Remove only installer-owned application files. Runtime, data and logs are deliberately retained.
Type: files; Name: "{app}\ModelPilot.cmd"
Type: files; Name: "{app}\LocalLLM.cmd"
Type: files; Name: "{app}\start.ps1"
Type: files; Name: "{app}\ui.ps1"
Type: files; Name: "{app}\tray.ps1"
Type: files; Name: "{app}\platform.ps1"
Type: files; Name: "{app}\diagnose.ps1"
Type: files; Name: "{app}\bench\run.py"
Type: files; Name: "{app}\bench\tasks.jsonl"
Type: files; Name: "{app}\llamaswap\config.example.yaml"
Type: files; Name: "{app}\VERSION"
Type: files; Name: "{app}\supply-chain.json"
Type: files; Name: "{app}\LICENSE"
Type: files; Name: "{app}\THIRD-PARTY.md"
Type: dirifempty; Name: "{app}\llamaswap"
Type: dirifempty; Name: "{app}\bench"
Type: dirifempty; Name: "{app}"
