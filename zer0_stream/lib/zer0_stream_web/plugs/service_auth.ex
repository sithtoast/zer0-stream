defmodule Zer0StreamWeb.Plugs.ServiceAuth do
  import Plug.Conn

  alias Zer0Stream.ServiceAuth

  def init(options), do: options

  def call(conn, options) do
    timestamp = get_req_header(conn, "x-zer0-timestamp") |> List.first()
    signature = get_req_header(conn, "x-zer0-signature") |> List.first()
    role = Keyword.fetch!(options, :role)

    if ServiceAuth.valid?(
         role,
         conn.method,
         conn.request_path,
         conn.body_params,
         timestamp,
         signature
       ) do
      conn
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(:unauthorized, ~s({"error":"unauthorized"}))
      |> halt()
    end
  end
end
