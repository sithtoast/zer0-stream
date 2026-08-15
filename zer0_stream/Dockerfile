FROM hexpm/elixir:1.20.3-erlang-27.0.1-alpine-3.20 AS builder

WORKDIR /app

RUN apk add --no-cache build-base git

COPY mix.exs mix.lock* ./
RUN mix local.hex --force && mix local.rebar --force && mix deps.get

COPY . .
RUN mix compile

FROM hexpm/elixir:1.20.3-erlang-27.0.1-alpine-3.20

WORKDIR /app

RUN apk add --no-cache ncurses-libs

COPY --from=builder /app/_build /app/_build
COPY --from=builder /app/deps /app/deps
COPY --from=builder /app/lib /app/lib
COPY --from=builder /app/config /app/config
COPY --from=builder /app/mix.exs /app/mix.exs

EXPOSE 4000

CMD ["mix", "phx.server"]
