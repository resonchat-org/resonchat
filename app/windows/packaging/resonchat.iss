; Copyright (C) 2026 resonchat contributors.
; SPDX-License-Identifier: GPL-3.0-or-later
;
; Inno Setup script for the Windows installer (setup.exe).
; {#SourcePath} = this file's directory (app/windows/packaging/).
; Do not rely on SourceDir for OutputDir / SetupIconFile — Inno resolves those
; relative to SourceDir once it is set.
;
; Build (from app/):
;   flutter build windows --release
;   ISCC.exe windows\packaging\resonchat.iss /DMyAppVersion=0.0.2
;
; Or via tool/build_windows.ps1

#ifndef MyAppVersion
  #define MyAppVersion "0.0.0"
#endif

#define MyAppName "resonchat"
#define MyAppPublisher "resonchat contributors"
#define MyAppURL "https://github.com/resonchat-org/resonchat"
#define MyAppExeName "resonchat.exe"
; Absolute roots from the script location (packaging/ → app/).
#define AppRoot SourcePath + "\..\.."
#define ReleaseDir AppRoot + "\build\windows\x64\runner\Release"
#define InstallerDir AppRoot + "\build\windows\installer"
#define AppIcon AppRoot + "\assets\icons\app_icon.ico"

[Setup]
; Stable uninstall id (same GUID family as Windows toast activator).
AppId={{8F3A2C1E-6B4D-4A9F-B7E2-1C5D8A0F3E6B}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}/issues
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
AllowNoIcons=yes
SourceDir={#ReleaseDir}
OutputDir={#InstallerDir}
OutputBaseFilename=resonchat-{#MyAppVersion}-x86_64-setup
SetupIconFile={#AppIcon}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\{#MyAppExeName}
CloseApplications=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent
