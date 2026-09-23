; Inno Setup 脚本：把 `flutter build windows --release` 的产物打成 .exe 安装器。
;
; 用法（先跑构建，再跑编译器）：
;   flutter build windows --release
;   iscc /DMyAppVersion=1.0.0 windows\installer\download_image.iss
;
; 产物：windows\installer\Output\download_image-<version>-windows-x64-setup.exe
;
; 说明：
; - AppId 是一个固定 GUID，升级安装时靠它识别「同一个应用」，不要改。
; - MyAppVersion 未通过 /D 传入时回退到 1.0.0。
; - 界面语言只用 Inno Setup 自带的 Default.isl（英文）。中文需要额外把
;   ChineseSimplified.isl 纳入仓库，它不在 Inno Setup 6 的默认安装里。

#ifndef MyAppVersion
  #define MyAppVersion "1.0.0"
#endif

#define MyAppName "download_image"
#define MyAppPublisher "com.lingren"
#define MyAppExeName "download_image.exe"

[Setup]
AppId={{1ED35C38-30FF-4286-BBDB-CF146B554F42}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
UninstallDisplayIcon={app}\{#MyAppExeName}
OutputDir=Output
OutputBaseFilename={#MyAppName}-{#MyAppVersion}-windows-x64-setup
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
WizardStyle=modern

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "..\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent
