defmodule Zer0Media.TURN do
  @moduledoc """
  Builds ICE servers (STUN + TURN) with separate quota identities for each
  viewer and each side of the connection. Browser credentials are refreshed
  through signaling; the control plane also receives a compatibility fallback.

  Supports two credential modes:

  - **Ephemeral (recommended)** — coturn `use-auth-secret`. Set `TURN_SECRET`.
    The username/credential are derived from the secret via HMAC-SHA1 with a
    short expiry, so credentials rotate and are never stored in plaintext.
  - **Static** — set `TURN_USERNAME` and `TURN_PASSWORD` directly.

  All values come from environment variables:

  - `TURN_URL` — TURN server used by the WebRTC sink (server side). If the media
    worker is on the same LAN as the TURN server, point this at the LAN address
    (e.g. `turn:192.168.1.1:3478?transport=udp`) to avoid NAT reflection.
    Only `transport=udp` is usable here: `ex_turn` (the server-side TURN
    client) only supports UDP — any other entry (e.g. `transport=tcp`) is
    silently ignored with a "Couldn't create TURN client: unsupported_turn_uri"
    log, so don't bother listing one. A comma-separated list is still
    accepted for future multi-UDP-server setups.
  - `TURN_PUBLIC_URL` — TURN server handed to the browser (must be a public,
    reachable address, e.g. `turn:199....:3478?transport=udp`). Defaults to
    `TURN_URL` if not set. Accepts a comma-separated list, and — unlike
    `TURN_URL` — a `transport=tcp` entry here IS usable (browsers implement
    TURN-over-TCP even though our server-side library doesn't), as a fallback
    for viewers on networks that drop/throttle long-lived UDP.
  - `TURN_SECRET` — shared secret for ephemeral credentials
  - `TURN_USERNAME` / `TURN_PASSWORD` — static credentials (when no secret)
  - `STUN_URL` — optional override of the default STUN server
  """

  @default_stun "stun:stun.l.google.com:19302"

  @doc "Returns the ICE servers list for the WebRTC sink (server side)."
  def ice_servers(viewer_id \\ nil) do
    [stun_server() | turn_servers(System.get_env("TURN_URL"), identity("worker", viewer_id))]
  end

  @doc "Returns the ICE servers to hand to the browser (public URL)."
  def browser_ice_servers(viewer_id \\ nil) do
    [
      stun_server()
      | turn_servers(
          System.get_env("TURN_PUBLIC_URL") || System.get_env("TURN_URL"),
          identity("browser", viewer_id)
        )
    ]
  end

  defp stun_server do
    %{urls: System.get_env("STUN_URL", @default_stun)}
  end

  defp turn_servers(nil, _identity), do: []

  defp turn_servers(urls, identity) do
    {username, credential} = credentials(identity)

    urls
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.map(fn url -> %{urls: url, username: username, credential: credential} end)
  end

  defp credentials(identity) do
    case System.get_env("TURN_SECRET") do
      nil ->
        {System.get_env("TURN_USERNAME", ""), System.get_env("TURN_PASSWORD", "")}

      secret ->
        username = "#{expiry_unix()}:#{identity}"
        credential = :crypto.mac(:hmac, :sha, secret, username) |> Base.encode64()
        {username, credential}
    end
  end

  defp expiry_unix do
    System.system_time(:second) + 3600
  end

  # Coturn's REST-auth quota uses the identity after the timestamp. Keep it
  # stable across retries but separate for each viewer and each side of TURN.
  defp identity(side, viewer_id) do
    value = viewer_id || Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    digest = :crypto.hash(:sha256, to_string(value)) |> Base.url_encode64(padding: false)
    "zer0-#{side}-#{digest}"
  end
end
