# Mouse Trap for the TEC-1G + TMS9918

Port of the ColecoVision *Mouse Trap* (from Captain Cosmos' disassembly) to the
TEC-1G with a TMS9918A video card, using the TEC-1G joystick port.

## Quick start

Two builds of the same program:

| File                  | Loads at | Run from | Lives in |
|-----------------------|----------|----------|----------|
| `mousetrap.hex/.bin`  | 1000H    | 1000H    | main RAM |
| `mousetrap-8000.hex/.bin` | 8000H | 8000H   | expansion socket |

1. Turn the **PROTECT** DIP switch **off** (the game uses RAM at 7000H-7FFFH).
2. Load the `.hex` with MON3's Intel HEX loader (serial, 4800 8N2), or put the
   `.bin` at its load address.
3. Run from the load address (`GO`).

For the 8000H build the expansion socket needs RAM (32 KB device) with the
right 16 KB bank selected by the Expand switch, before loading. The program
never writes to its own code, so it also runs from an EPROM in that socket.

## Controls

| Input              | Action                                   |
|--------------------|------------------------------------------|
| 1-8 (on the menu)  | 1-4 skill, one player; 5-8 skill, two players |
| Joystick           | Move the mouse                           |
| 1 / 2 / 3          | Swing the red / yellow / blue doors      |
| 5 or Fire          | Turn into a dog (uses a bone)            |
| A or GO            | After GAME OVER: play the same game again |
| B                  | After GAME OVER: back to the menu        |
| AD                 | Quit to MON3                             |

Two-player games alternate turns, so one joystick is enough.

## Hardware settings (top of `os7tec.asm`)

| Setting      | Default | Meaning |
|--------------|---------|---------|
| `VDP_DATA`   | `0BEH`  | TMS9918 data port (MODE low) |
| `VDP_CTRL`   | `0BFH`  | TMS9918 register/status port (MODE high) |
| `SOUND_CHIP` | `0`     | Set to `1` if an SN76489 sound card is fitted |
| `SN_PORT`    | `0FFH`  | SN76489 write port (must be changed if `SOUND_CHIP = 1`) |

- **No interrupt wiring is needed.** The VDP's interrupt output is never
  enabled; the game polls the status register's frame flag instead.
- The joystick (J9) is read directly at port FEH with A11 low, re-reading until
  the value is stable (as the TEC-1G diagnostics ROM does). The keypad is read
  through MON3's `scanKeys` call.
- **Joystick test:** the bottom line of the menu screen shows the joystick
  live (`JOYSTICK TEST xx U D L R F`). If nothing changes there when you move
  the stick, the problem is in the hardware or cable, not the game.
- Without a sound chip the game is silent, but all music timing still runs
  (the game waits for some tunes to finish).

## Memory use

| Range         | Use |
|---------------|-----|
| 1000H-4872H or 8000H-B872H | Program (about 14 KB) |
| 7000H-73FFH   | Game variables (the ColecoVision RAM layout) |
| 7400H-759BH   | Variables for the replacement BIOS |
| 7600H-7BFFH   | RAM copy of the two mazes (VRAM 1800H and 1C00H) |
| 7C00H-7FFFH   | Stack |

## Rebuilding

```
python3 z80asm.py mousetrap-tec1g.asm mousetrap
python3 z80asm.py mousetrap-tec1g-8000.asm mousetrap-8000
```

The two sources differ only in `LOAD_ADDR` near the top; set it to any free
area with 14 KB of room (not 7000H-7FFFH).

`z80asm.py` is a small two-pass assembler included here; the source uses plain
tniASM-style syntax and should also assemble with most Z80 assemblers that
support `INCLUDE`, `IF/ENDIF` and `EQU`.

## What changed from the ColecoVision version

- **`os7tec.asm`** replaces the ColecoVision BIOS calls the game uses: VDP
  access, `PUTOBJ` (the maze and sprites), timers, the sound engine, controller
  polling, and the game-option screen. It is all new code; no Coleco BIOS
  code or font is included (`font.asm` is an original font).
- The cartridge header is gone; `RST 10H/18H/28H/30H` are now `CALL`s, because
  the TEC-1G's RST vectors belong to MON3.
- The game's NMI handler is now a subroutine run once per video frame.
- Three busy-wait loops now poll for the frame, since nothing interrupts them.
- **Disassembly fix:** the source was missing 10 bytes of a 4-entry jump
  table that picks the wall tile between the red and blue doors (it jumped
  into the middle of instructions). The table is rebuilt; the tiles for three
  of the four door states were chosen from the game's own tile set to join up
  with the doors.
- The keypad screen-saver timeout was lengthened to about 1.5 minutes.
- The cats and mouse find their way by reading the maze back from video RAM.
  Some TMS9918 cards don't read back reliably (the game then freezes with only
  the doors working), so maze reads are now answered from a RAM copy that is
  updated on every maze write. The game never depends on reading VRAM.
- Setting `DIAG EQU 1` in `os7tec.asm` shows frame/timer counters and the
  mouse and cat positions on the bottom row (the `-diag` hex files).

## Testing

**Tested working on real TEC-1G hardware** with a TMS9918 video card and a
joystick on J9.

It was also run in a Z80 + TMS9918 emulator: menu, play, doors, dog, bird,
deaths, level completion, game over, two-player mode and quitting all worked,
with no VDP access-timing violations, including with VRAM reads deliberately
broken. If something is off on another setup, check first the VDP port
numbers, and the joystick readout on the menu screen.

Original disassembly by Captain Cosmos, who asks that his work not be sold.
