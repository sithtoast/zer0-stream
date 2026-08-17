defmodule Zer0Media.ControlPlaneAuth do
  @max_age_seconds 60

  def sign(method, path, params, timestamp \\ System.system_time(:second)) do
    signature =
      :crypto.mac(
        :hmac,
        :sha256,
        secret(),
        signing_payload(method, path, params, timestamp)
      )
      |> Base.url_encode64(padding: false)

    {Integer.to_string(timestamp), signature}
  end

  def valid?(method, path, params, timestamp, signature)
      when is_binary(timestamp) and is_binary(signature) do
    with {timestamp, ""} <- Integer.parse(timestamp),
         true <- abs(System.system_time(:second) - timestamp) <= @max_age_seconds,
         {_timestamp, expected_signature} <- sign(method, path, params, timestamp),
         true <- secure_compare(signature, expected_signature) do
      true
    else
      _ -> false
    end
  end

  def valid?(_method, _path, _params, _timestamp, _signature), do: false

  defp signing_payload(method, path, params, timestamp) do
    [method |> to_string() |> String.upcase(), path, timestamp, canonical_json(params)]
    |> Enum.join("\n")
  end

  defp canonical_json(value) when is_map(value) do
    entries =
      value
      |> Enum.map(fn {key, nested_value} -> {to_string(key), nested_value} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join(",", fn {key, nested_value} ->
        Jason.encode!(key) <> ":" <> canonical_json(nested_value)
      end)

    "{" <> entries <> "}"
  end

  defp canonical_json(value) when is_list(value),
    do: "[" <> Enum.map_join(value, ",", &canonical_json/1) <> "]"

  defp canonical_json(value), do: Jason.encode!(value)

  defp secret do
    case {System.get_env("CONTROL_PLANE_AUTH_SECRET"), System.get_env("MIX_ENV", "dev")} do
      {nil, "prod"} -> raise "environment variable CONTROL_PLANE_AUTH_SECRET is missing"
      {nil, _mix_env} -> "dev-control-plane-auth-secret"
      {secret, _mix_env} -> secret
    end
  end

  defp secure_compare(left, right) when byte_size(left) == byte_size(right),
    do: Plug.Crypto.secure_compare(left, right)

  defp secure_compare(_left, _right), do: false
end
