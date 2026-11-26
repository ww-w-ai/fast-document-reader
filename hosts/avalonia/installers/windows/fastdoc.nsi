; fastdoc.nsi — the per-user Windows setup for FastDoc. Built by Scripts/package-host.sh with
; makensis (it runs on macOS and Linux as well as Windows); not meant to be built by hand.
;
;   makensis -DVERSION=1.4.5 -DARCH=x64|arm64 -DSTAGE_NSH=<dir> -DOUTFILE=<setup.exe> fastdoc.nsi
;
; STAGE_NSH holds three generated includes: install-files.nsh (SetOutPath/File per published
; file), uninstall-files.nsh (Delete per file, then RMDir per folder, deepest first) and
; extensions.nsh (one !insertmacro per extension, from DefaultAppFamilies.WindowsOpenWithExtensions).
;
; What it writes — and the uninstaller removes exactly that:
;   - %LOCALAPPDATA%\Programs\FastDoc\ (the published app) plus "Uninstall FastDoc.exe"
;   - a Start-menu shortcut, and a desktop shortcut when that component is ticked
;   - the HKCU keys installers/windows/register.ps1 writes: ProgId FastDoc.Document,
;     .<ext>\OpenWithProgids for every extension, Software\FastDoc\Capabilities and the
;     RegisteredApplications entry — FastDoc becomes an "Open with" candidate, never the default
;   - HKCU\...\Uninstall\FastDoc (Settings > Apps > Installed apps)
; No administrator rights are requested; nothing is written outside the current user's profile.
; Settings and recent files the app itself keeps under %APPDATA% are the user's and stay.

!ifndef VERSION
  !error "VERSION is not defined (see Scripts/package-host.sh)"
!endif
!ifndef ARCH
  !error "ARCH is not defined (see Scripts/package-host.sh)"
!endif
!ifndef STAGE_NSH
  !error "STAGE_NSH is not defined (see Scripts/package-host.sh)"
!endif
!ifndef OUTFILE
  !error "OUTFILE is not defined (see Scripts/package-host.sh)"
!endif

Unicode true
ManifestDPIAware true
RequestExecutionLevel user
SetCompressor /SOLID lzma
SetCompressorDictSize 64

!define APP_NAME "FastDoc"
!define APP_EXE "FastDoc.exe"
!define PUBLISHER "DubDubDub Corp."
!define PROG_ID "FastDoc.Document"
!define UNINSTALLER "Uninstall FastDoc.exe"
!define UNINSTALL_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\FastDoc"
!define HOMEPAGE "https://github.com/ww-w-ai/fast-document-reader"
; The single-instance mutex Program.cs claims (Global\ prefix + user name); a running copy holds it.
!define APP_MUTEX_PREFIX "Global\ai.ww-w.fastdoc.avalonia.mutex."

Name "${APP_NAME}"
OutFile "${OUTFILE}"
InstallDir "$LOCALAPPDATA\Programs\FastDoc"
BrandingText "${APP_NAME} ${VERSION} (${ARCH})"

VIProductVersion "${VERSION}.0"
VIAddVersionKey "ProductName" "${APP_NAME}"
VIAddVersionKey "CompanyName" "${PUBLISHER}"
VIAddVersionKey "FileDescription" "${APP_NAME} Setup"
VIAddVersionKey "FileVersion" "${VERSION}"
VIAddVersionKey "ProductVersion" "${VERSION}"
VIAddVersionKey "LegalCopyright" "${PUBLISHER}"

!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "x64.nsh"
!include "FileFunc.nsh"
!include "${STAGE_NSH}/extensions.nsh"

!define MUI_ICON "${__FILEDIR__}/../../FastDoc.Avalonia/Assets/fastdoc.ico"
!define MUI_UNICON "${__FILEDIR__}/../../FastDoc.Avalonia/Assets/fastdoc.ico"
!define MUI_ABORTWARNING
!define MUI_COMPONENTSPAGE_NODESC

!define MUI_FINISHPAGE_TITLE "$(FinishTitle)"
!define MUI_FINISHPAGE_TEXT "$(FinishText)"
; Room for the text above the two checkboxes; without it the last line is cut off.
!define MUI_FINISHPAGE_TEXT_LARGE
!define MUI_FINISHPAGE_RUN "$INSTDIR\${APP_EXE}"
!define MUI_FINISHPAGE_RUN_TEXT "$(FinishRun)"
!define MUI_FINISHPAGE_SHOWREADME ""
!define MUI_FINISHPAGE_SHOWREADME_NOTCHECKED
!define MUI_FINISHPAGE_SHOWREADME_TEXT "$(FinishDefaultApps)"
!define MUI_FINISHPAGE_SHOWREADME_FUNCTION OpenDefaultApps

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_COMPONENTS
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

; The setup picks the language matching the Windows display language.
!insertmacro MUI_LANGUAGE "English"
!insertmacro MUI_LANGUAGE "Korean"

LangString SecApp ${LANG_ENGLISH} "FastDoc (required)"
LangString SecApp ${LANG_KOREAN} "FastDoc (필수)"
LangString SecDesktopName ${LANG_ENGLISH} "Desktop shortcut"
LangString SecDesktopName ${LANG_KOREAN} "바탕 화면 바로 가기"
LangString FinishTitle ${LANG_ENGLISH} "FastDoc is installed"
LangString FinishTitle ${LANG_KOREAN} "FastDoc 설치를 마쳤습니다"
LangString FinishText ${LANG_ENGLISH} "FastDoc is in the Start menu and under Open with for every file type it reads.$\r$\n$\r$\nAn installer cannot choose your default apps. To open documents in FastDoc with a double-click, choose it in Settings > Apps > Default apps."
LangString FinishText ${LANG_KOREAN} "FastDoc을 시작 메뉴와, 읽을 수 있는 모든 파일의 연결 프로그램 목록에 추가했습니다.$\r$\n$\r$\n기본 앱은 설치 프로그램이 정할 수 없습니다. 더블클릭으로 열려면 설정 > 앱 > 기본 앱에서 FastDoc을 고르세요."
LangString FinishRun ${LANG_ENGLISH} "Launch FastDoc"
LangString FinishRun ${LANG_KOREAN} "FastDoc 실행"
LangString FinishDefaultApps ${LANG_ENGLISH} "Open Default apps settings"
LangString FinishDefaultApps ${LANG_KOREAN} "기본 앱 설정 열기"
LangString AppRunning ${LANG_ENGLISH} "FastDoc is running. Close every FastDoc window, then select Retry."
LangString AppRunning ${LANG_KOREAN} "FastDoc이 실행 중입니다. FastDoc 창을 모두 닫은 뒤 다시 시도를 누르세요."
LangString WrongArch ${LANG_ENGLISH} "This setup is for ${ARCH} Windows. Download the setup that matches this PC: win-arm64 for Windows on ARM, win-x64 for Intel and AMD."
LangString WrongArch ${LANG_KOREAN} "이 설치 프로그램은 ${ARCH} Windows용입니다. 이 PC에 맞는 설치 프로그램을 받으세요. ARM PC는 win-arm64, Intel·AMD PC는 win-x64입니다."

; ---------------------------------------------------------------------------------------------
; Registration: the same keys installers/windows/register.ps1 and the app's own
; File > Set as Default App (WindowsDefaultAppRegistrar) write, so all three agree.

!macro RegisterExt EXT
  WriteRegStr HKCU "Software\Classes\.${EXT}\OpenWithProgids" "${PROG_ID}" ""
  WriteRegStr HKCU "Software\FastDoc\Capabilities\FileAssociations" ".${EXT}" "${PROG_ID}"
!macroend

!macro UnregisterExt EXT
  DeleteRegValue HKCU "Software\Classes\.${EXT}\OpenWithProgids" "${PROG_ID}"
  DeleteRegKey /ifempty HKCU "Software\Classes\.${EXT}\OpenWithProgids"
  DeleteRegKey /ifempty HKCU "Software\Classes\.${EXT}"
!macroend

!macro NotifyShell
  ; SHCNE_ASSOCCHANGED, SHCNF_IDLIST: Explorer re-reads "Open with" without a restart.
  System::Call 'shell32::SHChangeNotify(i 0x08000000, i 0, p 0, p 0)'
!macroend

; Sets $R9 to 1 while a FastDoc process of this user holds its single-instance mutex.
!macro DetectRunningApp
  ReadEnvStr $R8 "USERNAME"
  System::Call 'kernel32::OpenMutexW(i 0x00100000, i 0, w "${APP_MUTEX_PREFIX}$R8") p .R7'
  ${If} $R7 <> 0
    System::Call 'kernel32::CloseHandle(p R7)'
    StrCpy $R9 1
  ${Else}
    StrCpy $R9 0
  ${EndIf}
!macroend

!macro WaitForAppClosed
  ${Do}
    !insertmacro DetectRunningApp
    ${If} $R9 = 0
      ${Break}
    ${EndIf}
    ${If} ${Cmd} `MessageBox MB_RETRYCANCEL|MB_ICONEXCLAMATION "$(AppRunning)" /SD IDCANCEL IDCANCEL`
      Abort
    ${EndIf}
  ${Loop}
!macroend

Function OpenDefaultApps
  ; Windows 11 opens FastDoc's own page in Default apps; older builds ignore the query and open
  ; the Default apps list.
  ExecShell "open" "ms-settings:defaultapps?registeredAppUser=FastDoc"
FunctionEnd

Section "$(SecApp)" SecMain
  SectionIn RO
  !insertmacro WaitForAppClosed

  ; Upgrade in place: the previous version's uninstaller removes exactly what it installed, so a
  ; file the new version no longer ships does not linger. _?= keeps it from copying itself away.
  ${If} ${FileExists} "$INSTDIR\${UNINSTALLER}"
    ExecWait '"$INSTDIR\${UNINSTALLER}" /S _?=$INSTDIR'
    Delete "$INSTDIR\${UNINSTALLER}"
  ${EndIf}

  !include "${STAGE_NSH}/install-files.nsh"
  SetOutPath "$INSTDIR"
  WriteUninstaller "$INSTDIR\${UNINSTALLER}"

  CreateShortcut "$SMPROGRAMS\${APP_NAME}.lnk" "$INSTDIR\${APP_EXE}" "" "$INSTDIR\${APP_EXE}" 0

  WriteRegStr HKCU "Software\Classes\${PROG_ID}" "" "FastDoc Document"
  WriteRegStr HKCU "Software\Classes\${PROG_ID}\DefaultIcon" "" '"$INSTDIR\${APP_EXE}",0'
  WriteRegStr HKCU "Software\Classes\${PROG_ID}\shell\open\command" "" '"$INSTDIR\${APP_EXE}" "%1"'
  WriteRegStr HKCU "Software\FastDoc\Capabilities" "ApplicationName" "${APP_NAME}"
  WriteRegStr HKCU "Software\FastDoc\Capabilities" "ApplicationDescription" "Reader for Markdown, Word, OpenDocument and Hangul documents"
  !insertmacro FASTDOC_FOR_EACH_EXT RegisterExt
  WriteRegStr HKCU "Software\RegisteredApplications" "FastDoc" "Software\FastDoc\Capabilities"

  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayName" "${APP_NAME}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "Publisher" "${PUBLISHER}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayIcon" '"$INSTDIR\${APP_EXE}",0'
  WriteRegStr HKCU "${UNINSTALL_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "UninstallString" '"$INSTDIR\${UNINSTALLER}"'
  WriteRegStr HKCU "${UNINSTALL_KEY}" "QuietUninstallString" '"$INSTDIR\${UNINSTALLER}" /S'
  WriteRegStr HKCU "${UNINSTALL_KEY}" "URLInfoAbout" "${HOMEPAGE}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "HelpLink" "${HOMEPAGE}/issues"
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoRepair" 1
  ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "EstimatedSize" "$0"

  !insertmacro NotifyShell
SectionEnd

Section /o "$(SecDesktopName)" SecDesktop
  CreateShortcut "$DESKTOP\${APP_NAME}.lnk" "$INSTDIR\${APP_EXE}" "" "$INSTDIR\${APP_EXE}" 0
SectionEnd

Function .onInit
  !if "${ARCH}" == "arm64"
    ${IfNot} ${IsNativeARM64}
      MessageBox MB_OK|MB_ICONSTOP "$(WrongArch)" /SD IDOK
      Abort
    ${EndIf}
  !else
    ${IfNot} ${IsNativeAMD64}
    ${AndIfNot} ${IsNativeARM64}
      MessageBox MB_OK|MB_ICONSTOP "$(WrongArch)" /SD IDOK
      Abort
    ${EndIf}
  !endif
  ; An upgrade keeps the desktop shortcut the previous install made.
  ${If} ${FileExists} "$DESKTOP\${APP_NAME}.lnk"
    SectionSetFlags ${SecDesktop} ${SF_SELECTED}
  ${EndIf}
FunctionEnd

Section "Uninstall"
  !insertmacro WaitForAppClosed

  Delete "$SMPROGRAMS\${APP_NAME}.lnk"
  Delete "$DESKTOP\${APP_NAME}.lnk"

  !insertmacro FASTDOC_FOR_EACH_EXT UnregisterExt
  DeleteRegKey HKCU "Software\Classes\${PROG_ID}"
  DeleteRegKey HKCU "Software\FastDoc"
  DeleteRegValue HKCU "Software\RegisteredApplications" "FastDoc"
  DeleteRegKey HKCU "${UNINSTALL_KEY}"

  !include "${STAGE_NSH}/uninstall-files.nsh"
  Delete "$INSTDIR\${UNINSTALLER}"
  RMDir "$INSTDIR"

  !insertmacro NotifyShell
SectionEnd
