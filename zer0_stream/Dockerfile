FROM hexpm/elixir:1.20.2-erlang-29.0.4-debian-trixie-20260713-slim AS builder

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends build-essential git ca-certificates \
	&& rm -rf /var/lib/apt/lists/*

COPY mix.exs mix.lock* ./
RUN mix local.hex --force && mix local.rebar --force && mix deps.get

COPY . .
RUN mix compile

FROM hexpm/elixir:1.20.2-erlang-29.0.4-debian-trixie-20260713-slim

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends libncurses6 ca-certificates \
	&& rm -rf /var/lib/apt/lists/*

COPY --from=builder /app/_build /app/_build
COPY --from=builder /app/deps /app/deps
COPY --from=builder /app/lib /app/lib
COPY --from=builder /app/config /app/config
COPY --from=builder /app/mix.exs /app/mix.exs
COPY --from=builder /app/docker-entrypoint.sh /app/docker-entrypoint.sh

RUN chmod +x /app/docker-entrypoint.sh

EXPOSE 4000

ENTRYPOINT ["/app/docker-entrypoint.sh"]
CMD ["mix", "phx.server"]
