; SPDX-License-Identifier: GPL-3.0-or-later
; Windows installer for kickFile (Inno Setup 6). Built by .github/workflows/release.yml:
;   iscc /DAppVersion=1.0.1 /DSourceDir=<folder with kickfile.exe> /DOutputDir=<dir> kickfile.iss
; Installs per user by default (no admin prompt); "Install for all users" is offered in the wizard.

#ifndef AppVersion
  #error AppVersion is required
#endif

[Setup]
AppId={{6F3C2B0E-3D7A-4C1E-9B8F-2A6D5E4C1F70}
AppName=kickFile
AppVersion={#AppVersion}
AppVerName=kickFile {#AppVersion}
AppPublisher=Pratik Ukey
AppPublisherURL=https://ukpratik.github.io/kickfile/
AppSupportURL=https://github.com/ukpratik/kickfile/issues
AppUpdatesURL=https://github.com/ukpratik/kickfile/releases
DefaultDirName={autopf}\kickFile
DefaultGroupName=kickFile
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir={#OutputDir}
OutputBaseFilename=kickFile-windows-x64-setup
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\kickfile.exe
UninstallDisplayName=kickFile
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\kickFile"; Filename: "{app}\kickfile.exe"
Name: "{autodesktop}\kickFile"; Filename: "{app}\kickfile.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\kickfile.exe"; Description: "{cm:LaunchProgram,kickFile}"; Flags: nowait postinstall skipifsilent
