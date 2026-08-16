defmodule Zer0Media.ControlPlaneAuth do
  def sign(method, path, params, timestamp \\ System.system_time(:second)) do
    signature =
      :crypto.mac(
        :hmac,
        :sha256,
        System.fetch_env!("CONTROL_PLANE_AUTH_SECRET"),
        signing_payload(method, path, params, timestamp)
      )
      |> Base.url_encode64(padding: false)

    {Integer.to_string(timestamp), signature}
  end

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
end
