#!/usr/bin/env python3
"""Capture the real picker framebuffer with synthetic data; render PNG/MP4 media.
Requires macOS clang/ncurses, Pillow and ffmpeg. No permission-store access.
"""
import json
import os
from pathlib import Path
import runpy
import shutil
import subprocess
import sys
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'docs/media'
WORK = ROOT / 'build/demo'
WORK.mkdir(parents=True, exist_ok=True)
OUT.mkdir(parents=True, exist_ok=True)
# Instrument only a build-directory copy. Read cells without changing the UI.
probe = r'''
static void DemoCapture(void) {
    int oldY, oldX; getyx(stdscr, oldY, oldX);
    NSMutableArray *rows = [NSMutableArray array];
    for (int y = 0; y < LINES; y++) {
        NSMutableArray *row = [NSMutableArray array];
        for (int x = 0; x < COLS; x++) {
            cchar_t cell; wchar_t chars[CCHARW_MAX] = {0}; attr_t attr = 0; short pair = 0;
            mvwin_wch(stdscr, y, x, &cell); getcchar(&cell, chars, &attr, &pair, NULL);
            NSString *text = [[NSString alloc] initWithBytes:chars length:wcslen(chars)*sizeof(wchar_t) encoding:NSUTF32LittleEndianStringEncoding];
            [row addObject:@{@"text":text ?: @" ", @"bold":@((attr & A_BOLD)!=0), @"dim":@((attr & A_DIM)!=0), @"accent":@(pair==1)}];
        }
        [rows addObject:row];
    }
    move(oldY, oldX);
    NSData *data = [NSJSONSerialization dataWithJSONObject:rows options:0 error:NULL];
    [data writeToFile:[NSString stringWithUTF8String:getenv("LNP_DEMO_FRAME")] atomically:YES];
}
'''
source = (ROOT / 'src/LNPUI.m').read_text()
source = source.replace('static volatile sig_atomic_t interrupted;', probe + '\nstatic volatile sig_atomic_t interrupted;')
source = source.replace('int kind = get_wch(&key);', 'DemoCapture(); int kind = get_wch(&key);')
(WORK / 'LNPUI.m').write_text(source)
subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-Wall', '-Wextra', '-Werror', '-Wno-deprecated-declarations', '-O2', '-I'+str(ROOT/'src'), str(ROOT/'tools/demo/harness.m'), str(WORK/'LNPUI.m'), '-framework', 'Foundation', '-framework', 'CoreFoundation', '-lncurses', '-o', str(WORK/'picker')], check=True)
sys.argv = [str(ROOT/'tests/test_tui.py'), str(WORK/'picker')]
Picker = runpy.run_path(str(ROOT/'tests/test_tui.py'))['Picker']
os.environ.pop('NO_COLOR', None)
p = Picker(size=(32, 100), extra_env={'LNP_DEMO_FRAME':str(WORK/'frame.json')})
frames = []
def capture(name, title, caption, duration):
    p.pump(.25)
    data = json.loads((WORK/'frame.json').read_text())
    (WORK/(name+'.json')).write_text(json.dumps(data))
    frames.append((name, title, caption, duration, data))
try:
    capture('01-picker', 'Choose the entries you recognize', 'Nothing is selected automatically.', 3)
    p.send(b' ')
    capture('02-selected', 'Space selects an entry', 'A missing executable is a clue; verify the identity and path.', 3)
    p.send(b'/')
    for index, letter in enumerate(b'harbor'):
        p.send(bytes([letter]))
        capture('typing-'+str(index), 'Type / to filter', 'Your previous selections stay selected.', .22)
    p.send(b'\n')
    capture('03-filter', 'Filter without losing your selection', 'The hidden count keeps selections outside the filter visible.', 3)
    p.send(b' ')
    capture('04-two-selected', 'Add another entry', 'Two selections, including one hidden by the current filter.', 2)
    p.send(b'\n')
    capture('05-review', 'Review the complete selection', 'Check both entries before pressing p to prepare.', 5)
    p.send(b'p')
    result = p.finish()
    assert b'DEMO_SELECTION:demo-0,demo-3' in result, result
    (WORK/'selection.txt').write_text('DEMO_SELECTION:demo-0,demo-3\n')
finally:
    p.close()

BG = '#0e131b'
FG = '#e7edf5'
DIM = '#97a5b8'
CYAN = '#73d8ea'
FONT = '/System/Library/Fonts/Menlo.ttc'
mono = ImageFont.truetype(FONT, 18)
bold = ImageFont.truetype(FONT, 18, index=1)
heading = ImageFont.truetype('/System/Library/Fonts/SFNS.ttf', 29)
captionfont = ImageFont.truetype('/System/Library/Fonts/SFNS.ttf', 21)
W, H = 1280, 960
CW, LH = 12, 23
paths = []
for name, title, caption, duration, rows in frames:
    im = Image.new('RGB', (W,H), BG)
    d = ImageDraw.Draw(im)
    d.text((40,24), title, font=heading, fill=FG)
    d.text((40,68), 'lnpctl  /  synthetic data  /  actual picker framebuffer', font=captionfont, fill=DIM)
    d.rounded_rectangle((25,110,1255,869), radius=12, fill='#161e29', outline='#344153', width=1)
    for y, row in enumerate(rows):
        for x, cell in enumerate(row):
            d.text((40+x*CW,121+y*LH),cell['text'],font=bold if cell['bold'] else mono,fill=CYAN if cell['accent'] else DIM if cell['dim'] else FG)
    d.text((40,896),caption,font=captionfont,fill=FG)
    path = WORK/(name+'.png')
    im.save(path)
    paths.append((path,duration))
    if name in ('01-picker','03-filter','05-review'):
        shutil.copyfile(path,OUT/(name+'.png'))
im = Image.new('RGB',(W,H),BG)
d = ImageDraw.Draw(im)
d.text((80,180),'Prepare now. Apply later in Recovery.',font=heading,fill=FG)
for y,text in enumerate(['p confirms the selection and normally saves a backup.', 'Live permissions remain unchanged during preparation.', '', 'Demo ends here: no backup or permission change was made.', 'Recovery is a separate, manual step.']):
    d.text((80,270+y*52),text,font=captionfont,fill=CYAN if y==3 else DIM)
d.text((80,820),'lnpctl  /  synthetic walkthrough',font=captionfont,fill=DIM)
im.save(WORK/'end.png')
paths.append((WORK/'end.png',5))
# ffconcat filenames are generated here and contain no apostrophes.
playlist = ''.join(f"file '{path}'\nduration {duration}\n" for path,duration in paths)
playlist += f"file '{paths[-1][0]}'\n"
(WORK/'frames.txt').write_text(playlist)
subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-y','-f','concat','-safe','0','-i',str(WORK/'frames.txt'),'-t',str(sum(duration for _, duration in paths)),'-vf','fps=30','-c:v','libx264','-crf','18','-pix_fmt','yuv420p','-movflags','+faststart',str(OUT/'lnpctl-demo.mp4')],check=True)
print(OUT)
