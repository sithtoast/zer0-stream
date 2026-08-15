- [x] Verify that the copilot-instructions.md file in the .github directory is created.
- [x] Clarify Project Requirements
- [x] Scaffold the Project
- [x] Customize the Project
- [x] Install Required Extensions
- [x] Compile the Project
- [x] Create and Run Task
- [x] Launch the Project
- [x] Ensure Documentation is Complete

This workspace is for the independent zer0-stream backend that will power live ingest, transcoding, and low-latency HLS delivery for zer0.tv.

Project assumptions:
- Separate repository from the current zer0.tv discovery app.
- Elixir + Phoenix + Membrane as the media backend foundation.
- Dockerized deployment with independent runtime and environment configuration.
- RTMP ingest first, WHIP support added after initial stability.
- Low-latency HLS delivery using a CDN/origin pattern.
- Integration with zer0.tv via signed service contracts rather than a shared database.
