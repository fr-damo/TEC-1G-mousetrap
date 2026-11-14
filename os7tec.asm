; =============================================================================
; OS7TEC - a small stand-in for the ColecoVision OS7 BIOS, for the TEC-1G
;
; Mouse Trap was written against the ColecoVision BIOS (PUTOBJ, timers, the
; sound engine, controller polling ...).  The TEC-1G has no such BIOS, so this
; file re-implements the subset of OS7 calls that the game uses, on top of:
;
;   * a TMS9918A video card (ports below)
;   * the TEC-1G joystick port and hex keypad, read through MON3 API calls
;   * an optional SN76489 sound chip (the ColecoVision sound chip)
;
; No interrupt wiring is needed.  The VDP frame flag is polled; every time the
; game tests a timer or polls the controllers we check the flag and, once per
; video frame, run the game's old NMI handler (sprites, music, timers).
;
; All code is original.  None of the Coleco BIOS is reproduced.
; =============================================================================

; ------------------------------------------------------------- configuration
VDP_DATA        EQU 0BEH        ; TMS9918 VRAM data port   (MODE=0)
VDP_CTRL        EQU 0BFH        ; TMS9918 register/status  (MODE=1)

SOUND_CHIP      EQU 0           ; 1 = an SN76489 sound card is fitted
DIAG            EQU 0           ; 1 = show timing counters on the bottom row
SN_PORT         EQU 0FFH        ; its write port (set this if SOUND_CHIP=1!)

STACK_TOP       EQU 8000H       ; game stack, grows down from 7FFFH
BIOS_RAM        EQU 7400H       ; 400 bytes of variables for this file

; MON3 API (RST 10H, function number in C)
MON_SCANKEYS    EQU 16          ; Z = key down, A = key code

; Joystick (J9): read directly at port FEH with A11 low, active low.
;   bit0 up, bit1 down, bit2 left, bit3 right, bits 4-6 fire buttons
JOY_PORT        EQU 0F7FEH      ; B = F7 (A11 low), C = FE
JOY_FIRE_MASK   EQU 70H

; ------------------------------------------------------------- variables
MON_SP          EQU BIOS_RAM+0      ; 2  MON3 stack pointer, for quitting
TBL_BASE        EQU BIOS_RAM+2      ; 10 VRAM table bases (codes 0-4)
FRAME_SEEN      EQU BIOS_RAM+12     ; 1  a video frame has passed (input throttle)
IN_TICK         EQU BIOS_RAM+13     ; 1  re-entrancy guard
TMR_NEXT        EQU BIOS_RAM+14     ; 1  round-robin timer allocator
SND_N           EQU BIOS_RAM+15     ; 1  number of sound areas
SND_TBL         EQU BIOS_RAM+16     ; 2  song table
SND_AREA0       EQU BIOS_RAM+18     ; 2  first sound area
RND_SEED        EQU BIOS_RAM+20     ; 2
JOY_RAW         EQU BIOS_RAM+22     ; 1
NOISE_LAST      EQU BIOS_RAM+23     ; 1
SM_W            EQU BIOS_RAM+24     ; semi-mobile object scratch
SM_H            EQU BIOS_RAM+25
SM_FIRST        EQU BIOS_RAM+26
SM_SRC          EQU BIOS_RAM+27     ; 2
SM_DST          EQU BIOS_RAM+29     ; 2
SPR_TMP         EQU BIOS_RAM+31     ; 4
OPT_LIVE        EQU BIOS_RAM+35     ; 1  option screen is showing (joystick readout)
TIMERS          EQU BIOS_RAM+40     ; NTIMERS * 5
NTIMERS         EQU 32
SND_STATE       EQU BIOS_RAM+200    ; MAX_AREAS * 12
MAX_AREAS       EQU 16
DG_F            EQU BIOS_RAM+392    ; 2  diagnostics: frame flags seen
DG_N            EQU BIOS_RAM+394    ; 2  frame-handler runs
DG_L            EQU BIOS_RAM+396    ; 2  POLLER calls (game loop passes)
DG_T            EQU BIOS_RAM+398    ; 2  timer signals delivered
MIR_D0          EQU BIOS_RAM+400    ; 2  name-table mirror scratch
MIR_N           EQU BIOS_RAM+402    ; 2
MIR_SRC         EQU BIOS_RAM+404    ; 2
MIR_ST          EQU BIOS_RAM+406    ; 2
MIR_CNT         EQU BIOS_RAM+408    ; 2
MIR_MODE        EQU BIOS_RAM+410    ; 1
MIR_VAL         EQU BIOS_RAM+411    ; 1
BIOS_RAM_LEN    EQU 412

; RAM copies of the two maze name tables (the game reads the maze back to
; steer the cats and the mouse; VRAM reads are not reliable on every card)
SHADOW_A        EQU 7600H           ; mirrors VRAM 1800H-1AFFH
SHADOW_B        EQU 7900H           ; mirrors VRAM 1C00H-1EFFH
SHADOW_LEN      EQU 600H            ; stack lives above, 7C00H-7FFFH

; OS7 RAM locations the game itself reads or writes
VDP_REG0_SHADOW EQU 73C3H
VDP_REG1_SHADOW EQU 73C4H
MUX_SPRITES     EQU 73C7H

; per sound-area state (12 bytes)
S_PTR           EQU 0           ; 2 next note
S_CH            EQU 2           ; 0 = noise, 1-3 = tone channel
S_FREQ          EQU 3           ; 2 10-bit divider (noise: control nibble)
S_ATN           EQU 5           ; attenuation 0-15
S_LEN           EQU 6           ; frames (or freq steps) left
S_FPS           EQU 7           ; freq step period: hi = reload, lo = counter
S_FSTEP         EQU 8           ; signed freq step
S_ASTEP         EQU 9           ; hi = signed atten step, lo = steps left
S_APS           EQU 10          ; atten step period
S_FLAGS         EQU 11          ; bit0 rest, bit1 length counted in freq steps

; =============================================================================
; Start-up / shut-down
; =============================================================================
TEC_START:
    DI
    LD      HL, 0
    ADD     HL, SP
    LD      SP, STACK_TOP
    PUSH    HL                  ; keep MON3's SP until RAM is cleared
    LD      HL, BIOS_RAM
    LD      DE, BIOS_RAM+1
    LD      BC, BIOS_RAM_LEN-1
    LD      (HL), 0
    LDIR
    LD      HL, SHADOW_A
    LD      DE, SHADOW_A+1
    LD      BC, SHADOW_LEN-1
    LD      (HL), 0
    LDIR
    POP     HL
    LD      (MON_SP), HL
    LD      A, R
    LD      (RND_SEED), A
    LD      A, 0ACH
    LD      (RND_SEED+1), A
    LD      A, 0FFH
    LD      (NOISE_LAST), A
    CALL    SND_SILENCE
    LD      BC, 0180H           ; reg 1 = 80H: 16K, display off
    CALL    WRITE_REGISTER
    LD      BC, 0000H           ; reg 0 = 0: graphics mode I
    CALL    WRITE_REGISTER
    IN      A, (VDP_CTRL)       ; clear any pending frame flag
    JP      START               ; into the game

QUIT_TO_MON:                    ; AD key pressed
    CALL    SND_SILENCE
    LD      BC, 0180H           ; blank the screen
    CALL    WRITE_REGISTER
    LD      SP, (MON_SP)
    RET                         ; back to MON3

; =============================================================================
; Frame polling - replaces the VDP NMI
; =============================================================================
VSYNC_POLL:
    PUSH    AF
    IN      A, (VDP_CTRL)       ; reading status also clears the flag
    RLCA
    JR      NC, VP_X
    LD      A, 1
    LD      (FRAME_SEEN), A
 IF DIAG
    PUSH    HL
    LD      HL, (DG_F)
    INC     HL
    LD      (DG_F), HL
    POP     HL
 ENDIF
    LD      A, (IN_TICK)
    OR      A
    JR      NZ, VP_X
    LD      A, (VDP_REG1_SHADOW) ; the game "disables NMI" by clearing IE;
    BIT     5, A                 ; honour that exactly as the Coleco did
    JR      Z, VP_X
    LD      A, 1
    LD      (IN_TICK), A
 IF DIAG
    PUSH    HL
    LD      HL, (DG_N)
    INC     HL
    LD      (DG_N), HL
    POP     HL
 ENDIF
    CALL    NMI                 ; the game's own frame handler
 IF DIAG
    CALL    DIAG_SHOW
 ENDIF
    XOR     A
    LD      (IN_TICK), A
VP_X:
    POP     AF
    RET

 IF DIAG
; DIAG_SHOW: bottom row = frames seen, frame-handler runs, timer signals
; (4 digits), mouse x y, cat 1 x y (decimal).  Only during play.
DIAG_SHOW:
    LD      A, (OPT_LIVE)
    OR      A
    RET     NZ
    PUSH    BC
    PUSH    DE
    PUSH    HL
    LD      HL, (TBL_BASE+4)
    LD      DE, 23*32
    ADD     HL, DE
    EX      DE, HL
    CALL    VDP_SETW
    LD      HL, (DG_F)
    CALL    DG_NUM4
    LD      HL, (DG_N)
    CALL    DG_NUM4
    LD      HL, (DG_T)
    CALL    DG_NUM4
    LD      A, (7112H)          ; mouse x, y
    CALL    DG_NUM3
    LD      A, (7114H)
    CALL    DG_NUM3
    LD      A, (7121H)          ; cat 1 x, y
    CALL    DG_NUM3
    LD      A, (7123H)
    CALL    DG_NUM3
    POP     HL
    POP     DE
    POP     BC
    RET

DG_NUM3:                        ; A in decimal, 3 digits, then a blank
    LD      L, A
    LD      H, 0
    JR      DG_N3
DG_NUM4:                        ; HL mod 10000 in decimal, 4 digits, then a blank
    LD      DE, 10000
DGN4:
    OR      A
    SBC     HL, DE
    JR      NC, DGN4
    ADD     HL, DE
    LD      DE, 1000
    CALL    DG_DIG
DG_N3:
    LD      DE, 100
    CALL    DG_DIG
    LD      DE, 10
    CALL    DG_DIG
    LD      A, L
    ADD     A, '0'
    OUT     (VDP_DATA), A
    EX      (SP), HL            ; spacing between VDP writes
    EX      (SP), HL
    XOR     A                   ; tile 0 is blank during play
    OUT     (VDP_DATA), A
    RET
DG_DIG:
    LD      B, '0'
DGD1:
    OR      A
    SBC     HL, DE
    JR      C, DGD2
    INC     B
    JR      DGD1
DGD2:
    ADD     HL, DE
    LD      A, B
    OUT     (VDP_DATA), A
    RET
 ENDIF

; =============================================================================
; VDP primitives
; =============================================================================
VDP_SETW:                       ; DE = VRAM address for writing
    LD      A, E
    OUT     (VDP_CTRL), A
    LD      A, D
    AND     3FH
    OR      40H
    OUT     (VDP_CTRL), A
    RET

VDP_SETR:                       ; DE = VRAM address for reading
    LD      A, E
    OUT     (VDP_CTRL), A
    LD      A, D
    AND     3FH
    OUT     (VDP_CTRL), A
    EX      (SP), HL            ; give the VDP time to pre-fetch
    EX      (SP), HL
    RET

VDP_OUTBLK:                     ; HL = source, BC = count. HL advanced.
    LD      A, B
    OR      C
    RET     Z
VOB1:
    LD      A, (HL)
    OUT     (VDP_DATA), A
    INC     HL
    DEC     BC
    LD      A, B
    OR      C
    JR      NZ, VOB1            ; 50 T-states per byte: safe at any time
    RET

VDP_INBLK:                      ; HL = destination, BC = count. HL advanced.
    LD      A, B
    OR      C
    RET     Z
VIB1:
    IN      A, (VDP_DATA)
    LD      (HL), A
    INC     HL
    DEC     BC
    LD      A, B
    OR      C
    JR      NZ, VIB1
    RET

; WRITE_VRAM: HL = source, DE = VRAM address, BC = count
WRITE_VRAM:
    PUSH    BC
    PUSH    DE
    PUSH    HL
    CALL    MIR_COPY
    CALL    VDP_SETW
    CALL    VDP_OUTBLK
    POP     HL
    POP     DE
    POP     BC
    RET

; FILL_VRAM: HL = VRAM address, DE = count, A = value
FILL_VRAM:
    PUSH    AF
    PUSH    BC
    PUSH    DE
    PUSH    HL
    LD      C, A
    EX      DE, HL
    PUSH    BC
    LD      B, H
    LD      C, L
    CALL    MIR_FILL            ; DE = address, BC = count, A = value
    POP     BC
    CALL    VDP_SETW
FV1:
    LD      A, H
    OR      L
    JR      Z, FV2
    LD      A, C
    OUT     (VDP_DATA), A
    DEC     HL
    JR      FV1
FV2:
    POP     HL
    POP     DE
    POP     BC
    POP     AF
    RET

; WRITE_REGISTER: B = register, C = value
WRITE_REGISTER:
    PUSH    AF
    LD      A, B
    OR      A
    JR      NZ, WRG1
    LD      A, C
    LD      (VDP_REG0_SHADOW), A
    JR      WRG3
WRG1:
    CP      1
    JR      NZ, WRG3
    LD      A, C
    LD      (VDP_REG1_SHADOW), A
    BIT     6, A
    JR      NZ, WRG2
    XOR     A
    LD      (OPT_LIVE), A       ; screen blanked: option screen is gone
    LD      A, C
WRG2:
    AND     0DFH                ; never let the VDP drive its interrupt line
    JR      WRG4
WRG3:
    LD      A, C
WRG4:
    OUT     (VDP_CTRL), A
    LD      A, B
    AND     07H
    OR      80H
    OUT     (VDP_CTRL), A
    POP     AF
    RET

; READ_REGISTER: A = VDP status
READ_REGISTER:
    IN      A, (VDP_CTRL)
    RET

; INIT_TABLE: A = table code, HL = VRAM base
;   0 sprite attributes, 1 sprite patterns, 2 names, 3 patterns, 4 colours
INIT_TABLE:
    PUSH    AF
    PUSH    BC
    PUSH    DE
    PUSH    HL
    AND     7
    CP      5
    JR      NC, IT_X
    LD      C, A
    LD      B, 0
    EX      DE, HL              ; DE = base
    LD      HL, TBL_BASE
    ADD     HL, BC
    ADD     HL, BC
    LD      (HL), E
    INC     HL
    LD      (HL), D
    LD      HL, IT_SHIFT
    ADD     HL, BC
    LD      A, (HL)             ; shift count
    LD      HL, IT_REG
    ADD     HL, BC
    LD      C, (HL)             ; register number
    EX      DE, HL              ; HL = base
    LD      B, A
IT1:
    SRL     H
    RR      L
    DJNZ    IT1
    LD      B, C
    LD      C, L
    CALL    WRITE_REGISTER
IT_X:
    POP     HL
    POP     DE
    POP     BC
    POP     AF
    RET

IT_SHIFT:   DB 7, 11, 10, 11, 6
IT_REG:     DB 5, 6, 2, 4, 3
ITEM_SHIFT: DB 2, 3, 0, 3, 0        ; log2 of item size per table code

; VADDR: A = code, DE = item index, IY = item count
;        -> DE = VRAM address, BC = byte count.  HL preserved.
VADDR:
    PUSH    HL
    AND     7
    LD      C, A
    LD      B, 0
    LD      HL, TBL_BASE
    ADD     HL, BC
    ADD     HL, BC
    LD      A, (HL)
    INC     HL
    LD      H, (HL)
    LD      L, A
    PUSH    HL                  ; table base
    LD      HL, ITEM_SHIFT
    ADD     HL, BC
    LD      A, (HL)
    PUSH    IY
    POP     BC
    OR      A
    JR      Z, VA2
VA1:
    SLA     E
    RL      D
    SLA     C
    RL      B
    DEC     A
    JR      NZ, VA1
VA2:
    POP     HL
    ADD     HL, DE
    EX      DE, HL
    POP     HL
    RET

; PUT_VRAM: A = code, DE = first item, HL = source, IY = item count.
;           Returns HL advanced past the data.
PUT_VRAM:
    PUSH    BC
    PUSH    DE
    CALL    VADDR
    CALL    MIR_COPY
    CALL    VDP_SETW
    CALL    VDP_OUTBLK
    POP     DE
    POP     BC
    RET

; GET_VRAM: A = code, DE = first item, HL = destination, IY = item count.
;           Returns HL advanced past the data.
GET_VRAM:
    PUSH    BC
    PUSH    DE
    CALL    VADDR
    CALL    SH_FIND             ; maze data? answer from the RAM copy
    JR      C, GV_REAL
    EX      DE, HL              ; DE = destination
    LD      HL, (MIR_ST)
    LDIR
    EX      DE, HL              ; HL = destination, advanced
    JR      GV_X
GV_REAL:
    CALL    VDP_SETR
    CALL    VDP_INBLK
GV_X:
    POP     DE
    POP     BC
    RET

; -----------------------------------------------------------------------------
; Name-table mirror.  REGIONS lists VRAM ranges (300H bytes) and their copies.
; -----------------------------------------------------------------------------
REGIONS:
    DW 1800H, SHADOW_A
    DW 1C00H, SHADOW_B
    DW 0

; SH_FIND: DE = VRAM address, BC = count.  If the whole range is inside a
; mirrored region: carry clear, (MIR_ST) = address in the copy.  Else carry set.
; Preserves BC, DE, HL, IX.
SH_FIND:
    PUSH    HL
    PUSH    IX
    LD      A, B
    OR      C
    JR      Z, SF_NO
    LD      IX, REGIONS
SF1:
    LD      L, (IX+0)
    LD      H, (IX+1)
    LD      A, H
    OR      L
    JR      Z, SF_NO
    PUSH    DE
    EX      DE, HL              ; HL = address, DE = region start
    OR      A
    SBC     HL, DE              ; offset into region
    JR      C, SF_NEXT
    PUSH    HL
    ADD     HL, BC
    LD      DE, 301H
    OR      A
    SBC     HL, DE              ; carry if offset + count <= 300H
    POP     HL
    JR      NC, SF_NEXT
    LD      E, (IX+2)
    LD      D, (IX+3)
    ADD     HL, DE
    LD      (MIR_ST), HL
    POP     DE
    POP     IX
    POP     HL
    OR      A
    RET
SF_NEXT:
    POP     DE
    PUSH    DE
    LD      DE, 4
    ADD     IX, DE
    POP     DE
    JR      SF1
SF_NO:
    POP     IX
    POP     HL
    SCF
    RET

; MIR_COPY: DE = VRAM address, BC = count, HL = source.
; MIR_FILL: DE = VRAM address, BC = count, A = value.
; Copy whatever part of the write falls inside a mirrored region.
; All registers preserved.
MIR_COPY:
    PUSH    AF
    XOR     A
    JR      MIR_GO
MIR_FILL:
    PUSH    AF
    LD      (MIR_VAL), A
    LD      A, 1
MIR_GO:
    LD      (MIR_MODE), A
    PUSH    BC
    PUSH    DE
    PUSH    HL
    PUSH    IX
    LD      (MIR_D0), DE
    LD      (MIR_N), BC
    LD      (MIR_SRC), HL
    LD      IX, REGIONS
MG1:
    LD      L, (IX+0)
    LD      H, (IX+1)
    LD      A, H
    OR      L
    JP      Z, MG_X
    LD      DE, (MIR_D0)        ; start = max(address, region)
    PUSH    HL
    OR      A
    SBC     HL, DE
    POP     HL
    JR      NC, MG2
    EX      DE, HL
MG2:
    LD      (MIR_ST), HL
    LD      HL, (MIR_D0)        ; end = min(address + count, region + 300H)
    LD      DE, (MIR_N)
    ADD     HL, DE
    PUSH    HL
    LD      L, (IX+0)
    LD      H, (IX+1)
    LD      DE, 300H
    ADD     HL, DE
    POP     DE
    PUSH    HL
    OR      A
    SBC     HL, DE
    POP     HL
    JR      C, MG3
    EX      DE, HL
MG3:
    LD      DE, (MIR_ST)        ; count = end - start
    OR      A
    SBC     HL, DE
    JR      C, MG_NEXT
    JR      Z, MG_NEXT
    LD      (MIR_CNT), HL
    LD      HL, (MIR_ST)        ; copy address = copy base + (start - region)
    LD      E, (IX+0)
    LD      D, (IX+1)
    OR      A
    SBC     HL, DE
    LD      E, (IX+2)
    LD      D, (IX+3)
    ADD     HL, DE
    EX      DE, HL              ; DE = destination in the copy
    LD      BC, (MIR_CNT)
    LD      A, (MIR_MODE)
    OR      A
    JR      NZ, MG_FILL
    LD      HL, (MIR_ST)        ; source = source + (start - address)
    PUSH    DE
    LD      DE, (MIR_D0)
    OR      A
    SBC     HL, DE
    LD      DE, (MIR_SRC)
    ADD     HL, DE
    POP     DE
    LDIR
    JR      MG_NEXT
MG_FILL:
    EX      DE, HL
    LD      A, (MIR_VAL)
    LD      (HL), A
    DEC     BC
    LD      A, B
    OR      C
    JR      Z, MG_NEXT
    LD      D, H
    LD      E, L
    INC     DE
    LDIR
MG_NEXT:
    LD      DE, 4
    ADD     IX, DE
    JP      MG1
MG_X:
    POP     IX
    POP     HL
    POP     DE
    POP     BC
    POP     AF
    RET

; INIT_WRITER / WRITER: OS7 queues VRAM writes made while the NMI could
; interrupt them.  Polling never interrupts a VRAM access, so nothing to do.
INIT_WRITER:
WRITER:
    RET

; =============================================================================
; Sprites
; =============================================================================
; INIT_SPR_NM_TBL: A = count.  Sprite order table = 0,1,2...
INIT_SPR_NM_TBL:
    PUSH    AF
    PUSH    BC
    PUSH    HL
    OR      A
    JR      Z, ISN_X
    LD      B, A
    LD      HL, SPRITE_ORDER_TABLE
    XOR     A
ISN1:
    LD      (HL), A
    INC     HL
    INC     A
    DJNZ    ISN1
ISN_X:
    POP     HL
    POP     BC
    POP     AF
    RET

; WR_SPR_NM_TBL: A = count.  Copy the RAM sprite table to VRAM in the
; order given by the sprite order table (the game rotates it to flicker).
WR_SPR_NM_TBL:
    PUSH    AF
    PUSH    BC
    PUSH    DE
    PUSH    HL
    OR      A
    JR      Z, WSN_X
    CP      33
    JR      C, WSN0
    LD      A, 32
WSN0:
    LD      B, A
    LD      DE, (TBL_BASE)
    CALL    VDP_SETW
    LD      DE, SPRITE_ORDER_TABLE
WSN1:
    LD      A, (DE)
    INC     DE
    AND     1FH
    ADD     A, A
    ADD     A, A
    LD      L, A
    LD      H, 0
    PUSH    BC
    LD      BC, SPRITE_NAME_TABLE
    ADD     HL, BC
    LD      B, 4
WSN2:
    LD      A, (HL)
    OUT     (VDP_DATA), A
    INC     HL
    DJNZ    WSN2
    POP     BC
    DJNZ    WSN1
WSN_X:
    POP     HL
    POP     DE
    POP     BC
    POP     AF
    RET

; =============================================================================
; PUTOBJ: IX = object.  Handles the two object kinds Mouse Trap uses:
;   type 0  semi-mobile: a block of name-table characters (the maze)
;   type 2/3 sprite:      one 16x16 sprite
; object:   DW graphics, DW status, DB sprite slot
; graphics: DB type, first_name, DW generators, DB count, DW frame0, frame1..
; status:   DB frame, DW x, DW y
; =============================================================================
PUTOBJ:
    PUSH    AF
    PUSH    BC
    PUSH    DE
    PUSH    HL
    PUSH    IX
    PUSH    IY
    LD      L, (IX+0)
    LD      H, (IX+1)           ; HL = graphics
    LD      E, (IX+2)
    LD      D, (IX+3)
    PUSH    DE
    POP     IY                  ; IY = status
    LD      A, (HL)
    AND     0FH
    JR      Z, PO_SEMI
    CP      2
    JR      Z, PO_SPR
    CP      3
    JR      Z, PO_SPR
PO_DONE:
    POP     IY
    POP     IX
    POP     HL
    POP     DE
    POP     BC
    POP     AF
    RET

PO_SPR:
    INC     HL
    LD      C, (HL)             ; first sprite pattern name
    DEC     HL
    LD      A, (IY+0)
    CALL    FRAME_PTR
    LD      B, (HL)             ; colour
    INC     HL
    LD      A, (HL)
    ADD     A, C
    LD      C, A                ; pattern name
    LD      E, (IY+3)           ; y
    LD      D, (IY+1)           ; x
    LD      A, (IY+2)
    OR      (IY+4)
    JR      Z, PS1
    LD      E, 0C3H             ; off the 256x256 page: hide it
PS1:
    LD      A, E
    CP      0D0H                ; D0 would end the sprite list
    JR      NZ, PS2
    INC     E
PS2:
    LD      HL, SPR_TMP
    LD      (HL), E
    INC     HL
    LD      (HL), D
    INC     HL
    LD      (HL), C
    INC     HL
    LD      (HL), B
    LD      A, (IX+4)           ; sprite slot
    AND     1FH
    ADD     A, A
    ADD     A, A
    LD      L, A
    LD      H, 0
    LD      A, (MUX_SPRITES)
    OR      A
    JR      Z, PS_VRAM
    LD      DE, SPRITE_NAME_TABLE  ; multiplexed: RAM copy, sent each frame
    ADD     HL, DE
    EX      DE, HL
    LD      HL, SPR_TMP
    LD      BC, 4
    LDIR
    JR      PO_DONE
PS_VRAM:
    LD      DE, (TBL_BASE)
    ADD     HL, DE
    EX      DE, HL
    CALL    VDP_SETW
    LD      HL, SPR_TMP
    LD      BC, 4
    CALL    VDP_OUTBLK
    JR      PO_DONE

PO_SEMI:
    INC     HL
    LD      A, (HL)
    LD      (SM_FIRST), A
    DEC     HL
    LD      A, (IY+0)
    CALL    FRAME_PTR           ; HL = frame: DB width, height, names...
    LD      A, (HL)
    LD      (SM_W), A
    INC     HL
    LD      A, (HL)
    LD      (SM_H), A
    INC     HL
    LD      (SM_SRC), HL
    LD      A, (IY+3)           ; row = y / 8
    AND     0F8H
    LD      L, A
    LD      H, 0
    ADD     HL, HL
    ADD     HL, HL              ; row * 32
    LD      A, (IY+1)           ; column = x / 8
    SRL     A
    SRL     A
    SRL     A
    LD      E, A
    LD      D, 0
    ADD     HL, DE
    LD      DE, (TBL_BASE+4)    ; name table
    ADD     HL, DE
    LD      (SM_DST), HL
SM_ROW:
    LD      DE, (SM_DST)
    CALL    VDP_SETW
    LD      HL, (SM_SRC)
    LD      A, (SM_W)
    LD      B, A
    LD      A, (SM_FIRST)
    LD      C, A
SM_COL:
    LD      A, (HL)
    ADD     A, C
    OUT     (VDP_DATA), A
    INC     HL
    DJNZ    SM_COL
    PUSH    HL                  ; mirror this row into the maze copy
    LD      DE, (SM_DST)
    LD      A, (SM_W)
    LD      C, A
    LD      B, 0
    CALL    SH_FIND
    JR      C, SMM_X
    OR      A
    SBC     HL, BC              ; HL = start of this row's source
    LD      DE, (MIR_ST)
    LD      B, C
    LD      A, (SM_FIRST)
    LD      C, A
SMM1:
    LD      A, (HL)
    ADD     A, C
    LD      (DE), A
    INC     HL
    INC     DE
    DJNZ    SMM1
SMM_X:
    POP     HL
    LD      (SM_SRC), HL
    LD      HL, (SM_DST)
    LD      DE, 32
    ADD     HL, DE
    LD      (SM_DST), HL
    LD      HL, SM_H
    DEC     (HL)
    JR      NZ, SM_ROW
    JP      PO_DONE

; FRAME_PTR: HL = graphics, A = frame -> HL = frame data
FRAME_PTR:
    PUSH    DE
    LD      DE, 5
    ADD     HL, DE
    ADD     A, A
    LD      E, A
    LD      D, 0
    ADD     HL, DE
    LD      A, (HL)
    INC     HL
    LD      H, (HL)
    LD      L, A
    POP     DE
    RET

; =============================================================================
; Timers.  Entry (5 bytes): flags, count(2), reload(2)
;   flags: bit7 in use, bit6 repeating, bit0 timed out
; =============================================================================
INIT_TIMER:                     ; HL, DE (OS7 table pointers) are ignored
    PUSH    AF
    PUSH    BC
    PUSH    HL
    LD      HL, TIMERS
    LD      B, NTIMERS*5
IT_CLR:
    LD      (HL), 0
    INC     HL
    DJNZ    IT_CLR
    XOR     A
    LD      (TMR_NEXT), A
    POP     HL
    POP     BC
    POP     AF
    RET

TMR_ADDR:                       ; A = timer number -> IX = entry
    PUSH    DE
    AND     NTIMERS-1
    LD      E, A
    ADD     A, A
    ADD     A, A
    ADD     A, E
    LD      E, A
    LD      D, 0
    LD      IX, TIMERS
    ADD     IX, DE
    POP     DE
    RET

; REQUEST_SIGNAL: HL = frames, A = 0 one-shot / else repeating
;                 -> A = timer number
REQUEST_SIGNAL:
    PUSH    BC
    PUSH    DE
    PUSH    HL
    PUSH    IX
    LD      C, A
    LD      A, H
    OR      L
    JR      NZ, RQ0
    INC     HL                  ; a count of 0 means "next frame"
RQ0:
    LD      A, (TMR_NEXT)       ; round robin: a stale FREE_SIGNAL is
    LD      B, NTIMERS          ; unlikely to hit a freshly reused slot
RQ1:
    LD      E, A
    CALL    TMR_ADDR
    BIT     7, (IX+0)
    JR      Z, RQ2
    LD      A, E
    INC     A
    AND     NTIMERS-1
    DJNZ    RQ1
RQ2:
    LD      A, C
    OR      A
    LD      A, 80H
    JR      Z, RQ3
    LD      A, 0C0H
RQ3:
    LD      (IX+0), A
    LD      (IX+1), L
    LD      (IX+2), H
    LD      (IX+3), L
    LD      (IX+4), H
    LD      A, E
    INC     A
    AND     NTIMERS-1
    LD      (TMR_NEXT), A
    LD      A, E
    POP     IX
    POP     HL
    POP     DE
    POP     BC
    RET

; TEST_SIGNAL: A = timer -> A = 1/NZ if it has timed out, else A = 0/Z.
; A one-shot timer is released once it has been reported.
TEST_SIGNAL:
    CALL    VSYNC_POLL          ; every busy-wait in the game comes here
    PUSH    IX
    CALL    TMR_ADDR
    LD      A, (IX+0)
    BIT     7, A
    JR      Z, TS_NO
    BIT     0, A
    JR      Z, TS_NO
    RES     0, A
    BIT     6, A
    JR      NZ, TS1
    XOR     A
TS1:
    LD      (IX+0), A
    POP     IX
 IF DIAG
    PUSH    HL
    LD      HL, (DG_T)
    INC     HL
    LD      (DG_T), HL
    POP     HL
 ENDIF
    LD      A, 1
    OR      A
    RET
TS_NO:
    POP     IX
    XOR     A
    RET

; FREE_SIGNAL: A = timer
FREE_SIGNAL:
    PUSH    AF
    PUSH    IX
    CALL    TMR_ADDR
    LD      (IX+0), 0
    POP     IX
    POP     AF
    RET

; TIME_MGR: once per frame
TIME_MGR:
    PUSH    AF
    PUSH    BC
    PUSH    DE
    PUSH    HL
    PUSH    IX
    LD      IX, TIMERS
    LD      DE, 5
    LD      B, NTIMERS
TM1:
    BIT     7, (IX+0)
    JR      Z, TM_NEXT
    LD      L, (IX+1)
    LD      H, (IX+2)
    LD      A, H
    OR      L
    JR      Z, TM_NEXT          ; one-shot already timed out
    DEC     HL
    LD      A, H
    OR      L
    JR      NZ, TM_STORE
    SET     0, (IX+0)
    BIT     6, (IX+0)
    JR      Z, TM_STORE
    LD      L, (IX+3)
    LD      H, (IX+4)
TM_STORE:
    LD      (IX+1), L
    LD      (IX+2), H
TM_NEXT:
    ADD     IX, DE
    DJNZ    TM1
    POP     IX
    POP     HL
    POP     DE
    POP     BC
    POP     AF
    RET

; RAND_GEN: A = pseudo-random byte (16-bit xorshift)
RAND_GEN:
    PUSH    HL
    LD      HL, (RND_SEED)
    LD      A, H
    RRA
    LD      A, L
    RRA
    XOR     H
    LD      H, A
    LD      A, L
    RRA
    LD      A, H
    RRA
    XOR     L
    LD      L, A
    XOR     H
    LD      H, A
    LD      (RND_SEED), HL
    POP     HL
    RET

; =============================================================================
; Controllers: TEC-1G joystick + hex keypad -> ColecoVision controller buffer
;   +2 fire  +3 joystick (1 N, 2 E, 4 S, 8 W)  +6 keypad (0-11, 0FH = none)
;   player 2 at +7/+8/+11 mirrors player 1 (two-player games alternate turns)
; Keypad: 0-9 as Coleco keys, A = *, B = #, GO = *, AD = quit to MON3.
; Fire acts as keypad 5 (turn into a dog) when no key is held.
; =============================================================================
POLLER:
    PUSH    AF
    PUSH    BC
    PUSH    DE
    PUSH    HL
    PUSH    IX
    PUSH    IY
 IF DIAG
    LD      HL, (DG_L)
    INC     HL
    LD      (DG_L), HL
 ENDIF
    CALL    VSYNC_POLL
    LD      A, (FRAME_SEEN)     ; read the hardware once per video frame
    OR      A
    JR      Z, PL_X
    XOR     A
    LD      (FRAME_SEEN), A
    CALL    JOY_READ
    LD      (JOY_RAW), A
    LD      C, MON_SCANKEYS
    RST     10H
    LD      B, 0FH
    JR      NZ, PL_KEYDONE
    CP      13H                 ; AD
    JP      Z, QUIT_TO_MON
    CP      0CH
    JR      C, PL_KEY
    CP      12H                 ; GO
    JR      NZ, PL_KEYDONE
    LD      A, 0AH
PL_KEY:
    LD      B, A
PL_KEYDONE:
    LD      A, (JOY_RAW)
    AND     JOY_FIRE_MASK       ; any fire button
    LD      C, 0
    JR      Z, PL_NOFIRE
    LD      C, 40H
    LD      A, (OPT_LIVE)       ; on the option screen fire is not a key
    OR      A
    JR      NZ, PL_NOFIRE
    LD      A, B
    CP      0FH
    JR      NZ, PL_NOFIRE
    LD      B, 5
PL_NOFIRE:
    LD      A, (JOY_RAW)
    AND     0FH
    LD      E, A
    LD      D, 0
    LD      HL, JOY_MAP
    ADD     HL, DE
    LD      A, (HL)
    LD      IX, CONTROLLER_BUFFER
    LD      (IX+3), A
    LD      (IX+8), A
    LD      (IX+2), C
    LD      (IX+7), C
    LD      (IX+6), B
    LD      (IX+11), B
    LD      A, (OPT_LIVE)
    OR      A
    CALL    NZ, JOY_SHOW
PL_X:
    POP     IY
    POP     IX
    POP     HL
    POP     DE
    POP     BC
    POP     AF
    RET

; JOY_READ: A = joystick bits, active high (1 = pressed).
; Like the TEC-1G diagnostics ROM, re-read the port until it gives the same
; value 8 times running, so the matrix lines have settled.
JOY_READ:
    PUSH    BC
    PUSH    DE
    PUSH    HL
    LD      BC, JOY_PORT
    LD      D, 64               ; give up after 64 changes (never hang)
JR_RESET:
    IN      E, (C)
    LD      H, 8
JR_LOOP:
    IN      A, (C)
    CP      E
    JR      NZ, JR_CHANGED
    DEC     H
    JR      NZ, JR_LOOP
JR_DONE:
    LD      A, E
    CPL
    POP     HL
    POP     DE
    POP     BC
    RET
JR_CHANGED:
    DEC     D
    JR      NZ, JR_RESET
    LD      E, A
    JR      JR_DONE

; JOY_SHOW: live joystick readout on the option screen's bottom line
JOY_SHOW:
    LD      DE, (TBL_BASE+4)
    LD      HL, 23*32+2
    ADD     HL, DE
    EX      DE, HL
    CALL    VDP_SETW
    LD      HL, JS_TEXT
JS1:
    LD      A, (HL)
    INC     HL
    OR      A
    JR      Z, JS2
    OUT     (VDP_DATA), A
    JR      JS1
JS2:
    LD      A, (JOY_RAW)
    LD      C, A
    RRCA
    RRCA
    RRCA
    RRCA
    CALL    JS_HEX
    LD      A, C
    CALL    JS_HEX
    LD      HL, JS_NAMES
    LD      B, 4
JS3:
    LD      A, ' '
    OUT     (VDP_DATA), A
    LD      A, (HL)
    RRC     C
    JR      C, JS4
    LD      A, '-'
JS4:
    OUT     (VDP_DATA), A
    INC     HL
    DJNZ    JS3
    LD      A, ' '
    OUT     (VDP_DATA), A
    LD      A, C                ; C has rotated 4 places: fire bits now 0-2
    AND     07H
    LD      A, 'F'
    JR      NZ, JS5
    LD      A, '-'
JS5:
    OUT     (VDP_DATA), A
    RET

JS_HEX:
    AND     0FH
    ADD     A, 90H
    DAA
    ADC     A, 40H
    DAA
    NOP                         ; keep VDP writes at least 29 T-states apart
    OUT     (VDP_DATA), A
    RET

JS_TEXT:    DB "JOYSTICK TEST  ",0
JS_NAMES:   DB "UDLR"

JOY_MAP:        ; index: joystick bits (1 up, 2 down, 4 left, 8 right)
    DB 0, 1, 4, 5, 8, 9, 12, 13, 2, 3, 6, 7, 10, 11, 14, 15

; =============================================================================
; GAME_OPT: the game option screen (the Coleco BIOS drew its own; this one
; also loads the font that the game's score and messages rely on)
; =============================================================================
GAME_OPT:
    PUSH    AF
    PUSH    BC
    PUSH    DE
    PUSH    HL
    LD      BC, 0180H           ; blank while drawing
    CALL    WRITE_REGISTER
    LD      BC, 0000H
    CALL    WRITE_REGISTER
    LD      A, 3
    LD      HL, 0000H
    CALL    INIT_TABLE
    LD      A, 2
    LD      HL, 1800H
    CALL    INIT_TABLE
    LD      A, 4
    LD      HL, 2000H
    CALL    INIT_TABLE
    XOR     A
    LD      HL, 1B00H
    CALL    INIT_TABLE
    LD      A, 1
    LD      HL, 3800H
    CALL    INIT_TABLE
    LD      HL, FONT_DATA       ; characters 20H-5FH
    LD      DE, 0100H
    LD      BC, 0200H
    CALL    WRITE_VRAM
    LD      HL, 2000H
    LD      DE, 32
    LD      A, 0F0H             ; white on the backdrop
    CALL    FILL_VRAM
    LD      HL, 2006H           ; digits in yellow
    LD      DE, 2
    LD      A, 0B0H
    CALL    FILL_VRAM
    LD      HL, 1800H
    LD      DE, 768
    LD      A, ' '
    CALL    FILL_VRAM
    LD      HL, 1B00H
    LD      DE, 128
    LD      A, 0D0H
    CALL    FILL_VRAM
    LD      HL, OPT_TEXT
GO1:
    LD      E, (HL)
    INC     HL
    LD      D, (HL)
    INC     HL
    LD      A, D
    OR      E
    JR      Z, GO3
    CALL    VDP_SETW
GO2:
    LD      A, (HL)
    INC     HL
    OR      A
    JR      Z, GO1
    OUT     (VDP_DATA), A
    JR      GO2
GO3:
    LD      BC, 01C2H           ; display on
    CALL    WRITE_REGISTER
    LD      A, 1
    LD      (OPT_LIVE), A       ; show the joystick readout until play starts
    POP     HL
    POP     DE
    POP     BC
    POP     AF
    RET

OPT_TEXT:
    DW 1800H+2*32+11
    DB "MOUSE TRAP",0
    DW 1800H+4*32+5
    DB "TEC-1G  TMS9918 EDITION",0
    DW 1800H+7*32+2
    DB "PRESS A KEY TO SELECT GAME",0
    DW 1800H+9*32+4
    DB "1 = SKILL 1  ONE PLAYER",0
    DW 1800H+10*32+4
    DB "2 = SKILL 2  ONE PLAYER",0
    DW 1800H+11*32+4
    DB "3 = SKILL 3  ONE PLAYER",0
    DW 1800H+12*32+4
    DB "4 = SKILL 4  ONE PLAYER",0
    DW 1800H+13*32+4
    DB "5 = SKILL 1  TWO PLAYERS",0
    DW 1800H+14*32+4
    DB "6 = SKILL 2  TWO PLAYERS",0
    DW 1800H+15*32+4
    DB "7 = SKILL 3  TWO PLAYERS",0
    DW 1800H+16*32+4
    DB "8 = SKILL 4  TWO PLAYERS",0
    DW 1800H+18*32+2
    DB "JOYSTICK   MOVE THE MOUSE",0
    DW 1800H+19*32+2
    DB "1 2 3      SWING THE DOORS",0
    DW 1800H+20*32+2
    DB "5 OR FIRE  TURN INTO A DOG",0
    DW 1800H+21*32+2
    DB "A OR GO    PLAY AGAIN",0
    DW 1800H+22*32+2
    DB "AD         QUIT TO MON3",0
    DW 0

; =============================================================================
; Sound.  Mouse Trap's music is in the OS7 note format:
;   header CC.TTTTT  CC = channel (0 noise, 1-3 tone)
;     bit5 set   : rest, bits 4-0 = frames
;     bit4 set   : end of song (bit3 set = repeat from the start)
;     else bits 1-0 = type: bit0 frequency sweep, bit1 attenuation sweep
;   tone : hdr, freq lo, atn<<4|freq hi, length, [fps, fstep], [astep, aps]
;   noise: hdr, atn<<4|ctrl,            length, [fps, fstep], [astep, aps]
; Song table entries: DW song data, DW sound area (10 bytes, byte 0 = FF idle)
; The song timing is always tracked (the game waits for songs to finish);
; the SN76489 is only written when SOUND_CHIP = 1.
; =============================================================================

; SOUND_INIT: B = number of sound areas, HL = song table
SOUND_INIT:
    PUSH    AF
    PUSH    BC
    PUSH    DE
    PUSH    HL
    LD      (SND_TBL), HL
    LD      A, B
    CP      MAX_AREAS+1
    JR      C, SI0
    LD      A, MAX_AREAS
SI0:
    LD      (SND_N), A
    INC     HL
    INC     HL
    LD      E, (HL)
    INC     HL
    LD      D, (HL)
    LD      (SND_AREA0), DE
    EX      DE, HL
    OR      A
    JR      Z, SI3
    LD      B, A
SI1:
    LD      (HL), 0FFH
    INC     HL
    LD      C, 9
SI2:
    LD      (HL), 0
    INC     HL
    DEC     C
    JR      NZ, SI2
    DJNZ    SI1
SI3:
    LD      (HL), 0
    CALL    SND_SILENCE
    POP     HL
    POP     DE
    POP     BC
    POP     AF
    RET

; PLAY_IT: B = song number (1-based).  A song already playing is left alone.
PLAY_IT:
    PUSH    AF
    PUSH    BC
    PUSH    DE
    PUSH    HL
    PUSH    IX
    LD      A, B
    OR      A
    JR      Z, PI_X
    DEC     A
    LD      L, A
    LD      H, 0
    ADD     HL, HL
    ADD     HL, HL
    LD      DE, (SND_TBL)
    ADD     HL, DE
    LD      E, (HL)
    INC     HL
    LD      D, (HL)             ; DE = song data
    INC     HL
    LD      A, (HL)
    INC     HL
    LD      H, (HL)
    LD      L, A                ; HL = sound area
    LD      A, (HL)
    CP      0FFH
    JR      Z, PI_GO
    AND     3FH
    CP      B
    JR      Z, PI_X
PI_GO:
    CALL    AREA_STATE
    JR      C, PI_X
    LD      (HL), B
    LD      (IX+S_PTR), E
    LD      (IX+S_PTR+1), D
    CALL    LOAD_NOTE
PI_X:
    POP     IX
    POP     HL
    POP     DE
    POP     BC
    POP     AF
    RET

; AREA_STATE: HL = sound area -> IX = its state block; carry set if invalid
AREA_STATE:
    PUSH    BC
    PUSH    DE
    PUSH    HL
    LD      DE, (SND_AREA0)
    OR      A
    SBC     HL, DE
    JR      C, AS_BAD
    LD      DE, 10
    LD      B, 0
AS1:
    LD      A, H
    OR      L
    JR      Z, AS2
    OR      A
    SBC     HL, DE
    JR      C, AS_BAD
    INC     B
    JR      AS1
AS2:
    LD      A, (SND_N)
    LD      C, A
    LD      A, B
    CP      C
    JR      NC, AS_BAD
    LD      L, B
    LD      H, 0
    ADD     HL, HL
    ADD     HL, HL
    LD      D, H
    LD      E, L
    ADD     HL, HL
    ADD     HL, DE              ; * 12
    LD      DE, SND_STATE
    ADD     HL, DE
    PUSH    HL
    POP     IX
    POP     HL
    POP     DE
    POP     BC
    OR      A
    RET
AS_BAD:
    POP     HL
    POP     DE
    POP     BC
    SCF
    RET

; SONG_DATA: A = song number -> DE = song data
SONG_DATA:
    PUSH    HL
    DEC     A
    LD      L, A
    LD      H, 0
    ADD     HL, HL
    ADD     HL, HL
    LD      DE, (SND_TBL)
    ADD     HL, DE
    LD      E, (HL)
    INC     HL
    LD      D, (HL)
    POP     HL
    RET

; LOAD_NOTE: IX = state, HL = sound area.  Fetch the next note.
LOAD_NOTE:
    PUSH    BC
    PUSH    DE
    PUSH    HL
    LD      B, 8                ; guard against empty repeating songs
LN_LOOP:
    LD      E, (IX+S_PTR)
    LD      D, (IX+S_PTR+1)
    LD      A, (DE)
    BIT     5, A
    JR      Z, LN_NOTREST
    INC     DE
    LD      (IX+S_PTR), E
    LD      (IX+S_PTR+1), D
    AND     1FH
    JR      Z, LN_NEXT          ; zero-length rest
    LD      (IX+S_LEN), A
    LD      (IX+S_FLAGS), 1
    JP      LN_X
LN_NOTREST:
    BIT     4, A
    JR      Z, LN_NOTE
    BIT     3, A
    JR      Z, LN_END
    LD      A, (HL)             ; repeat from the start
    AND     3FH
    CALL    SONG_DATA
    LD      (IX+S_PTR), E
    LD      (IX+S_PTR+1), D
LN_NEXT:
    DJNZ    LN_LOOP
LN_END:
    LD      (HL), 0FFH
    JP      LN_X
LN_NOTE:
    LD      C, A                ; C = header
    AND     0C0H
    LD      B, A
    LD      A, (HL)
    AND     3FH
    OR      B
    LD      (HL), A             ; channel bits into the area, like OS7
    INC     DE
    XOR     A
    LD      (IX+S_FPS), A
    LD      (IX+S_ASTEP), A
    LD      (IX+S_FLAGS), A
    LD      (IX+S_FREQ+1), A
    LD      A, C
    RLCA
    RLCA
    AND     3
    LD      (IX+S_CH), A
    JR      NZ, LN_TONE
    LD      A, (DE)             ; noise: atn<<4 | control
    INC     DE
    LD      B, A
    AND     0FH
    LD      (IX+S_FREQ), A
    LD      A, B
    RRCA
    RRCA
    RRCA
    RRCA
    AND     0FH
    LD      (IX+S_ATN), A
    LD      A, (DE)
    INC     DE
    LD      (IX+S_LEN), A
    BIT     0, C
    JR      Z, LN_ATN
    INC     DE                  ; frequency sweep means nothing for noise
    INC     DE
    JR      LN_ATN
LN_TONE:
    LD      A, (DE)
    INC     DE
    LD      (IX+S_FREQ), A
    LD      A, (DE)
    INC     DE
    LD      B, A
    AND     03H
    LD      (IX+S_FREQ+1), A
    LD      A, B
    RRCA
    RRCA
    RRCA
    RRCA
    AND     0FH
    LD      (IX+S_ATN), A
    LD      A, (DE)
    INC     DE
    LD      (IX+S_LEN), A
    BIT     0, C
    JR      Z, LN_ATN
    LD      A, (DE)
    INC     DE
    LD      (IX+S_FPS), A
    LD      A, (DE)
    INC     DE
    LD      (IX+S_FSTEP), A
    LD      (IX+S_FLAGS), 2
LN_ATN:
    BIT     1, C
    JR      Z, LN_STORE
    LD      A, (DE)
    INC     DE
    LD      (IX+S_ASTEP), A
    LD      A, (DE)
    INC     DE
    LD      (IX+S_APS), A
LN_STORE:
    LD      (IX+S_PTR), E
    LD      (IX+S_PTR+1), D
LN_X:
    POP     HL
    POP     DE
    POP     BC
    RET

; PLAY_SONGS: once per frame - advance every active song
PLAY_SONGS:
    PUSH    AF
    PUSH    BC
    PUSH    DE
    PUSH    HL
    PUSH    IX
    LD      A, (SND_N)
    OR      A
    JR      Z, PSG_X
    LD      B, A
    LD      HL, (SND_AREA0)
    LD      IX, SND_STATE
PSG1:
    LD      A, (HL)
    CP      0FFH
    JR      Z, PSG2
    AND     3FH
    CALL    NZ, NOTE_TICK
PSG2:
    LD      DE, 10
    ADD     HL, DE
    LD      DE, 12
    ADD     IX, DE
    DJNZ    PSG1
PSG_X:
    POP     IX
    POP     HL
    POP     DE
    POP     BC
    POP     AF
    RET

NOTE_TICK:                      ; IX = state, HL = area
    PUSH    BC
    BIT     0, (IX+S_FLAGS)
    JR      NZ, NT_COUNT        ; rest
    LD      A, (IX+S_ASTEP)
    AND     0FH
    JR      Z, NT_FREQ
    LD      A, (IX+S_APS)
    CALL    STEP_COUNTER
    LD      (IX+S_APS), A
    JR      NC, NT_FREQ
    LD      A, (IX+S_ASTEP)
    DEC     A                   ; one attenuation step used
    LD      (IX+S_ASTEP), A
    SRA     A
    SRA     A
    SRA     A
    SRA     A                   ; signed step
    ADD     A, (IX+S_ATN)
    BIT     7, A
    JR      Z, NT_A1
    XOR     A
NT_A1:
    CP      16
    JR      C, NT_A2
    LD      A, 15
NT_A2:
    LD      (IX+S_ATN), A
NT_FREQ:
    BIT     1, (IX+S_FLAGS)
    JR      Z, NT_COUNT
    LD      A, (IX+S_FPS)
    CALL    STEP_COUNTER
    LD      (IX+S_FPS), A
    JR      NC, NT_X
    LD      A, (IX+S_FSTEP)
    LD      C, A
    RLA
    SBC     A, A
    LD      B, A                ; BC = signed step
    PUSH    HL
    LD      L, (IX+S_FREQ)
    LD      H, (IX+S_FREQ+1)
    ADD     HL, BC
    LD      (IX+S_FREQ), L
    LD      A, H
    AND     03H
    LD      (IX+S_FREQ+1), A
    POP     HL
NT_COUNT:
    LD      A, (IX+S_LEN)
    OR      A
    JR      Z, NT_LOAD
    DEC     A
    LD      (IX+S_LEN), A
    JR      NZ, NT_X
NT_LOAD:
    CALL    LOAD_NOTE
NT_X:
    POP     BC
    RET

; STEP_COUNTER: A = reload<<4 | counter.  Counts down; carry = step now.
STEP_COUNTER:
    LD      C, A
    AND     0FH
    JR      Z, SC_FIRE
    DEC     A
    JR      Z, SC_FIRE
    LD      B, A
    LD      A, C
    AND     0F0H
    OR      B
    RET                         ; carry clear (from AND/OR)
SC_FIRE:
    LD      A, C
    AND     0F0H
    LD      B, A
    RRCA
    RRCA
    RRCA
    RRCA
    OR      B
    SCF
    RET

; SOUND_MAN: once per frame - drive the SN76489 from the song states.
; Later sound areas override earlier ones on a shared channel.
SOUND_MAN:
 IF SOUND_CHIP
    PUSH    AF
    PUSH    BC
    PUSH    DE
    PUSH    HL
    PUSH    IX
    LD      C, 0                ; channel 0 = noise, 1-3 = tone
SMN_CH:
    LD      DE, 0
    LD      A, (SND_N)
    OR      A
    JR      Z, SMN_OUT
    LD      B, A
    LD      HL, (SND_AREA0)
    LD      IX, SND_STATE
SMN1:
    LD      A, (HL)
    CP      0FFH
    JR      Z, SMN2
    AND     3FH
    JR      Z, SMN2
    BIT     0, (IX+S_FLAGS)
    JR      NZ, SMN2
    LD      A, (IX+S_CH)
    CP      C
    JR      NZ, SMN2
    PUSH    IX
    POP     DE
SMN2:
    PUSH    DE
    LD      DE, 10
    ADD     HL, DE
    LD      DE, 12
    ADD     IX, DE
    POP     DE
    DJNZ    SMN1
SMN_OUT:
    LD      A, C
    DEC     A
    AND     3                   ; SN channel: tone 1-3 -> 0-2, noise -> 3
    RRCA
    RRCA
    RRCA                        ; channel << 5
    LD      B, A
    LD      A, D
    OR      E
    JR      NZ, SMN_ON
    LD      A, B
    OR      9FH                 ; silent
    OUT     (SN_PORT), A
    JR      SMN_NEXT
SMN_ON:
    PUSH    DE
    POP     IX
    LD      A, C
    OR      A
    JR      NZ, SMN_TONE
    LD      A, (IX+S_FREQ)      ; noise control - only on change
    AND     07H
    LD      HL, NOISE_LAST
    CP      (HL)
    JR      Z, SMN_ATN
    LD      (HL), A
    OR      0E0H
    OUT     (SN_PORT), A
    JR      SMN_ATN
SMN_TONE:
    LD      A, (IX+S_FREQ)
    AND     0FH
    OR      B
    OR      80H
    OUT     (SN_PORT), A
    LD      L, (IX+S_FREQ)
    LD      H, (IX+S_FREQ+1)
    ADD     HL, HL
    ADD     HL, HL
    ADD     HL, HL
    ADD     HL, HL
    LD      A, H
    AND     3FH
    OUT     (SN_PORT), A
SMN_ATN:
    LD      A, (IX+S_ATN)
    AND     0FH
    OR      B
    OR      90H
    OUT     (SN_PORT), A
SMN_NEXT:
    INC     C
    LD      A, C
    CP      4
    JP      C, SMN_CH
    POP     IX
    POP     HL
    POP     DE
    POP     BC
    POP     AF
 ENDIF
    RET

SND_SILENCE:
 IF SOUND_CHIP
    PUSH    AF
    LD      A, 9FH
    OUT     (SN_PORT), A
    LD      A, 0BFH
    OUT     (SN_PORT), A
    LD      A, 0DFH
    OUT     (SN_PORT), A
    LD      A, 0FFH
    OUT     (SN_PORT), A
    LD      (NOISE_LAST), A
    POP     AF
 ENDIF
    RET

    INCLUDE "font.asm"
