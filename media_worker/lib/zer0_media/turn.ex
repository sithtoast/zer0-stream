defmodule Zer0Media.TURN do
  @moduledoc """
  Builds the ICE servers (STUN + TURN) used by the WebRTC sink and reported to
  the control plane so the browser can use the same TURN credentials.

  Supports two credential modes:

  - **Ephemeral (recommended)** — coturn `use-auth-secret`. Set `TURN_SECRET`.
    The username/credential are derived from the secret via HMAC-SHA1 with a
    short expiry, so credentials rotate and are never stored in plaintext.
  - **Static** — set `TURN_USERNAME` and `TURN_PASSWORD` directly.

  All values come from environment variables:

  - `TURN_URL` — e.g. `turn:turn.example.com:3478?transport=udp`
  - `TURN_SECRET` — shared secret for ephemeral credentials
  - `TURN_USERNAME` / `TURN_PASSWORD` — static credentials (when no secret)
  - `STUN_URL` — optional override of the default STUN server
  """

  @default_stun "stun:stun.l.google.com:19302"

  @doc "Returns the ICE servers list for the WebRTC sink (server side)."
  def ice_servers do
    [stun_server() | turn_servers()]
  end

  @doc "Returns the ICE servers to hand to the browser (same list)."
  def browser_ice_servers, do: ice_servers()

  defp stun_server do
    %{urls: System.get_env("STUN_URL", @default_stun)}
  end

  defp turn_servers do
    case System.get_env("TURN_URL") do
      nil ->
        []

      url ->
        {username, credential} = credentials()
        [%{urls: url, username: username, credential: credential}]
    end
  end

  defp credentials do
    case System.get_env("TURN_SECRET") do
      nil ->
        {System.get_env("TURN_USERNAME", ""), System.get_env("TURN_PASSWORD", "")}

      secret ->
        username = "#{expiry_unix()}:#{user_id()}"
        credential = :crypto.mac(:hmac, :sha, secret, username) |> Base.encode64()
        {username, credential}
    end
  end

  defp expiry_unix do
    System.system_time(:second) + 3600
  end

  defp user_id do
    "zer0"
  end
end
