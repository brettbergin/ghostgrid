; ghostgrid's additions to the Tauri NSIS installer: "Open in ghostgrid" on
; folders and folder backgrounds in Explorer (the Windows counterpart of
; dropping a folder on the Dock icon). Per user, like the install.

!macro NSIS_HOOK_POSTINSTALL
  WriteRegStr HKCU "Software\Classes\Directory\shell\ghostgrid" "" "Open in ghostgrid"
  WriteRegStr HKCU "Software\Classes\Directory\shell\ghostgrid" "Icon" "$INSTDIR\ghostgrid.exe"
  WriteRegStr HKCU "Software\Classes\Directory\shell\ghostgrid\command" "" '"$INSTDIR\ghostgrid.exe" --open "%V"'
  WriteRegStr HKCU "Software\Classes\Directory\Background\shell\ghostgrid" "" "Open in ghostgrid"
  WriteRegStr HKCU "Software\Classes\Directory\Background\shell\ghostgrid" "Icon" "$INSTDIR\ghostgrid.exe"
  WriteRegStr HKCU "Software\Classes\Directory\Background\shell\ghostgrid\command" "" '"$INSTDIR\ghostgrid.exe" --open "%V"'
!macroend

!macro NSIS_HOOK_POSTUNINSTALL
  DeleteRegKey HKCU "Software\Classes\Directory\shell\ghostgrid"
  DeleteRegKey HKCU "Software\Classes\Directory\Background\shell\ghostgrid"
!macroend
