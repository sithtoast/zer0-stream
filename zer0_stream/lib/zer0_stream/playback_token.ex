defmodule Zer0Stream.PlaybackToken do
  @default_ttl 3600

  def issue(session_id, ttl \\ @default_ttl) do
    expires_at = System.system_time(:second) + ttl
    payload = "#{session_id}:#{expires_at}"
    signature = sign(payload)
    Base.url_encode64(payload <> ":" <> signature, padding: false)
  end

  def valid?(token, session_id) when is_binary(token) do
    with {:ok, encoded} <- Base.url_decode64(token, padding: false),
         [^session_id, expires_at, signature] <- String.split(encoded, ":"),
         {expires_at, ""} <- Integer.parse(expires_at),
         true <- expires_at >= System.system_time(:second),
         true <- Plug.Crypto.secure_compare(signature, sign("#{session_id}:#{expires_at}")) do
      true
    else
      _ -> false
    end
  end

  def valid?(_token, _session_id), do: false

  defp sign(payload) do
    secret = Application.get_env(:zer0_stream, :playback_token_secret, "dev-playback-secret")
    :crypto.mac(:hmac, :sha256, secret, payload) |> Base.url_encode64(padding: false)
  end
end
