# Demo media

Run `python3 tools/demo/create.py` from the project root with an existing Python environment containing Pillow, plus macOS Command Line Tools and ffmpeg. The script does not install dependencies.

It compiles a temporary copy of `src/LNPUI.m` with a framebuffer observer and drives the real ncurses picker through the existing PTY harness. All eight application entries are fictional. The harness only returns selected tokens; it cannot prepare backups or access the permission store.

The PNGs render captured character cells, emphasis, and color with a fixed terminal palette. Titles, captions, and the final explanation card are editorial additions. The MP4 is a paced sequence of these captures, including each filter keystroke, not a desktop recording. Recovery is not shown.

Outputs are in `docs/media/`; intermediate cell captures and the temporary executable are in `build/demo/`. The script asserts that confirmation returns exactly the two intended selections. Rendering does not modify production source or the installed executable.
