defmodule Zer0Media.PlaybackToken do
  def valid?(token, session_id), do: match?({:ok, _}, viewer_id(token, session_id))

  # Only return an identity after verifying its signature, stream, and expiry.
  # Legacy tokens keep their old identity until their normal expiry.
  def viewer_id(token, session_id) when is_binary(token) do
    with {:ok, encoded} <- Base.url_decode64(token, padding: false),
         {:ok, payload, expires_at, signature, identity} <-
           decode(String.split(encoded, ":"), to_string(session_id), token),
         {expires_at, ""} <- Integer.parse(expires_at),
         true <- expires_at >= System.system_time(:second),
         true <- Plug.Crypto.secure_compare(signature, sign(payload)) do
      {:ok, identity}
    else
      _ -> :error
    end
  end

  def viewer_id(_, _), do: :error

  def valid_viewer_id?(id),
    do: is_binary(id) and byte_size(id) in 1..128 and Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, id)

  defp decode(["v2", session, expiry, id, signature], session, _token) do
    if valid_viewer_id?(id),
      do: {:ok, "v2:#{session}:#{expiry}:#{id}", expiry, signature, "viewer:" <> id},
      else: :error
  end

  defp decode([session, expiry, signature], session, token) do
    id = :crypto.hash(:sha256, token) |> Base.url_encode64(padding: false)
    {:ok, "#{session}:#{expiry}", expiry, signature, id}
  end

  defp decode(_, _, _), do: :error

  defp sign(payload) do
    secret = System.get_env("PLAYBACK_TOKEN_SECRET", "dev-playback-secret")
    :crypto.mac(:hmac, :sha256, secret, payload) |> Base.url_encode64(padding: false)
  end
end
