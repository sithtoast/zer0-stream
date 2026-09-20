# Synthetic CMAF integration inputs

Generated locally with FFmpeg's `testsrc2` and `sine` sources. No external media,
personal data or captured publisher input. Six seconds, H.264 160x90 at 30 fps,
2-second closed GOP, no B-frames; AAC mono 48 kHz. Small fixtures are checked in
so the Membrane integration test does not require ffmpeg to generate inputs.

Reproduce from this directory with FFmpeg built with libx264:

```sh
ffmpeg -f lavfi -i testsrc2=size=160x90:rate=30 -t 6 -an -c:v libx264 -preset ultrafast -g 60 -keyint_min 60 -sc_threshold 0 -bf 0 -f h264 video.h264
ffmpeg -f lavfi -i sine=frequency=440:sample_rate=48000 -t 6 -c:a aac -b:a 64k -f adts audio.aac
```

`llhls_pipeline_test.exs` uses production LivePipeline and the installed Membrane
muxer, checks exact part/segment assembly and parses the resulting playlists.
When ffprobe is installed it additionally decodes local assembled media and the
actual authenticated HTTP master, counts frames and checks DTS/keyframes.
This is not OBS/RTMP packet, B-frame, Safari or hls.js interoperability evidence.
