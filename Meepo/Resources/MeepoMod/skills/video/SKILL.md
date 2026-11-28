---
name: video
description: Watch a screen recording or a bug video — its key frames and what's said in it — and report what happens, the steps to reproduce, expected vs actual. Use when the user gives a video file (.mov, .mp4, .webm).
argument-hint: <video file>
context: fork
allowed-tools: Bash(~/.meepo/mod/skills/video/frames.sh *) Read
---

Watch the video at $ARGUMENTS. Claude can't read video, so:

1. Run `~/.meepo/mod/skills/video/frames.sh "<the video path>"`. It prints a folder with `frames/NN.jpg` (key frames:
   the first one and every scene change, at most 20), `frames.txt` (each frame's time in the video) and, when
   someone speaks, `transcript.txt` (speech with timestamps).
2. Read `frames.txt`, `transcript.txt` if there, then every frame in order.
3. Report, in the language of the speech or the user's:
   - **What the video shows** — one or two sentences.
   - **Steps to reproduce** — numbered, each with its time in the video.
   - **Expected vs actual**.
   - **Errors on screen** — exact texts, as shown.
   - **Key frames** — 3–5 frame paths, what each shows.
   Don't fix anything; the main session decides what to do with it.
