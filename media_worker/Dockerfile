FROM hexpm/elixir:1.20.2-erlang-29.0.4-debian-trixie-20260713-slim AS builder

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential git pkg-config libssl-dev ca-certificates \
    libasound2-dev libx11-dev libxext-dev libxrandr-dev libxrender-dev \
    libxfixes-dev libxi-dev libxss-dev libxcursor-dev libxinerama-dev \
    libxkbcommon-dev libgl1-mesa-dev \
    && rm -rf /var/lib/apt/lists/*

COPY media_worker/mix.exs media_worker/mix.lock ./media_worker/
COPY boombox_runtime/mix.exs boombox_runtime/mix.lock ./boombox_runtime/

RUN mix local.hex --force && mix local.rebar --force
RUN cd /app/media_worker && mix deps.get
RUN MIX_HOME=/app/.mix-boombox HEX_HOME=/app/.hex-boombox \
    mix local.hex --force && \
    MIX_HOME=/app/.mix-boombox HEX_HOME=/app/.hex-boombox mix local.rebar --force
RUN cd /app/boombox_runtime && MIX_HOME=/app/.mix-boombox HEX_HOME=/app/.hex-boombox mix deps.get

COPY media_worker ./media_worker
COPY boombox_runtime ./boombox_runtime

RUN cd /app/media_worker && mix compile
RUN cd /app/boombox_runtime && MIX_HOME=/app/.mix-boombox HEX_HOME=/app/.hex-boombox mix compile

FROM hexpm/elixir:1.20.2-erlang-29.0.4-debian-trixie-20260713-slim

WORKDIR /app/media_worker

RUN apt-get update && apt-get install -y --no-install-recommends \
    libncurses6 openssl ca-certificates libasound2 libx11-6 libxext6 \
    libxrandr2 libxrender1 libxfixes3 libxi6 libxss1 libxcursor1 \
    libxinerama1 libxkbcommon0 libgl1 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /app/media_worker /app/media_worker
COPY --from=builder /app/boombox_runtime /app/boombox_runtime
COPY --from=builder /app/.mix-boombox /app/.mix-boombox
COPY --from=builder /app/.hex-boombox /app/.hex-boombox

ENV MIX_ENV=prod \
    MIX_HOME=/app/.mix-media \
    HEX_HOME=/app/.hex-media \
    BOOMBOX_RUNTIME_DIR=/app/boombox_runtime \
    HLS_HTTP_PORT=8080

EXPOSE 1935 8080

CMD ["mix", "run", "-e", "{:ok, _pid} = Zer0Media.RTMPServer.start_link(port: 1935); Process.sleep(:infinity)"]
