defmodule Zer0Media.PlaybackToken do
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
    secret = System.get_env("PLAYBACK_TOKEN_SECRET", "dev-playback-secret")
    :crypto.mac(:hmac, :sha256, secret, payload) |> Base.url_encode64(padding: false)
  end
end
