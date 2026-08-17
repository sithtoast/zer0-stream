# zer0.tv Chat

Independent Phoenix Channels service for zer0.tv. The service listens on port
4100, exposes `GET /health`, and accepts WebSocket connections at `/socket`.

Chat clients connect with a short-lived Phoenix token in the `token` parameter.
The token must contain a `user_id` claim and uses the `chat-user` salt. The
main application will issue these tokens through the signed service contract.

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
