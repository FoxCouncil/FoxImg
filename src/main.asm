; FoxImg - entry point, main window, commands
include foximg.inc

VK_ESCAPE   equ 1Bh

.data
g_hInst     dd 0
g_hWnd      dd 0
g_hAccel    dd 0
g_saveDesc  dd 0                        ; DESC_*: the text descriptor written beside the data file
g_saveKind  dd 0
g_saveFilter dd 0                       ; nFilterIndex from the last save dialog
g_saveRaw   dd 0                        ; cue sheet says MODE1/2352
g_cliRaw    dd 0                        ; /raw on the command line

WSTR szClassName, <FoxImgMain>
WSTR szTitle, <FoxImg>
szTitleA    db 'FoxImg', 0
WSTR szOpenTitle, <Open Disc Image>
WSTR szSaveTitle, <Save As / Convert>
WSTR szAddFilesTitle, <Add Files>
WSTR szBrowseTitle, <Choose a destination folder>
szErrOpen    db 'Could not open this image. No readable filesystem or track layout was found inside.', 0
szErrWrite    db 'Writing the image failed. Check free space and that the destination is writable.', 0
szErrReplace    db 'The image was written but the original could not be replaced.', 0
szErrExtract    db 'Some files could not be extracted.', 0
szErrBoot    db 'Select a file in the list first. Directories cannot be boot images.', 0
szBusy    db 'Please wait for the current operation to finish (or cancel it).', 0
szDiscard    db 'Discard unsaved changes?', 0
szDeleteAsk    db 'Delete the selected items from the image?', 0
szDeleteDirAsk    db 'Delete this folder and everything inside it?', 0
szAboutText    db 'FoxImg v1.4 - a small native disc image tool. 34 readable formats from ISO to CHD, eight built-in codecs, CD audio playback, one dependency-free exe.', 0
WSTR szSaved, <Saved>
WSTR szExtracted, <Extracted>
WSTR szCancelled, <Cancelled>
WSTR szAdded, <Files added>
WSTR szExtIso, <iso>
WSTR szExtCueDot, <.cue>
WSTR szExtBinDot, <.bin>
WSTR szExtGzDot, <.gz>
WSTR szExtZipDot, <.zip>
WSTR szExtCsoDot, <.cso>
WSTR szExtTocDot, <.toc>
WSTR szExtCcdDot, <.ccd>
WSTR szExtImgDot, <.img>
WSTR szExtEcmDot, <.ecm>
WSTR szExtNrgDot, <.nrg>
WSTR szExtMdsDot, <.mds>
WSTR szExtMdfDot, <.mdf>
WSTR szExtIszDot, <.isz>
WSTR szExtDaxDot, <.dax>
WSTR szExtJsoDot, <.jso>
WSTR szExtGczDot, <.gcz>
WSTR szExtUifDot, <.uif>
WSTR szExtDaaDot, <.daa>
WSTR szExtDmgDot, <.dmg>
; save extensions in SAVE_* order: the index plus one is the kind
g_saveExts  dd offset szExtGzDot, offset szExtZipDot, offset szExtCsoDot, offset szExtIszDot, offset szExtDaxDot
            dd offset szExtJsoDot, offset szExtGczDot, offset szExtUifDot, offset szExtDaaDot, offset szExtDmgDot
            dd offset szExtEcmDot, offset szExtNrgDot, 0
WSTR szTmpSuffix, <.tmp>
WSTR szSwRaw, </raw>
szCliOk     db 'FoxImg: wrote ', 0
szCliFail   db 'FoxImg: convert failed', 13, 10, 0
szCrLf      db 13, 10, 0
WSTR szNewFolderName, <New Folder>
WSTR szNewFileName, <New File>

WSTR szDiscImages, <Disc Images>
szFilterSave LABEL WORD
    dw 'I','S','O',' ','I','m','a','g','e',' ','(','*','.','i','s','o',')',0
    dw '*','.','i','s','o',0
    dw 'R','a','w',' ','I','m','a','g','e',' ','(','*','.','i','m','g',')',0
    dw '*','.','i','m','g',0
    dw 'B','I','N','/','C','U','E',' ','(','*','.','b','i','n',')',0
    dw '*','.','b','i','n',0
    dw 'B','I','N','/','C','U','E',' ','r','a','w',' ','(','M','O','D','E','1','/','2','3','5','2',')',0
    dw '*','.','b','i','n',0
    dw 'g','z','i','p',' ','I','S','O',' ','(','*','.','i','s','o','.','g','z',')',0
    dw '*','.','g','z',0
    dw 'Z','i','p',' ','a','r','c','h','i','v','e',' ','(','*','.','z','i','p',')',0
    dw '*','.','z','i','p',0
    dw 'C','S','O',' ','i','m','a','g','e',' ','(','*','.','c','s','o',')',0
    dw '*','.','c','s','o',0
    dw 'I','S','Z',' ','i','m','a','g','e',' ','(','*','.','i','s','z',')',0
    dw '*','.','i','s','z',0
    dw 'D','A','X',' ','i','m','a','g','e',' ','(','*','.','d','a','x',')',0
    dw '*','.','d','a','x',0
    dw 'J','S','O',' ','i','m','a','g','e',' ','(','*','.','j','s','o',')',0
    dw '*','.','j','s','o',0
    dw 'G','C','Z',' ','i','m','a','g','e',' ','(','*','.','g','c','z',')',0
    dw '*','.','g','c','z',0
    dw 'U','I','F',' ','i','m','a','g','e',' ','(','*','.','u','i','f',')',0
    dw '*','.','u','i','f',0
    dw 'D','A','A',' ','i','m','a','g','e',' ','(','*','.','d','a','a',')',0
    dw '*','.','d','a','a',0
    dw 'D','M','G',' ','i','m','a','g','e',' ','(','*','.','d','m','g',')',0
    dw '*','.','d','m','g',0
    dw 'E','C','M',' ','i','m','a','g','e',' ','(','*','.','e','c','m',')',0
    dw '*','.','e','c','m',0
    dw 'c','d','r','d','a','o',' ','T','O','C',' ','(','*','.','t','o','c',')',0
    dw '*','.','t','o','c',0
    dw 'C','l','o','n','e','C','D',' ','(','*','.','c','c','d',')',0
    dw '*','.','c','c','d',0
    dw 'N','e','r','o',' ','i','m','a','g','e',' ','(','*','.','n','r','g',')',0
    dw '*','.','n','r','g',0
    dw 'A','l','c','o','h','o','l',' ','1','2','0','%',' ','(','*','.','m','d','s',')',0
    dw '*','.','m','d','s',0
    dw 0
szFilterAll LABEL WORD
    dw 'A','l','l',' ','F','i','l','e','s',' ','(','*','.','*',')',0
    dw '*','.','*',0
    dw 0

szCueFmt    dw 'F','I','L','E',' ','"','%','s','"',' ','B','I','N','A','R','Y',13,10
            dw ' ',' ','T','R','A','C','K',' ','0','1',' ','M','O','D','E','1','/','2','0','4','8',13,10
            dw ' ',' ',' ',' ','I','N','D','E','X',' ','0','1',' ','0','0',':','0','0',':','0','0',13,10,0
szCueRawFmt dw 'F','I','L','E',' ','"','%','s','"',' ','B','I','N','A','R','Y',13,10
            dw ' ',' ','T','R','A','C','K',' ','0','1',' ','M','O','D','E','1','/','2','3','5','2',13,10
            dw ' ',' ',' ',' ','I','N','D','E','X',' ','0','1',' ','0','0',':','0','0',':','0','0',13,10,0
SAVE_FILTER_RAW equ 4                   ; the "BIN/CUE raw" entry of szFilterSave
WriteAllFile PROTO :DWORD,:DWORD,:DWORD
DESC_NONE   equ 0
DESC_CUE    equ 1
DESC_TOC    equ 2
DESC_CCD    equ 3
DESC_MDS    equ 4
; Alcohol 120% descriptor for one MODE1/2352 track in the sibling .mdf; the
; lead-out and track length are patched in
g_mdsTemplate   db 04Dh, 045h, 044h, 049h, 041h, 020h, 044h, 045h, 053h, 043h, 052h, 049h, 050h, 054h, 04Fh, 052h
                db 001h, 003h, 000h, 000h, 001h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h
                db 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h
                db 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h
                db 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h
                db 058h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 06Ah, 0FFh, 0FFh, 0FFh, 000h, 000h, 000h, 000h
                db 001h, 000h, 004h, 003h, 001h, 000h, 001h, 000h, 000h, 000h, 000h, 000h, 070h, 000h, 000h, 000h
                db 000h, 000h, 014h, 000h, 0A0h, 000h, 000h, 000h, 000h, 001h, 000h, 000h, 000h, 000h, 000h, 000h
                db 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h
                db 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h
                db 001h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h
                db 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h
                db 000h, 000h, 014h, 000h, 0A1h, 000h, 000h, 000h, 000h, 001h, 000h, 000h, 000h, 000h, 000h, 000h
                db 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h
                db 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h
                db 001h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h
                db 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h
                db 000h, 000h, 014h, 000h, 0A2h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h
                db 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h
                db 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h
                db 001h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h
                db 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h
                db 0AAh, 000h, 014h, 000h, 001h, 000h, 000h, 000h, 000h, 000h, 002h, 000h, 0B0h, 001h, 000h, 000h
                db 030h, 009h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h
                db 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h
                db 001h, 000h, 000h, 000h, 0B8h, 001h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h
                db 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h
                db 096h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 0C8h, 001h, 000h, 000h, 001h, 000h, 000h, 000h
                db 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 02Ah, 000h, 02Eh, 000h, 06Dh, 000h, 064h, 000h
                db 066h, 000h, 000h, 000h
MDS_TEMPLATE_CB equ 468
MDS_SESSION_END equ 92
MDS_A2_PMIN     equ 281
MDS_EXTRA_LEN   equ 436
szTocFmt    dw 'C','D','_','R','O','M',13,10
            dw 13,10
            dw '/','/',' ','T','r','a','c','k',' ','1',13,10
            dw 'T','R','A','C','K',' ','M','O','D','E','1','_','R','A','W',13,10
            dw 'N','O',' ','C','O','P','Y',13,10
            dw 'D','A','T','A','F','I','L','E',' ','"','%','s','"',13,10,0
szCcdFmt        db '[CloneCD]', 13, 10
                db 'Version=3', 13, 10
                db 13, 10
                db '[Disc]', 13, 10
                db 'TocEntries=4', 13, 10
                db 'Sessions=1', 13, 10
                db 'DataTracksScrambled=0', 13, 10
                db 'CDTextLength=0', 13, 10
                db 13, 10
                db '[Session 1]', 13, 10
                db 'PreGapMode=1', 13, 10
                db 'PreGapSubC=0', 13, 10
                db 13, 10
                db '[Entry 0]', 13, 10
                db 'Session=1', 13, 10
                db 'Point=0xa0', 13, 10
                db 'ADR=0x01', 13, 10
                db 'Control=0x04', 13, 10
                db 'TrackNo=0', 13, 10
                db 'AMin=0', 13, 10
                db 'ASec=0', 13, 10
                db 'AFrame=0', 13, 10
                db 'ALBA=-150', 13, 10
                db 'Zero=0', 13, 10
                db 'PMin=1', 13, 10
                db 'PSec=0', 13, 10
                db 'PFrame=0', 13, 10
                db 'PLBA=4350', 13, 10
                db 13, 10
                db '[Entry 1]', 13, 10
                db 'Session=1', 13, 10
                db 'Point=0xa1', 13, 10
                db 'ADR=0x01', 13, 10
                db 'Control=0x04', 13, 10
                db 'TrackNo=0', 13, 10
                db 'AMin=0', 13, 10
                db 'ASec=0', 13, 10
                db 'AFrame=0', 13, 10
                db 'ALBA=-150', 13, 10
                db 'Zero=0', 13, 10
                db 'PMin=1', 13, 10
                db 'PSec=0', 13, 10
                db 'PFrame=0', 13, 10
                db 'PLBA=4350', 13, 10
                db 13, 10
                db '[Entry 2]', 13, 10
                db 'Session=1', 13, 10
                db 'Point=0xa2', 13, 10
                db 'ADR=0x01', 13, 10
                db 'Control=0x04', 13, 10
                db 'TrackNo=0', 13, 10
                db 'AMin=0', 13, 10
                db 'ASec=0', 13, 10
                db 'AFrame=0', 13, 10
                db 'ALBA=-150', 13, 10
                db 'Zero=0', 13, 10
                db 'PMin=%d', 13, 10
                db 'PSec=%d', 13, 10
                db 'PFrame=%d', 13, 10
                db 'PLBA=%d', 13, 10
                db 13, 10
                db '[Entry 3]', 13, 10
                db 'Session=1', 13, 10
                db 'Point=0x01', 13, 10
                db 'ADR=0x01', 13, 10
                db 'Control=0x04', 13, 10
                db 'TrackNo=0', 13, 10
                db 'AMin=0', 13, 10
                db 'ASec=0', 13, 10
                db 'AFrame=0', 13, 10
                db 'ALBA=-150', 13, 10
                db 'Zero=0', 13, 10
                db 'PMin=0', 13, 10
                db 'PSec=2', 13, 10
                db 'PFrame=0', 13, 10
                db 'PLBA=0', 13, 10
                db 13, 10
                db '[TRACK 1]', 13, 10
                db 'MODE=1', 13, 10
                db 'INDEX 1=0', 13, 10
                db 0
MULTI_BUF   equ 32768

.data?
g_szMulti   dw MULTI_BUF dup(?)
g_saveData  dw MAX_PATH dup(?)
g_saveCue   dw MAX_PATH dup(?)
g_cliOut    dw MAX_PATH dup(?)          ; second command-line path: convert headless and exit
g_saveTmp   dw MAX_PATH + 8 dup(?)
g_szFilter  dw 512 dup(?)

.code

; ---------------------------------------------------------------------------
; Dialog helpers
; ---------------------------------------------------------------------------
ConfirmDiscard PROC
    .IF g_bModified == 0
        mov eax, TRUE
        ret
    .ENDIF
    invoke MessageBoxA, g_hWnd, offset szDiscard, offset szTitleA, MB_YESNO or MB_ICONWARNING
    .IF eax == IDYES
        mov eax, TRUE
    .ELSE
        xor eax, eax
    .ENDIF
    ret
ConfirmDiscard ENDP

SaveDialog PROC pszOut:DWORD, pszFilter:DWORD, pszDefExt:DWORD, pszTitle:DWORD
    LOCAL ofn:OPENFILENAMEW
    invoke RtlZeroMemory, addr ofn, sizeof OPENFILENAMEW
    mov ofn.lStructSize, sizeof OPENFILENAMEW
    push g_hWnd
    pop ofn.hwndOwner
    push pszFilter
    pop ofn.lpstrFilter
    mov ofn.nFilterIndex, 1
    push pszOut
    pop ofn.lpstrFile
    mov ofn.nMaxFile, MAX_PATH
    push pszTitle
    pop ofn.lpstrTitle
    push pszDefExt
    pop ofn.lpstrDefExt
    mov ofn.Flags, OFN_EXPLORER or OFN_OVERWRITEPROMPT or OFN_PATHMUSTEXIST or OFN_HIDEREADONLY
    invoke GetSaveFileNameW, addr ofn
    mov ecx, ofn.nFilterIndex
    mov g_saveFilter, ecx
    ret
SaveDialog ENDP

BrowseFolder PROC pszOut:DWORD
    LOCAL bi:BROWSEINFOW
    LOCAL pidl:DWORD
    invoke RtlZeroMemory, addr bi, sizeof BROWSEINFOW
    push g_hWnd
    pop bi.hwndOwner
    mov bi.lpszTitle, offset szBrowseTitle
    mov bi.ulFlags, BIF_RETURNONLYFSDIRS or BIF_NEWDIALOGSTYLE
    invoke SHBrowseForFolderW, addr bi
    .IF eax == 0
        ret
    .ENDIF
    mov pidl, eax
    invoke SHGetPathFromIDListW, pidl, pszOut
    push eax
    invoke CoTaskMemFree, pidl
    pop eax
    ret
BrowseFolder ENDP

; ---------------------------------------------------------------------------
; Image open / save
; ---------------------------------------------------------------------------
OpenImage PROC pszPath:DWORD
    LOCAL szLocal[MAX_PATH]:WORD
    invoke lstrcpynW, addr szLocal, pszPath, MAX_PATH
    invoke IsoOpen, addr szLocal
    .IF eax == 0
        invoke MessageBoxA, g_hWnd, offset szErrOpen, offset szTitleA, MB_OK or MB_ICONERROR
        xor eax, eax
        ret
    .ENDIF
    invoke VfsBuildFromIso
    invoke BootParse
    invoke lstrcpynW, offset g_szPath, addr szLocal, MAX_PATH
    mov g_bHavePath, TRUE
    push g_pRootNode
    pop g_pCurDir
    invoke UiRefreshTree
    invoke UiUpdateInfo
    invoke UiUpdateTitle
    mov eax, TRUE
    ret
OpenImage ENDP

; pszFmt formatted with the wide string pszArg, written as ASCII to pszPath
WriteTextFile PROC USES esi edi pszPath:DWORD, pszFmt:DWORD, pszArg:DWORD
    LOCAL szText[512]:WORD
    LOCAL szAscii[512]:BYTE
    LOCAL hOut:DWORD
    invoke wsprintfW, addr szText, pszFmt, pszArg
    lea esi, szText
    lea edi, szAscii
    .WHILE word ptr [esi] != 0
        movzx eax, word ptr [esi]
        .IF eax > 127
            mov eax, '?'
        .ENDIF
        mov [edi], al
        inc edi
        add esi, 2
    .ENDW
    lea eax, szAscii
    sub edi, eax
    invoke WriteAllFile, pszPath, addr szAscii, edi
    ret
WriteTextFile ENDP

; cb bytes at pData as the whole of pszPath
WriteAllFile PROC pszPath:DWORD, pData:DWORD, cb:DWORD
    LOCAL hOut:DWORD
    invoke CreateFileW, pszPath, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL
    .IF eax == INVALID_HANDLE_VALUE
        xor eax, eax
        ret
    .ENDIF
    mov hOut, eax
    invoke WriteAll, hOut, pData, cb
    invoke CloseHandle, hOut
    mov eax, TRUE
    ret
WriteAllFile ENDP

; The descriptor beside the data file, by g_saveDesc: a cue sheet (2048 or raw
; by g_saveRaw), a cdrdao toc, or a CloneCD ccd with the TOC entries of one
; data track. TRUE on success.
WriteDescFile PROC pszDesc:DWORD, pszData:DWORD
    LOCAL hData:DWORD
    LOCAL sizeLo:DWORD
    LOCAL sizeHi:DWORD
    LOCAL sectors:DWORD
    LOCAL mins:DWORD
    LOCAL secs:DWORD
    LOCAL frames:DWORD
    LOCAL szText[1024]:BYTE
    mov eax, g_saveDesc
    .IF eax == DESC_CUE
        invoke PathLeaf, pszData
        mov ecx, offset szCueFmt
        .IF g_saveRaw != 0
            mov ecx, offset szCueRawFmt
        .ENDIF
        invoke WriteTextFile, pszDesc, ecx, eax
    .ELSEIF eax == DESC_TOC
        invoke PathLeaf, pszData
        invoke WriteTextFile, pszDesc, offset szTocFmt, eax
    .ELSEIF eax == DESC_CCD || eax == DESC_MDS
        ; the lead-out sits after the last sector; MSF counts from 00:02:00
        invoke FileOpenRead, pszData
        .IF eax == INVALID_HANDLE_VALUE
            xor eax, eax
            ret
        .ENDIF
        mov hData, eax
        invoke FileSize64, hData, addr sizeLo, addr sizeHi
        invoke CloseHandle, hData
        mov eax, sizeLo
        xor edx, edx
        mov ecx, 2352
        div ecx
        mov sectors, eax
        add eax, 150
        xor edx, edx
        mov ecx, 75
        div ecx
        mov frames, edx
        xor edx, edx
        mov ecx, 60
        div ecx
        mov secs, edx
        mov mins, eax
        .IF g_saveDesc == DESC_CCD
            invoke wsprintfA, addr szText, offset szCcdFmt, mins, secs, frames, sectors
            invoke WriteAllFile, pszDesc, addr szText, eax
        .ELSE
            invoke RtlMoveMemory, addr szText, offset g_mdsTemplate, MDS_TEMPLATE_CB
            mov eax, sectors
            mov dword ptr szText[MDS_SESSION_END], eax
            mov dword ptr szText[MDS_EXTRA_LEN], eax
            mov eax, mins
            mov byte ptr szText[MDS_A2_PMIN], al
            mov eax, secs
            mov byte ptr szText[MDS_A2_PMIN + 1], al
            mov eax, frames
            mov byte ptr szText[MDS_A2_PMIN + 2], al
            invoke WriteAllFile, pszDesc, addr szText, MDS_TEMPLATE_CB
        .ENDIF
    .ELSE
        xor eax, eax
    .ENDIF
    ret
WriteDescFile ENDP

; Work out what pszTarget asks for: .bin/.cue -> BIN + CUE (raw when the raw
; filter was picked), a container extension -> ISO then that container, anything
; else -> ISO. Fills g_saveDesc, g_saveRaw, g_saveKind, g_saveData, g_saveCue and
; the .tmp path the writer targets.
SaveClassify PROC pszTarget:DWORD
    LOCAL szTarget[MAX_PATH]:WORD
    invoke lstrcpynW, addr szTarget, pszTarget, MAX_PATH
    mov g_saveDesc, DESC_NONE
    mov g_saveRaw, FALSE
    mov g_saveKind, SAVE_NONE
    invoke PathExt, addr szTarget
    push eax
    invoke lstrcmpiW, eax, offset szExtCueDot
    pop ecx
    .IF eax == 0
        mov g_saveDesc, DESC_CUE
        invoke lstrcpynW, offset g_saveCue, addr szTarget, MAX_PATH
        invoke PathWithExt, offset g_saveData, addr szTarget, offset szExtBinDot
    .ELSE
        push ecx
        invoke lstrcmpiW, ecx, offset szExtBinDot
        pop ecx
        .IF eax == 0
            mov g_saveDesc, DESC_CUE
            invoke lstrcpynW, offset g_saveData, addr szTarget, MAX_PATH
            invoke PathWithExt, offset g_saveCue, addr szTarget, offset szExtCueDot
        .ELSE
            push ecx
            invoke lstrcmpiW, ecx, offset szExtTocDot
            pop ecx
            .IF eax == 0
                mov g_saveDesc, DESC_TOC
                mov g_saveFilter, SAVE_FILTER_RAW
                invoke lstrcpynW, offset g_saveCue, addr szTarget, MAX_PATH
                invoke PathWithExt, offset g_saveData, addr szTarget, offset szExtBinDot
            .ELSE
                push ecx
                invoke lstrcmpiW, ecx, offset szExtCcdDot
                pop ecx
                .IF eax == 0
                    mov g_saveDesc, DESC_CCD
                    mov g_saveFilter, SAVE_FILTER_RAW
                    invoke lstrcpynW, offset g_saveCue, addr szTarget, MAX_PATH
                    invoke PathWithExt, offset g_saveData, addr szTarget, offset szExtImgDot
                .ELSE
                    invoke lstrcmpiW, ecx, offset szExtMdsDot
                    .IF eax == 0
                        mov g_saveDesc, DESC_MDS
                        mov g_saveFilter, SAVE_FILTER_RAW
                        invoke lstrcpynW, offset g_saveCue, addr szTarget, MAX_PATH
                        invoke PathWithExt, offset g_saveData, addr szTarget, offset szExtMdfDot
                    .ENDIF
                .ENDIF
            .ENDIF
        .ENDIF
        .IF g_saveDesc == DESC_NONE
            ; anything in the save table is an ISO first, then that container
            push esi
            mov esi, offset g_saveExts
            .WHILE dword ptr [esi] != 0
                invoke PathExt, addr szTarget
                invoke lstrcmpiW, eax, dword ptr [esi]
                .IF eax == 0
                    mov eax, esi
                    sub eax, offset g_saveExts
                    shr eax, 2
                    inc eax
                    mov g_saveKind, eax
                    .BREAK
                .ENDIF
                add esi, 4
            .ENDW
            pop esi
            invoke lstrcpynW, offset g_saveData, addr szTarget, MAX_PATH
        .ENDIF
    .ENDIF
    .IF g_saveDesc != DESC_NONE && g_saveFilter == SAVE_FILTER_RAW
        mov g_saveRaw, TRUE                 ; second pass turns the 2048 image into raw sectors
        mov g_saveKind, SAVE_RAW
    .ENDIF
    invoke wsprintfW, offset g_saveTmp, offset g_szCatFmt, offset g_saveData, offset szTmpSuffix
    ret
SaveClassify ENDP

; Save / convert to pszTarget on the worker thread. SaveFinish swaps the .tmp in and reopens.
SaveBegin PROC pszTarget:DWORD
    invoke SaveClassify, pszTarget
    invoke JobStartSave, offset g_saveTmp
    ret
SaveBegin ENDP

; Command line: open g_szPath, write it as g_cliOut, no window. TRUE on success.
CliConvert PROC
    LOCAL ok:DWORD
    LOCAL hCon:DWORD
    LOCAL written:DWORD
    LOCAL cb:DWORD
    LOCAL szOut[MAX_PATH]:BYTE
    mov ok, FALSE
    invoke IsoOpen, offset g_szPath
    .IF eax != 0
        invoke VfsBuildFromIso
        invoke BootParse
        .IF g_cliRaw != 0
            mov g_saveFilter, SAVE_FILTER_RAW
        .ENDIF
        invoke SaveClassify, offset g_cliOut
        invoke JobRunSave, offset g_saveTmp
        .IF eax != 0
            invoke IsoClose
            invoke MoveFileExW, offset g_saveTmp, offset g_saveData, MOVEFILE_REPLACE_EXISTING
            .IF eax != 0
                mov ok, TRUE
                .IF g_saveDesc != DESC_NONE
                    invoke WriteDescFile, offset g_saveCue, offset g_saveData
                    mov ok, eax
                .ENDIF
            .ENDIF
        .ELSE
            invoke DeleteFileW, offset g_saveTmp
        .ENDIF
    .ENDIF
    ; one line to the console this was started from, when there is one
    invoke AttachConsole, ATTACH_PARENT_PROCESS
    .IF eax != 0
        invoke GetStdHandle, STD_OUTPUT_HANDLE
        mov hCon, eax
        .IF ok != 0
            invoke lstrlenA, offset szCliOk
            mov cb, eax
            invoke WriteFile, hCon, offset szCliOk, cb, addr written, NULL
            invoke WideCharToMultiByte, CP_ACP, 0, offset g_cliOut, -1, addr szOut, MAX_PATH, NULL, NULL
            invoke lstrlenA, addr szOut
            mov cb, eax
            invoke WriteFile, hCon, addr szOut, cb, addr written, NULL
            invoke lstrlenA, offset szCrLf
            mov cb, eax
            invoke WriteFile, hCon, offset szCrLf, cb, addr written, NULL
        .ELSE
            invoke lstrlenA, offset szCliFail
            mov cb, eax
            invoke WriteFile, hCon, offset szCliFail, cb, addr written, NULL
        .ENDIF
    .ENDIF
    mov eax, ok
    ret
CliConvert ENDP

SaveFinish PROC result:DWORD
    .IF g_jobCancel != 0
        invoke DeleteFileW, offset g_saveTmp
        invoke UiSetStatus, offset szCancelled
        ret
    .ENDIF
    .IF result == 0
        invoke MessageBoxA, g_hWnd, offset szErrWrite, offset szTitleA, MB_OK or MB_ICONERROR
        ret
    .ENDIF
    invoke IsoClose                             ; release the mapping before replacing the file
    invoke MoveFileExW, offset g_saveTmp, offset g_saveData, MOVEFILE_REPLACE_EXISTING
    .IF eax == 0
        invoke MessageBoxA, g_hWnd, offset szErrReplace, offset szTitleA, MB_OK or MB_ICONERROR
        .IF g_bHavePath != 0
            invoke OpenImage, offset g_szPath
        .ENDIF
        ret
    .ENDIF
    .IF g_saveDesc != DESC_NONE
        invoke WriteDescFile, offset g_saveCue, offset g_saveData
        invoke OpenImage, offset g_saveCue
    .ELSE
        invoke OpenImage, offset g_saveData
    .ENDIF
    invoke UiSetStatus, offset szSaved
    ret
SaveFinish ENDP

; Worker thread completion (UI thread)
AppJobFinished PROC kind:DWORD, result:DWORD
    mov eax, kind
    .IF eax == JOB_SAVE
        invoke SaveFinish, result
    .ELSEIF eax == JOB_EXTRACT
        .IF g_jobCancel != 0
            invoke UiSetStatus, offset szCancelled
        .ELSEIF result == 0
            invoke MessageBoxA, g_hWnd, offset szErrExtract, offset szTitleA, MB_OK or MB_ICONWARNING
            invoke UiSetStatus, offset szExtracted
        .ELSE
            invoke UiSetStatus, offset szExtracted
        .ENDIF
    .ELSEIF eax == JOB_ADD
        invoke UiRefreshTree
        invoke UiUpdateTitle
        .IF g_jobCancel != 0
            invoke UiSetStatus, offset szCancelled
        .ELSE
            invoke UiSetStatus, offset szAdded
        .ENDIF
    .ENDIF
    invoke UiUpdateInfo
    ret
AppJobFinished ENDP

; ---------------------------------------------------------------------------
; Commands
; ---------------------------------------------------------------------------
DeleteCb PROC pNode:DWORD, lParam:DWORD
    invoke BootForgetNode, pNode
    invoke VfsDelete, pNode
    ret
DeleteCb ENDP

CmdNew PROC
    invoke ConfirmDiscard
    .IF eax == 0
        ret
    .ENDIF
    invoke IsoClose
    mov g_bootCount, 0
    invoke VfsNewImage
    mov g_bHavePath, FALSE
    push g_pRootNode
    pop g_pCurDir
    invoke UiRefreshTree
    invoke UiUpdateInfo
    invoke UiUpdateTitle
    ret
CmdNew ENDP

CmdOpen PROC
    LOCAL ofn:OPENFILENAMEW
    LOCAL szFile[MAX_PATH]:WORD
    invoke ConfirmDiscard
    .IF eax == 0
        ret
    .ENDIF
    mov szFile[0], 0
    invoke RtlZeroMemory, addr ofn, sizeof OPENFILENAMEW
    mov ofn.lStructSize, sizeof OPENFILENAMEW
    push g_hWnd
    pop ofn.hwndOwner
    invoke CtBuildOpenFilter, offset g_szFilter, offset szDiscImages, offset szFilterAll
    mov ofn.lpstrFilter, offset g_szFilter
    mov ofn.nFilterIndex, 1
    lea eax, szFile
    mov ofn.lpstrFile, eax
    mov ofn.nMaxFile, MAX_PATH
    mov ofn.lpstrTitle, offset szOpenTitle
    mov ofn.Flags, OFN_EXPLORER or OFN_FILEMUSTEXIST or OFN_PATHMUSTEXIST or OFN_HIDEREADONLY
    invoke GetOpenFileNameW, addr ofn
    .IF eax != 0
        invoke OpenImage, addr szFile
    .ENDIF
    ret
CmdOpen ENDP

CmdSaveAs PROC
    LOCAL szFile[MAX_PATH]:WORD
    mov szFile[0], 0
    .IF g_bHavePath != 0
        invoke lstrcpynW, addr szFile, offset g_szPath, MAX_PATH
    .ENDIF
    invoke SaveDialog, addr szFile, offset szFilterSave, offset szExtIso, offset szSaveTitle
    .IF eax != 0
        invoke SaveBegin, addr szFile
    .ENDIF
    ret
CmdSaveAs ENDP

CmdSave PROC
    ; containers (NRG, MDS, ...) are read-only inputs: saving means choosing an output image; CUE stays writable
    mov eax, g_bContainer
    .IF g_bCue != 0
        xor eax, eax
    .ENDIF
    .IF g_bHavePath != 0 && eax == 0
        invoke SaveBegin, offset g_szPath
    .ELSE
        invoke CmdSaveAs
    .ENDIF
    ret
CmdSave ENDP

CmdExtractAll PROC USES esi
    LOCAL szDir[MAX_PATH]:WORD
    .IF g_pRootNode == 0
        ret
    .ENDIF
    invoke BrowseFolder, addr szDir
    .IF eax == 0
        ret
    .ENDIF
    invoke JobNodesReset
    mov esi, g_pRootNode
    mov esi, [esi].NODE.pFirstChild
    .WHILE esi != 0
        invoke JobNodesAdd, esi, 0
        mov esi, [esi].NODE.pNextSibling
    .ENDW
    invoke JobStartExtract, addr szDir
    ret
CmdExtractAll ENDP

CmdExtract PROC
    LOCAL szDir[MAX_PATH]:WORD
    invoke UiCtxIsTree
    .IF eax == 0
        invoke SendMessageW, g_hList, LVM_GETSELECTEDCOUNT, 0, 0
        .IF eax == 0
            ret
        .ENDIF
    .ENDIF
    invoke BrowseFolder, addr szDir
    .IF eax == 0
        ret
    .ENDIF
    invoke JobNodesReset
    invoke UiCtxIsTree
    .IF eax != 0
        invoke JobNodesAdd, g_pCurDir, 0
    .ELSE
        invoke UiForEachSelected, offset JobNodesAdd, 0
    .ENDIF
    invoke JobStartExtract, addr szDir
    ret
CmdExtract ENDP

CmdAddFiles PROC USES esi edi
    LOCAL ofn:OPENFILENAMEW
    LOCAL szPath[MAX_PATH]:WORD
    LOCAL pDir:DWORD

    invoke UiCtxDir
    .IF eax == 0
        ret
    .ENDIF
    mov pDir, eax
    mov g_szMulti[0], 0
    invoke RtlZeroMemory, addr ofn, sizeof OPENFILENAMEW
    mov ofn.lStructSize, sizeof OPENFILENAMEW
    push g_hWnd
    pop ofn.hwndOwner
    mov ofn.lpstrFilter, offset szFilterAll
    mov ofn.nFilterIndex, 1
    mov ofn.lpstrFile, offset g_szMulti
    mov ofn.nMaxFile, MULTI_BUF
    mov ofn.lpstrTitle, offset szAddFilesTitle
    mov ofn.Flags, OFN_EXPLORER or OFN_FILEMUSTEXIST or OFN_PATHMUSTEXIST or OFN_HIDEREADONLY or OFN_ALLOWMULTISELECT
    invoke GetOpenFileNameW, addr ofn
    .IF eax == 0
        ret
    .ENDIF
    invoke JobPathsReset
    mov esi, offset g_szMulti
    invoke lstrlenW, esi
    lea edi, [esi + eax * 2 + 2]
    .IF word ptr [edi] == 0
        invoke JobPathsAdd, esi
    .ELSE
        .WHILE word ptr [edi] != 0
            invoke wsprintfW, addr szPath, offset g_szJoinFmt, esi, edi
            invoke JobPathsAdd, addr szPath
            invoke lstrlenW, edi
            lea edi, [edi + eax * 2 + 2]
        .ENDW
    .ENDIF
    mov eax, pDir
    mov g_pCurDir, eax
    invoke JobStartAdd, pDir
    ret
CmdAddFiles ENDP

CmdNewNode PROC bDir:DWORD
    LOCAL szName[NODE_NAME_MAX]:WORD
    LOCAL pDir:DWORD
    LOCAL pNode:DWORD
    LOCAL nflags:DWORD
    invoke UiCtxDir
    .IF eax == 0
        ret
    .ENDIF
    mov pDir, eax
    mov nflags, 0
    mov ecx, offset szNewFileName
    .IF bDir != 0
        mov nflags, NF_DIR
        mov ecx, offset szNewFolderName
    .ENDIF
    invoke VfsUniqueName, pDir, ecx, addr szName
    invoke VfsNew, pDir, addr szName, nflags
    .IF eax == 0
        ret
    .ENDIF
    mov pNode, eax
    invoke VfsDateNow, eax
    mov g_bModified, TRUE
    mov eax, pDir
    mov g_pCurDir, eax
    invoke UiRefreshTree
    invoke UiUpdateTitle
    invoke UiBeginRename, pNode
    ret
CmdNewNode ENDP

CmdDelete PROC
    LOCAL pDir:DWORD
    invoke UiCtxIsTree
    .IF eax != 0
        mov eax, g_pCurDir
        .IF eax == 0 || eax == g_pRootNode
            ret
        .ENDIF
        invoke MessageBoxA, g_hWnd, offset szDeleteDirAsk, offset szTitleA, MB_YESNO or MB_ICONQUESTION
        .IF eax != IDYES
            ret
        .ENDIF
        mov eax, g_pCurDir
        mov ecx, [eax].NODE.pParent
        mov pDir, ecx
        invoke DeleteCb, eax, 0
        mov eax, pDir
        mov g_pCurDir, eax
    .ELSE
        invoke SendMessageW, g_hList, LVM_GETSELECTEDCOUNT, 0, 0
        .IF eax == 0
            ret
        .ENDIF
        invoke MessageBoxA, g_hWnd, offset szDeleteAsk, offset szTitleA, MB_YESNO or MB_ICONQUESTION
        .IF eax != IDYES
            ret
        .ENDIF
        invoke UiForEachSelected, offset DeleteCb, 0
    .ENDIF
    invoke UiRefreshTree
    invoke UiUpdateInfo
    invoke UiUpdateTitle
    ret
CmdDelete ENDP

CmdOpenDir PROC
    invoke UiSelectedNode
    .IF eax != 0
        test [eax].NODE.nflags, NF_DIR
        .IF !ZERO?
            invoke UiSelectDir, eax
        .ENDIF
    .ENDIF
    ret
CmdOpenDir ENDP

CmdBoot PROC platform:DWORD
    invoke UiSelectedNode
    .IF eax != 0
        invoke BootSetEntry, eax, platform
    .ENDIF
    .IF eax == 0
        invoke MessageBoxA, g_hWnd, offset szErrBoot, offset szTitleA, MB_OK or MB_ICONINFORMATION
        ret
    .ENDIF
    invoke UiUpdateInfo
    invoke UiUpdateTitle
    ret
CmdBoot ENDP

AppCommand PROC id:DWORD
    mov eax, id
    .IF eax == IDC_CANCEL
        invoke JobCancel
        ret
    .ENDIF
    ; everything that touches the model or the files waits for the running job
    .IF g_jobBusy != 0
        .IF eax != IDM_ABOUT && eax != IDM_PREVIEW && eax != IDM_OPENDIR && eax != IDM_REFRESH
            invoke UiSetStatus, offset szBusy
            ret
        .ENDIF
    .ENDIF
    .IF eax == IDM_NEW
        invoke CmdNew
    .ELSEIF eax == IDM_OPEN
        invoke CmdOpen
    .ELSEIF eax == IDM_SAVE
        invoke CmdSave
    .ELSEIF eax == IDM_SAVEAS
        invoke CmdSaveAs
    .ELSEIF eax == IDM_EXTRACTALL
        invoke CmdExtractAll
    .ELSEIF eax == IDM_ADDFILES
        invoke CmdAddFiles
    .ELSEIF eax == IDM_NEWFOLDER
        invoke CmdNewNode, TRUE
    .ELSEIF eax == IDM_NEWFILE
        invoke CmdNewNode, FALSE
    .ELSEIF eax == IDM_RENAME
        invoke UiSelectedNode
        .IF eax != 0
            invoke UiBeginRename, eax
        .ENDIF
    .ELSEIF eax == IDM_DELETE
        invoke CmdDelete
    .ELSEIF eax == IDM_EXTRACT
        invoke CmdExtract
    .ELSEIF eax == IDM_OPENDIR
        invoke CmdOpenDir
    .ELSEIF eax == IDM_BOOT_BIOS
        invoke CmdBoot, BOOT_PLATFORM_X86
    .ELSEIF eax == IDM_BOOT_EFI
        invoke CmdBoot, BOOT_PLATFORM_EFI
    .ELSEIF eax == IDM_BOOT_CLEAR
        invoke BootClear
        invoke UiUpdateInfo
        invoke UiUpdateTitle
    .ELSEIF eax == IDM_PREVIEW
        xor g_bPreview, 1
        invoke UiLayout, g_hWnd
        invoke UiSelectedNode
        invoke PreviewShow, eax
    .ELSEIF eax == IDM_REFRESH
        .IF g_jobBusy == 0
            invoke UiRefreshTree
            invoke UiUpdateInfo
            invoke UiUpdateTitle
        .ENDIF
    .ELSEIF eax == IDM_EXIT
        invoke SendMessageW, g_hWnd, WM_CLOSE, 0, 0
    .ELSEIF eax == IDM_ABOUT
        invoke MessageBoxA, g_hWnd, offset szAboutText, offset szTitleA, MB_OK or MB_ICONINFORMATION
    .ENDIF
    ret
AppCommand ENDP

; ---------------------------------------------------------------------------
; Command line: FoxImg [image [output [/raw]]]. The image goes to g_szPath; an
; output path to g_cliOut asks for a headless convert.
; ---------------------------------------------------------------------------
; One argument from pSrc into pDst (quotes stripped, MAX_PATH bound); returns the
; position after it, or 0 when none is left
CliArg PROC USES esi edi pSrc:DWORD, pDst:DWORD
    mov esi, pSrc
    .WHILE word ptr [esi] == ' ' || word ptr [esi] == 9
        add esi, 2
    .ENDW
    .IF word ptr [esi] == 0
        xor eax, eax
        ret
    .ENDIF
    mov edi, pDst
    mov ecx, MAX_PATH - 1
    mov edx, ' '
    .IF word ptr [esi] == '"'
        add esi, 2
        mov edx, '"'
    .ENDIF
    .WHILE word ptr [esi] != 0
        movzx eax, word ptr [esi]
        .BREAK .IF eax == edx
        .BREAK .IF edx == ' ' && eax == 9
        .IF ecx != 0
            mov word ptr [edi], ax
            add edi, 2
            dec ecx
        .ENDIF
        add esi, 2
    .ENDW
    .IF word ptr [esi] == '"'
        add esi, 2
    .ENDIF
    mov word ptr [edi], 0
    mov eax, esi
    ret
CliArg ENDP

ParseCommandLine PROC USES esi
    LOCAL szArg[MAX_PATH]:WORD
    invoke GetCommandLineW
    mov esi, eax
    invoke CliArg, esi, addr szArg          ; the program itself
    mov esi, eax
    invoke CliArg, esi, offset g_szPath
    .IF eax == 0
        ret
    .ENDIF
    mov esi, eax
    .WHILE 1
        invoke CliArg, esi, addr szArg
        .BREAK .IF eax == 0
        mov esi, eax
        .IF word ptr szArg[0] == '/' || word ptr szArg[0] == '-'
            mov word ptr szArg[0], '/'
            invoke lstrcmpiW, addr szArg, offset szSwRaw
            .IF eax == 0
                mov g_cliRaw, TRUE
            .ENDIF
        .ELSE
            invoke lstrcpynW, offset g_cliOut, addr szArg, MAX_PATH
        .ENDIF
    .ENDW
    mov eax, TRUE
    ret
ParseCommandLine ENDP

; ---------------------------------------------------------------------------
; WndProc
; ---------------------------------------------------------------------------
WndProc PROC hWnd:DWORD, uMsg:DWORD, wParam:DWORD, lParam:DWORD
    mov eax, uMsg
    .IF eax == MM_WOM_DONE
        invoke AudioOnDone, lParam
        xor eax, eax
        ret
    .ENDIF
    .IF eax == WM_CREATE
        invoke UiCreateControls, hWnd
        invoke JobInit, hWnd
        invoke ThemeApply, hWnd
        invoke DndInit
    .ELSEIF eax == WM_SIZE
        invoke UiLayout, hWnd
        invoke JobLayout
    .ELSEIF eax == WM_TIMER
        .IF wParam == JOB_TIMER_ID
            invoke JobOnTimer
        .ENDIF
    .ELSEIF eax == WM_JOBDONE
        invoke JobOnDone, wParam
    .ELSEIF eax == WM_SETCURSOR
        invoke JobSetCursor
        .IF eax != 0
            mov eax, TRUE
            ret
        .ENDIF
        invoke DefWindowProcW, hWnd, uMsg, wParam, lParam
        ret
    .ELSEIF eax == WM_ERASEBKGND
        invoke ThemeEraseBkgnd, hWnd, wParam
        ret
    .ELSEIF eax == WM_DRAWITEM
        .IF g_bDark != 0
            invoke ThemeDrawStatus, lParam
            ret
        .ENDIF
        invoke DefWindowProcW, hWnd, uMsg, wParam, lParam
        ret
    .ELSEIF eax == WM_CTLCOLOREDIT || eax == WM_CTLCOLORSTATIC
        invoke PreviewCtlColor, wParam, lParam
        .IF eax != 0
            ret
        .ENDIF
        invoke DefWindowProcW, hWnd, uMsg, wParam, lParam
        ret
    .ELSEIF eax == WM_SETTINGCHANGE
        invoke ThemeOnSettingChange, hWnd, lParam
    .ELSEIF eax == WM_UAHDRAWMENU
        invoke ThemeDrawMenuBar, hWnd, lParam
        .IF eax != 0
            ret
        .ENDIF
        invoke DefWindowProcW, hWnd, uMsg, wParam, lParam
        ret
    .ELSEIF eax == WM_UAHDRAWMENUITEM
        invoke ThemeDrawMenuItem, hWnd, lParam
        .IF eax != 0
            ret
        .ENDIF
        invoke DefWindowProcW, hWnd, uMsg, wParam, lParam
        ret
    .ELSEIF eax == WM_NCPAINT || eax == WM_NCACTIVATE
        invoke DefWindowProcW, hWnd, uMsg, wParam, lParam
        push eax
        invoke ThemeDrawMenuBottomLine, hWnd
        pop eax
        ret
    .ELSEIF eax == WM_DPICHANGED
        movzx eax, word ptr wParam
        invoke UiUpdateDpi, hWnd, eax
        mov edx, lParam
        mov eax, [edx].RECT.right
        sub eax, [edx].RECT.left
        mov ecx, [edx].RECT.bottom
        sub ecx, [edx].RECT.top
        invoke SetWindowPos, hWnd, NULL, [edx].RECT.left, [edx].RECT.top, eax, ecx, SWP_NOZORDER or SWP_NOACTIVATE
    .ELSEIF eax == WM_INITMENUPOPUP
        invoke GetMenu, hWnd
        mov ecx, MF_BYCOMMAND or MF_UNCHECKED
        .IF g_bPreview != 0
            mov ecx, MF_BYCOMMAND or MF_CHECKED
        .ENDIF
        invoke CheckMenuItem, eax, IDM_PREVIEW, ecx
    .ELSEIF eax == WM_COMMAND
        movzx eax, word ptr wParam
        invoke AppCommand, eax
    .ELSEIF eax == WM_NOTIFY
        invoke UiOnNotify, lParam
        ret
    .ELSEIF eax == WM_CONTEXTMENU
        .IF g_jobBusy == 0
            movsx eax, word ptr lParam
            movsx ecx, word ptr lParam[2]
            invoke UiContextMenu, wParam, eax, ecx
        .ENDIF
    .ELSEIF eax == WM_DROPFILES
        invoke UiOnDropFiles, wParam
    .ELSEIF eax == WM_CLOSE
        .IF g_jobBusy != 0
            invoke UiSetStatus, offset szBusy
        .ELSE
            invoke ConfirmDiscard
            .IF eax != 0
                invoke DestroyWindow, hWnd
            .ENDIF
        .ENDIF
    .ELSEIF eax == WM_DESTROY
        invoke DndShutdown
        invoke IsoClose
        invoke PostQuitMessage, 0
    .ELSE
        invoke DefWindowProcW, hWnd, uMsg, wParam, lParam
        ret
    .ENDIF
    xor eax, eax
    ret
WndProc ENDP

; ---------------------------------------------------------------------------
; start - process entry (no CRT)
; ---------------------------------------------------------------------------
start PROC
    LOCAL wc:WNDCLASSEXW
    LOCAL msg:MSG
    LOCAL icc:INITCOMMONCONTROLSEX
    LOCAL hMenu:DWORD
    LOCAL rcWork:RECT
    LOCAL cxInit:DWORD
    LOCAL cyInit:DWORD

    invoke GetModuleHandleW, NULL
    mov g_hInst, eax
    invoke VfsInit
    invoke DndInit
    invoke ParseCommandLine
    .IF word ptr g_cliOut[0] != 0           ; FoxImg image output [/raw]: convert and leave
        invoke CliConvert
        xor eax, 1
        invoke ExitProcess, eax
    .ENDIF

    mov icc.dwSize, sizeof INITCOMMONCONTROLSEX
    mov icc.dwICC, ICC_LISTVIEW_CLASSES or ICC_TREEVIEW_CLASSES or ICC_BAR_CLASSES or ICC_PROGRESS_CLASS
    invoke InitCommonControlsEx, addr icc
    invoke ThemeInit

    invoke SystemParametersInfoW, SPI_GETWORKAREA, 0, addr rcWork, 0
    mov eax, rcWork.right
    sub eax, rcWork.left
    invoke MulDiv, eax, 65, 100
    mov cxInit, eax
    mov eax, rcWork.bottom
    sub eax, rcWork.top
    invoke MulDiv, eax, 65, 100
    mov cyInit, eax

    mov wc.cbSize, sizeof WNDCLASSEXW
    mov wc.style, CS_HREDRAW or CS_VREDRAW
    mov wc.lpfnWndProc, offset WndProc
    mov wc.cbClsExtra, 0
    mov wc.cbWndExtra, 0
    push g_hInst
    pop wc.hInstance
    invoke LoadIconW, g_hInst, IDI_APP
    mov wc.hIcon, eax
    mov wc.hIconSm, eax
    invoke LoadCursorW, NULL, IDC_ARROW
    mov wc.hCursor, eax
    mov wc.hbrBackground, NULL
    mov wc.lpszMenuName, NULL
    mov wc.lpszClassName, offset szClassName
    invoke RegisterClassExW, addr wc

    invoke LoadAcceleratorsW, g_hInst, IDR_ACCEL
    mov g_hAccel, eax
    invoke LoadMenuW, g_hInst, IDR_MAINMENU
    mov hMenu, eax

    invoke CreateWindowExW, 0, offset szClassName, offset szTitle, WS_OVERLAPPEDWINDOW or WS_CLIPCHILDREN, CW_USEDEFAULT, CW_USEDEFAULT, cxInit, cyInit, NULL, hMenu, g_hInst, NULL
    mov g_hWnd, eax
    invoke ShowWindow, g_hWnd, SW_SHOWDEFAULT
    invoke UpdateWindow, g_hWnd

    .IF word ptr g_szPath[0] != 0
        invoke OpenImage, offset g_szPath
    .ELSE
        xor eax, eax
    .ENDIF
    .IF eax == 0
        invoke CmdNew
    .ENDIF

    .WHILE TRUE
        invoke GetMessageW, addr msg, NULL, 0, 0
        .BREAK .IF eax == 0
        ; Escape cancels a running job (only then, so label editing keeps its own Escape)
        .IF msg.message == WM_KEYDOWN && msg.wParam == VK_ESCAPE && g_jobBusy != 0
            invoke JobCancel
            .CONTINUE
        .ENDIF
        invoke TranslateAcceleratorW, g_hWnd, g_hAccel, addr msg
        .IF eax == 0
            invoke TranslateMessage, addr msg
            invoke DispatchMessageW, addr msg
        .ENDIF
    .ENDW

    invoke ExitProcess, msg.wParam
    ret
start ENDP

END start
