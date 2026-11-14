#!/usr/bin/env python3
"""Small two-pass Z80 assembler (tniASM-like syntax).

Supports: labels (with or without colon), EQU, ORG, DB/DEFB/DM, DW/DEFW,
DS/DEFS, INCLUDE, IF/ELSE/ENDIF, FNAME/CPU (ignored), full documented Z80
instruction set.  Numbers: 123, 0FFH, $FF, 0xFF, %1010, 'c'.
Output: raw binary from lowest to highest emitted address + Intel HEX + listing.
"""
import re, sys, os

R8 = {'B': 0, 'C': 1, 'D': 2, 'E': 3, 'H': 4, 'L': 5, '(HL)': 6, 'A': 7}
RP = {'BC': 0, 'DE': 1, 'HL': 2, 'SP': 3}
RP2 = {'BC': 0, 'DE': 1, 'HL': 2, 'AF': 3}
CC = {'NZ': 0, 'Z': 1, 'NC': 2, 'C': 3, 'PO': 4, 'PE': 5, 'P': 6, 'M': 7}
ALU = {'ADD': 0, 'ADC': 1, 'SUB': 2, 'SBC': 3, 'AND': 4, 'XOR': 5, 'OR': 6, 'CP': 7}
ROT = {'RLC': 0, 'RRC': 1, 'RL': 2, 'RR': 3, 'SLA': 4, 'SRA': 5, 'SLL': 6, 'SRL': 7}
SIMPLE = {'NOP': [0x00], 'HALT': [0x76], 'DI': [0xF3], 'EI': [0xFB], 'EXX': [0xD9],
          'DAA': [0x27], 'CPL': [0x2F], 'SCF': [0x37], 'CCF': [0x3F], 'RLA': [0x17],
          'RRA': [0x1F], 'RLCA': [0x07], 'RRCA': [0x0F], 'NEG': [0xED, 0x44],
          'RETI': [0xED, 0x4D], 'RETN': [0xED, 0x45], 'LDI': [0xED, 0xA0],
          'LDIR': [0xED, 0xB0], 'LDD': [0xED, 0xA8], 'LDDR': [0xED, 0xB8],
          'CPI': [0xED, 0xA1], 'CPIR': [0xED, 0xB1], 'CPD': [0xED, 0xA9],
          'CPDR': [0xED, 0xB9], 'INI': [0xED, 0xA2], 'INIR': [0xED, 0xB2],
          'IND': [0xED, 0xAA], 'INDR': [0xED, 0xBA], 'OUTI': [0xED, 0xA3],
          'OTIR': [0xED, 0xB3], 'OUTD': [0xED, 0xAB], 'OTDR': [0xED, 0xBB],
          'RLD': [0xED, 0x6F], 'RRD': [0xED, 0x67]}


MNEMONICS = set(SIMPLE) | set(ALU) | set(ROT) | {
    'IF', 'ELSE', 'ENDIF', 'ORG', 'DB', 'DW', 'DS', 'DEFB', 'DEFW', 'DEFS', 'DM', 'INCLUDE', 'EQU',
    'FNAME', 'CPU', 'END', 'IM', 'RST', 'EX', 'PUSH', 'POP', 'JP', 'CALL', 'JR', 'DJNZ', 'RET',
    'INC', 'DEC', 'BIT', 'SET', 'RES', 'IN', 'OUT', 'LD'}


class AsmError(Exception):
    pass


class Assembler:
    def __init__(self):
        self.symbols = {}
        self.pass_no = 1
        self.pc = 0
        self.mem = {}
        self.listing = []
        self.errors = []

    # ---------------------------------------------------------------- exprs
    def eval(self, s):
        s = s.strip()
        if not s:
            raise AsmError('empty expression')
        toks = []
        i = 0
        while i < len(s):
            c = s[i]
            if c.isspace():
                i += 1
                continue
            m = re.match(r"'(.)'", s[i:])
            if m:
                toks.append(str(ord(m.group(1))))
                i += 3
                continue
            m = re.match(r'\$[0-9A-Fa-f]+|0[xX][0-9A-Fa-f]+|[0-9][0-9A-Fa-f]*[Hh](?![0-9A-Za-z_])|%[01]+|[0-9]+(?![0-9A-Za-z_])', s[i:])
            if m:
                t = m.group(0)
                if t[0] == '$':
                    v = int(t[1:], 16)
                elif t[:2].lower() == '0x':
                    v = int(t[2:], 16)
                elif t[-1] in 'hH':
                    v = int(t[:-1], 16)
                elif t[0] == '%':
                    v = int(t[1:], 2)
                else:
                    v = int(t, 10)
                toks.append(str(v))
                i += len(t)
                continue
            if c == '$':
                toks.append(str(self.pc))
                i += 1
                continue
            m = re.match(r'[A-Za-z_.][A-Za-z0-9_.]*', s[i:])
            if m:
                name = m.group(0).upper()
                if name in ('HIGH', 'LOW'):
                    toks.append({'HIGH': '_hi', 'LOW': '_lo'}[name])
                elif name in self.symbols:
                    toks.append(str(self.symbols[name]))
                elif self.pass_no == 1:
                    toks.append('0')
                else:
                    raise AsmError('undefined symbol ' + name)
                i += len(m.group(0))
                continue
            two = s[i:i + 2]
            if two in ('<<', '>>'):
                toks.append(two)
                i += 2
                continue
            if c in '+-*/()&|^~':
                toks.append('//' if c == '/' else c)
                i += 1
                continue
            raise AsmError('bad char in expression: ' + s)
        expr = ' '.join(toks)
        try:
            return int(eval(expr, {'__builtins__': {}},
                            {'_hi': lambda v: (v >> 8) & 255, '_lo': lambda v: v & 255}))
        except Exception as e:
            raise AsmError('bad expression %r (%s)' % (s, e))

    # ---------------------------------------------------------------- operands
    def operand(self, op):
        """Return (kind, value).  kinds: r8, rp, ix, cond-ish name, ind (nn), idx (IX/IY,d), imm"""
        o = op.strip()
        u = o.upper().replace(' ', '')
        if u in R8:
            return ('r8', u)
        if u in ('BC', 'DE', 'HL', 'SP', 'AF', "AF'", 'IX', 'IY', 'I', 'R'):
            return ('reg', u)
        if u in ('(BC)', '(DE)', '(SP)', '(C)'):
            return ('reg', u)
        if u in ('(IX)', '(IY)'):
            return ('idx', (u[1:3], 0))
        m = re.match(r'^\((I[XY])([+-].*)\)$', u)
        if m:
            d = self.eval(m.group(2))
            return ('idx', (m.group(1), d))
        if o.startswith('(') and o.endswith(')') and self._balanced(o[1:-1]):
            return ('ind', o[1:-1])
        return ('imm', o)

    @staticmethod
    def _balanced(s):
        d = 0
        for c in s:
            if c == '(':
                d += 1
            elif c == ')':
                d -= 1
                if d < 0:
                    return False
        return d == 0

    def w(self, v):
        v &= 0xFFFF
        return [v & 255, v >> 8]

    def b(self, v):
        if self.pass_no == 2 and not (-128 <= v <= 255):
            raise AsmError('byte out of range: %d' % v)
        return [v & 255]

    def disp(self, d):
        if self.pass_no == 2 and not (-128 <= d <= 127):
            raise AsmError('index displacement out of range: %d' % d)
        return d & 255

    def rel(self, target, pc):
        d = target - (pc + 2)
        if self.pass_no == 2 and not (-128 <= d <= 127):
            raise AsmError('relative jump out of range (%d)' % d)
        return d & 255

    # ------------------------------------------------------------- encoder
    def encode(self, mn, ops, pc):
        n = len(ops)
        P = [self.operand(o) for o in ops]
        if mn in SIMPLE and n == 0:
            return SIMPLE[mn]
        if mn == 'IM':
            return [0xED, {0: 0x46, 1: 0x56, 2: 0x5E}[self.eval(ops[0])]]
        if mn == 'RST':
            return [0xC7 + (self.eval(ops[0]) & 0x38)]
        if mn == 'EX':
            a = ops[0].upper().replace(' ', '')
            bb = ops[1].upper().replace(' ', '')
            if a == 'DE' and bb == 'HL':
                return [0xEB]
            if a == 'AF':
                return [0x08]
            if a == '(SP)':
                if bb == 'HL':
                    return [0xE3]
                return [0xDD if bb == 'IX' else 0xFD, 0xE3]
        if mn in ('PUSH', 'POP'):
            r = ops[0].upper().strip()
            base = 0xC5 if mn == 'PUSH' else 0xC1
            if r in ('IX', 'IY'):
                return [0xDD if r == 'IX' else 0xFD, base + 0x20]
            return [base + RP2[r] * 16]
        if mn in ('JP', 'CALL'):
            if n == 1:
                k, v = P[0]
                if mn == 'JP' and k == 'r8' and v == '(HL)':
                    return [0xE9]
                if mn == 'JP' and k == 'idx':
                    return [0xDD if v[0] == 'IX' else 0xFD, 0xE9]
                return [0xC3 if mn == 'JP' else 0xCD] + self.w(self.eval(ops[0]))
            c = CC[ops[0].upper().strip()]
            return [(0xC2 if mn == 'JP' else 0xC4) + c * 8] + self.w(self.eval(ops[1]))
        if mn == 'JR':
            if n == 1:
                return [0x18, self.rel(self.eval(ops[0]), pc)]
            c = CC[ops[0].upper().strip()]
            if c > 3:
                raise AsmError('bad JR condition')
            return [0x20 + c * 8, self.rel(self.eval(ops[1]), pc)]
        if mn == 'DJNZ':
            return [0x10, self.rel(self.eval(ops[0]), pc)]
        if mn == 'RET':
            if n == 0:
                return [0xC9]
            return [0xC0 + CC[ops[0].upper().strip()] * 8]
        if mn in ALU:
            if n == 2 and P[0] == ('r8', 'A') and mn in ('ADD', 'ADC', 'SBC', 'SUB', 'AND', 'OR', 'XOR', 'CP'):
                P = P[1:]
                ops = ops[1:]
                n = 1
            if n == 2:
                d = P[0][1]
                s = P[1][1]
                if d == 'HL' and mn in ('ADD', 'ADC', 'SBC'):
                    rp = RP[s]
                    if mn == 'ADD':
                        return [0x09 + rp * 16]
                    return [0xED, (0x4A if mn == 'ADC' else 0x42) + rp * 16]
                if d in ('IX', 'IY') and mn == 'ADD':
                    pre = 0xDD if d == 'IX' else 0xFD
                    rp = 2 if s == d else RP[s]
                    return [pre, 0x09 + rp * 16]
                raise AsmError('bad ALU operands')
            k, v = P[0]
            a = ALU[mn]
            if k == 'r8':
                return [0x80 + a * 8 + R8[v]]
            if k == 'idx':
                return [0xDD if v[0] == 'IX' else 0xFD, 0x86 + a * 8, self.disp(v[1])]
            return [0xC6 + a * 8] + self.b(self.eval(ops[0]))
        if mn in ('INC', 'DEC'):
            k, v = P[0]
            if k == 'r8':
                return [(0x04 if mn == 'INC' else 0x05) + R8[v] * 8]
            if k == 'idx':
                return [0xDD if v[0] == 'IX' else 0xFD, 0x34 if mn == 'INC' else 0x35, self.disp(v[1])]
            if v in ('IX', 'IY'):
                return [0xDD if v == 'IX' else 0xFD, 0x23 if mn == 'INC' else 0x2B]
            return [(0x03 if mn == 'INC' else 0x0B) + RP[v] * 16]
        if mn in ROT or mn in ('BIT', 'SET', 'RES'):
            if mn in ROT:
                base = ROT[mn] * 8
                tgt = P[0]
            else:
                bit = self.eval(ops[0])
                base = {'BIT': 0x40, 'RES': 0x80, 'SET': 0xC0}[mn] + bit * 8
                tgt = P[1]
            k, v = tgt
            if k == 'r8':
                return [0xCB, base + R8[v]]
            if k == 'idx':
                return [0xDD if v[0] == 'IX' else 0xFD, 0xCB, self.disp(v[1]), base + 6]
            raise AsmError('bad operand')
        if mn == 'IN':
            r = ops[0].upper().strip()
            k, v = P[1]
            if v == '(C)':
                return [0xED, 0x40 + R8[r] * 8]
            return [0xDB] + self.b(self.eval(v))
        if mn == 'OUT':
            k, v = P[0]
            if v == '(C)':
                return [0xED, 0x41 + R8[ops[1].upper().strip()] * 8]
            return [0xD3] + self.b(self.eval(v))
        if mn == 'LD':
            return self.enc_ld(ops, P)
        raise AsmError('unknown instruction %s %s' % (mn, ','.join(ops)))

    def enc_ld(self, ops, P):
        (dk, dv), (sk, sv) = P
        if dk == 'r8' and sk == 'r8':
            if dv == '(HL)' and sv == '(HL)':
                raise AsmError('LD (HL),(HL)')
            return [0x40 + R8[dv] * 8 + R8[sv]]
        if dk == 'r8' and sk == 'idx':
            return [0xDD if sv[0] == 'IX' else 0xFD, 0x46 + R8[dv] * 8, self.disp(sv[1])]
        if dk == 'idx' and sk == 'r8':
            return [0xDD if dv[0] == 'IX' else 0xFD, 0x70 + R8[sv], self.disp(dv[1])]
        if dk == 'idx' and sk == 'imm':
            return [0xDD if dv[0] == 'IX' else 0xFD, 0x36, self.disp(dv[1])] + self.b(self.eval(sv))
        if dk == 'r8' and sk == 'imm':
            return [0x06 + R8[dv] * 8] + self.b(self.eval(sv))
        if dv == 'A' and sk == 'reg' and sv in ('(BC)', '(DE)'):
            return [0x0A if sv == '(BC)' else 0x1A]
        if sv == 'A' and dk == 'reg' and dv in ('(BC)', '(DE)'):
            return [0x02 if dv == '(BC)' else 0x12]
        if dv == 'A' and sk == 'ind':
            return [0x3A] + self.w(self.eval(sv))
        if sv == 'A' and dk == 'ind':
            return [0x32] + self.w(self.eval(dv))
        if dv == 'A' and sv == 'I':
            return [0xED, 0x57]
        if dv == 'A' and sv == 'R':
            return [0xED, 0x5F]
        if dv == 'I' and sv == 'A':
            return [0xED, 0x47]
        if dv == 'R' and sv == 'A':
            return [0xED, 0x4F]
        if dk == 'reg' and dv == 'SP' and sk == 'reg' and sv in ('HL', 'IX', 'IY'):
            if sv == 'HL':
                return [0xF9]
            return [0xDD if sv == 'IX' else 0xFD, 0xF9]
        if dk == 'reg' and dv in ('IX', 'IY'):
            pre = 0xDD if dv == 'IX' else 0xFD
            if sk == 'imm':
                return [pre, 0x21] + self.w(self.eval(sv))
            if sk == 'ind':
                return [pre, 0x2A] + self.w(self.eval(sv))
        if dk == 'ind' and sk == 'reg' and sv in ('IX', 'IY'):
            return [0xDD if sv == 'IX' else 0xFD, 0x22] + self.w(self.eval(dv))
        if dk == 'reg' and dv in RP:
            if sk == 'imm':
                return [0x01 + RP[dv] * 16] + self.w(self.eval(sv))
            if sk == 'ind':
                if dv == 'HL':
                    return [0x2A] + self.w(self.eval(sv))
                return [0xED, 0x4B + RP[dv] * 16] + self.w(self.eval(sv))
        if dk == 'ind' and sk == 'reg' and sv in RP:
            if sv == 'HL':
                return [0x22] + self.w(self.eval(dv))
            return [0xED, 0x43 + RP[sv] * 16] + self.w(self.eval(dv))
        raise AsmError('bad LD operands: ' + ','.join(ops))

    # --------------------------------------------------------------- lines
    @staticmethod
    def strip_comment(line):
        out = []
        q = None
        for i, c in enumerate(line):
            if q:
                out.append(c)
                if c == q:
                    q = None
                continue
            if c == '"':
                q = c
            elif c == "'" and not (i > 0 and line[i - 2:i].upper() == 'AF'):
                # char literal 'x'
                if i + 2 < len(line) and line[i + 2] == "'":
                    out.append(line[i:i + 3])
                    # skip handled by flag
                    return Assembler._cont(out, line, i + 3)
            elif c == ';':
                break
            out.append(c)
        return ''.join(out)

    @staticmethod
    def _cont(out, line, j):
        return ''.join(out) + Assembler.strip_comment(line[j:])

    @staticmethod
    def split_ops(s):
        ops, cur, depth, q = [], '', 0, None
        for c in s:
            if q:
                cur += c
                if c == q:
                    q = None
                continue
            if c == '"':
                q = c
                cur += c
            elif c == '(':
                depth += 1
                cur += c
            elif c == ')':
                depth -= 1
                cur += c
            elif c == ',' and depth == 0:
                ops.append(cur.strip())
                cur = ''
            else:
                cur += c
        if cur.strip():
            ops.append(cur.strip())
        return ops

    def emit(self, bytes_):
        for x in bytes_:
            if self.pass_no == 2:
                if self.pc in self.mem:
                    raise AsmError('overlapping code at %04X' % self.pc)
                self.mem[self.pc] = x & 255
            self.pc += 1

    def read_file(self, path):
        lines = []
        with open(path) as f:
            for ln, line in enumerate(f, 1):
                lines.append((path, ln, line.rstrip('\n').rstrip('\r')))
        return lines

    def expand(self, path):
        out = []
        for (fn, ln, line) in self.read_file(path):
            m = re.match(r'\s*INCLUDE\s+"([^"]+)"', line, re.I)
            if m:
                inc = os.path.join(os.path.dirname(path), m.group(1))
                out.extend(self.expand(inc))
            else:
                out.append((fn, ln, line))
        return out

    def run_pass(self, lines):
        self.pc = 0
        cond = []
        for (fn, ln, raw) in lines:
            line = self.strip_comment(raw)
            try:
                self.line(line, cond, raw)
            except AsmError as e:
                if self.pass_no == 2:
                    self.errors.append('%s:%d: %s\n    %s' % (os.path.basename(fn), ln, e, raw.strip()))
            except (KeyError, IndexError, ValueError) as e:
                if self.pass_no == 2:
                    self.errors.append('%s:%d: syntax (%s)\n    %s' % (os.path.basename(fn), ln, e, raw.strip()))

    def line(self, line, cond, raw):
        if not line.strip():
            return
        m = re.match(r'^([A-Za-z_.][A-Za-z0-9_.]*)(:?)\s*(.*)$', line)
        label = None
        rest = line
        if m and (line[0] not in ' \t' or m.group(2) == ':'):
            # label at column 0 or with colon
            word = m.group(1).upper()
            nxt = m.group(3)
            is_directive_first = word in MNEMONICS
            if m.group(2) == ':' or not is_directive_first:
                label = word
                rest = nxt
        tok = rest.strip().split(None, 1)
        mn = tok[0].upper() if tok else ''
        args = tok[1] if len(tok) > 1 else ''
        # conditional assembly
        if mn == 'IF':
            active = all(cond)
            cond.append(bool(self.eval(args)) if active else False)
            return
        if mn == 'ELSE':
            parent = all(cond[:-1])
            cond[-1] = (not cond[-1]) and parent
            return
        if mn == 'ENDIF':
            cond.pop()
            return
        if not all(cond):
            return
        if mn == 'EQU':
            v = self.eval(args)
            self.define(label, v)
            return
        if label:
            self.define(label, self.pc)
        if not mn:
            return
        start = self.pc
        if mn in ('FNAME', 'CPU', 'OUTPUT', 'END'):
            return
        if mn == 'ORG':
            self.pc = self.eval(args)
            return
        if mn in ('DB', 'DEFB', 'DM', 'BYTE'):
            data = []
            for o in self.split_ops(args):
                if o.startswith('"'):
                    data.extend(ord(c) for c in o[1:-1])
                else:
                    data.extend(self.b(self.eval(o)))
            self.emit(data)
        elif mn in ('DW', 'DEFW', 'WORD'):
            data = []
            for o in self.split_ops(args):
                data.extend(self.w(self.eval(o)))
            self.emit(data)
        elif mn in ('DS', 'DEFS'):
            ops = self.split_ops(args)
            cnt = self.eval(ops[0])
            fill = self.eval(ops[1]) if len(ops) > 1 else 0
            self.emit([fill] * cnt)
        else:
            ops = self.split_ops(args)
            self.emit(self.encode(mn, ops, self.pc))
        if self.pass_no == 2:
            self.listing.append('%04X  %-24s %s' % (start, ' '.join('%02X' % self.mem[a] for a in range(start, min(self.pc, start + 8))), raw.rstrip()))

    def define(self, name, v):
        if self.pass_no == 1 and name in self.symbols and self.symbols[name] != v:
            raise AsmError('duplicate symbol ' + name)
        if self.pass_no == 2 and self.symbols.get(name) != v:
            self.phase_error = True
        self.symbols[name] = v

    def assemble(self, path):
        lines = self.expand(path)
        for p in (1, 1, 2):
            self.pass_no = p
            self.phase_error = False
            if p == 2:
                self.mem = {}
            self.run_pass(lines)
        return self.errors


def intel_hex(mem, lo, hi, rec=16):
    out = []
    a = lo
    while a <= hi:
        n = min(rec, hi - a + 1)
        data = [mem.get(a + i, 0xFF) for i in range(n)]
        rec_ = [n, (a >> 8) & 255, a & 255, 0] + data
        cs = (-sum(rec_)) & 255
        out.append(':' + ''.join('%02X' % x for x in rec_) + '%02X' % cs)
        a += n
    out.append(':00000001FF')
    return '\n'.join(out) + '\n'


def main():
    src = sys.argv[1]
    base = os.path.splitext(sys.argv[2] if len(sys.argv) > 2 else src)[0]
    a = Assembler()
    errs = a.assemble(src)
    if errs:
        print('\n'.join(errs[:60]))
        print('%d error(s)' % len(errs))
        sys.exit(1)
    lo, hi = min(a.mem), max(a.mem)
    with open(base + '.bin', 'wb') as f:
        f.write(bytes(a.mem.get(i, 0xFF) for i in range(lo, hi + 1)))
    with open(base + '.hex', 'w') as f:
        f.write(intel_hex(a.mem, lo, hi))
    with open(base + '.lst', 'w') as f:
        f.write('\n'.join(a.listing) + '\n')
    with open(base + '.sym', 'w') as f:
        for k, v in sorted(a.symbols.items(), key=lambda kv: kv[1]):
            f.write('%04X %s\n' % (v & 0xFFFF, k))
    print('OK  %04X-%04X  (%d bytes)' % (lo, hi, hi - lo + 1))


if __name__ == '__main__':
    main()
