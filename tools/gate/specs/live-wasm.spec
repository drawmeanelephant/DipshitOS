# live-wasm.spec -- M35 W2+W3+W4+W5 + rustc cross-language app in-guest

vgate_name live-wasm "M35 W2+W3+W4+W5 + rustc nl in-guest"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file hello.c <<'EOF'
__attribute__((import_module("env"), import_name("exit")))
__attribute__((noreturn)) void exit(int status);
__attribute__((import_module("env"), import_name("write")))
int write(int fd, const void *buf, unsigned long n);
void _start(void) {
    write(1, "hello, wasm!\n", 13);
    exit(55);
}
EOF

vgate_file script1.txt <<'EOF'
exec WASM.BIN FLOATAPP.WASM
echo rx-w4-float
exec WASM.BIN FILEAPP.WASM
echo rx-w3-file
exec WASM.BIN HELLO.WASM
echo rx-wasm-hello
exec WASM.BIN WC.WASM
echo rx-w5-wc
exec WASM.BIN WINAPP.WASM
echo rx-w3-win
EOF

vgate_file script2.txt <<'EOF'
dui
echo rx-w3-dui
dui raise 2
echo rx-w3-raised
dui move 2 100 100
echo rx-w3-moved
dui raise 2
echo rx-w3-raised2
dui move 2 100 100
echo rx-w3-moved2
dui raise 2
echo rx-w3-raised3
dui
echo rx-w3-dui
echo rx-wasm-ok
EOF

vgate_file script3.txt <<'EOF'
exec WASM.BIN NL.WASM
echo rx-rust-nl
EOF

vgate_setup_python <<'PY'
import os, shutil, subprocess, sys

run_dir = os.environ["RUN_DIR"]
share = os.path.join(run_dir, "share")
os.makedirs(share, exist_ok=True)

# 1. WASM.BIN
if os.path.exists("zig-out/bin/WASM.BIN"):
    shutil.copy("zig-out/bin/WASM.BIN", os.path.join(share, "WASM.BIN"))

# 2. HELLO.WASM
src = os.path.join(run_dir, "hello.c")
dst = os.path.join(share, "HELLO.WASM")
subprocess.run([
    "zig", "cc", "-target", "wasm32-freestanding", "-nostdlib",
    "-fno-sanitize=undefined", "-g0", src, "-o", dst
], check=True)

# 3. Fixtures from corpus
shutil.copy("user/src/wasm-corpus/winapp.wasm", os.path.join(share, "WINAPP.WASM"))
shutil.copy("user/src/wasm-corpus/fileapp.wasm", os.path.join(share, "FILEAPP.WASM"))
shutil.copy("user/src/wasm-corpus/floatapp.wasm", os.path.join(share, "FLOATAPP.WASM"))
shutil.copy("user/src/wasm-corpus/wc.wasm", os.path.join(share, "WC.WASM"))
shutil.copy("tests/wc-fixture.txt", os.path.join(share, "WC.TXT"))
shutil.copy("user/src/wasm-corpus/nl.wasm", os.path.join(share, "NL.WASM"))

# 4. FILE.TXT
with open(os.path.join(share, "FILE.TXT"), "wb") as f:
    f.write(b"w3-filerocks!!!\n" * 32)
PY

vgate_run 01 -- --display --screen '$RUN_DIR/gpu-screen' --script '$RUN_DIR/script1.txt' --script-after "tasks user-el0 exited status=7" --script2 '$RUN_DIR/script2.txt' --script2-after "w3: win ok" --script3 '$RUN_DIR/script3.txt' --script3-after "tasks user-exec exited status=21" --screenshot-after "rx-wasm-ok" --timeout 120

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'hello, wasm!'
vgate_assert 01 serial-contains 'tasks user-exec exited status=55'
vgate_assert 01 serial-contains 'rx-wasm-hello'
vgate_assert 01 serial-contains 'w3: win open='
vgate_assert 01 serial-contains 'w3: win ok'
vgate_assert 01 serial-contains 'tasks user-exec exited status=21'
vgate_assert 01 serial-contains 'rect=100,100,96,48'
vgate_assert 01 serial-contains 'tasks user-exec exited status=512'
vgate_assert 01 serial-contains 'w3-filerocks!!!'
vgate_assert 01 serial-contains 'tasks user-exec exited status=590'
vgate_assert 01 serial-contains 'mC 100000 = 212.00'
vgate_assert 01 serial-contains 'bits64 c2f 21.50 = 4051accccccccccd'
vgate_assert 01 serial-contains 'f2c 98.60 = 37.00'
vgate_assert 01 serial-contains 'f32 f2c -4.00 = -20.00'
vgate_assert 01 serial-contains 'sext chk = -66'
vgate_assert 01 serial-contains 'rx-w4-float'
vgate_assert 01 serial-contains '  8  32 320 /host/WC.TXT'
vgate_assert 01 serial-contains 'tasks user-exec exited status=320'
vgate_assert 01 serial-contains 'rx-w5-wc'
vgate_assert 01 serial-contains '     1  w5 wc capstone fixture'
vgate_assert 01 serial-contains '     3  long-token-0001-abcdefghijklmnopqrstuvwxyz-this-token-is-longer-than-the-64-byte-reader-buffer-so-the-word-state-must-survive-the-chunk-seam'
vgate_assert 01 serial-contains '     7    leading spaces too'
vgate_assert 01 serial-contains '     8  last line ends with a word'
vgate_assert 01 serial-contains 'tasks user-exec exited status=383'
vgate_assert 01 serial-contains 'rx-rust-nl'
vgate_assert 01 serial-contains 'rx-wasm-ok'
vgate_assert 01 serial-contains 'dui: windows='
vgate_assert 01 serial-contains 'blits='
vgate_assert 01 serial-absent 'wasm: open failed'
vgate_assert 01 serial-absent 'wasm: parse error'
vgate_assert 01 serial-absent 'wasm: validate error'
vgate_assert 01 serial-absent 'wasm: mmap failed'
vgate_assert 01 serial-absent 'wasm: trap'
vgate_assert 01 serial-absent 'wasm: instantiate trap'
vgate_assert 01 serial-absent '[EXC] parking:'

vgate_assert 01 snapshot 'gpu-screen-after' <<'PY'
import sys, zlib, struct
def decode(path):
    d = open(path, 'rb').read()
    pos = 8; idat = b''; w = h = ct = 0
    while pos < len(d):
        ln, typ = struct.unpack('>I4s', d[pos:pos+8])
        data = d[pos+8:pos+8+ln]
        if typ == b'IHDR':
            w, h, bd, ct = struct.unpack('>IIBB', data[:10])
        elif typ == b'IDAT':
            idat += data
        pos += 12 + ln
    raw = zlib.decompress(idat)
    bpp = 4 if ct == 6 else 3
    stride = w * bpp
    out = bytearray(); prev = bytearray(stride); i = 0
    for y in range(h):
        f = raw[i]; i += 1
        line = bytearray(raw[i:i+stride]); i += stride
        if f == 1:
            for x in range(bpp, stride): line[x] = (line[x] + line[x-bpp]) & 0xff
        elif f == 2:
            for x in range(stride): line[x] = (line[x] + prev[x]) & 0xff
        elif f == 3:
            for x in range(stride):
                a = line[x-bpp] if x >= bpp else 0
                line[x] = (line[x] + ((a + prev[x]) >> 1)) & 0xff
        elif f == 4:
            for x in range(stride):
                a = line[x-bpp] if x >= bpp else 0
                b = prev[x]
                c = prev[x-bpp] if x >= bpp else 0
                p = a + b - c
                pa, pb, pc = abs(p-a), abs(p-b), abs(p-c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[x] = (line[x] + pr) & 0xff
        out += line
        prev = line
    return w, h, bpp, out

def largest_red_component(out, w, h, bpp, x0, y0, x1, y1):
    def px(x, y):
        o = (y * w + x) * bpp
        return out[o], out[o+1], out[o+2]
    mask = set()
    for y in range(y0, y1):
        for x in range(x0, x1):
            r, g, b = px(x, y)
            if r > 170 and g < 110 and b < 110:
                mask.add((x, y))
    best = 0
    todo = list(mask)
    while todo:
        seed = todo.pop()
        comp = {seed}
        stack = [seed]
        while stack:
            cx, cy = stack.pop()
            for nx, ny in ((cx+1, cy), (cx-1, cy), (cx, cy+1), (cx, cy-1)):
                if (nx, ny) in mask and (nx, ny) not in comp:
                    comp.add((nx, ny))
                    stack.append((nx, ny))
        if len(comp) > best: best = len(comp)
    return best

path = sys.argv[1]
w, h, bpp, out = decode(path)
best = largest_red_component(out, w, h, bpp, 150, 150, 450, 350)
print(f"red fill: largest contiguous red block = {best} px")
sys.exit(0 if best >= 4000 else 1)
PY
