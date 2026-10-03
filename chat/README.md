# zer0.tv Chat

Independent Phoenix Channels service for zer0.tv. The service listens on port
4100, exposes `GET /health`, and accepts WebSocket connections at `/socket`.

Chat clients connect with a short-lived Phoenix token in the `token` parameter.
The token uses the `chat-user` salt and must contain `user_id` and `channel_id`
claims (plus optional `display_name` and `broadcaster_id`). The main application
issues one only after checking the viewer may chat in that channel, so a token
can join `chat:<channel_id>` for its own `channel_id` and nothing else; joins to
any other topic return `unauthorized`. The broadcaster badge comes from the
token's `broadcaster_id`, never from join params.

## Local development

```sh
cd /Users/wmh/Dev/zer0-stream/chat
mix setup
mix phx.server
```

The first channel contract is `chat:<channel_id>`. Clients send a `message`
event with a `body` string up to 500 characters and receive broadcast `message`
events. The service returns at most 50 recent messages on join and allows 10
messages per connection in a rolling 10-second window.

Run the channel tests with PostgreSQL available:

```sh
mix test
```

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://phoenix.hexdocs.pm/overview.html
* Docs: https://phoenix.hexdocs.pm
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix
