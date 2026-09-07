#!/usr/bin/env python3
"""Make a paced video from the unedited, numbered Tart screenshots."""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[2]
media = root / 'docs/media/recovery'
frames = sorted(p for p in media.glob('[0-9][0-9]-*') if p.suffix in ('.png', '.jpg'))
if not frames:
    raise SystemExit('No Recovery screenshots found')
work = root / 'build/demo'
work.mkdir(parents=True, exist_ok=True)
playlist = work / 'recovery-frames.txt'
# Terminal steps need more reading time than the navigation screens.
durations = [5 if int(p.name[:2]) >= 11 else 3 for p in frames]
playlist.write_text(''.join(f"file '{p}'\nduration {seconds}\n" for p, seconds in zip(frames, durations)) + f"file '{frames[-1]}'\n")
subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-f', 'concat', '-safe', '0', '-i', str(playlist), '-t', str(sum(durations)), '-vf', 'fps=30,pad=ceil(iw/2)*2:ceil(ih/2)*2', '-c:v', 'libx264', '-crf', '18', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', str(media/'lnpctl-recovery.mp4')], check=True)
print(f'{len(frames)} screenshots; {sum(durations)} seconds')
