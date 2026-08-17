defmodule Mix.Tasks.Zer0Media.Dev do
  use Mix.Task

  @shortdoc "Starts the local media worker and RTMP listener"

  @impl Mix.Task
  def run(args) do
    {options, positional, invalid} =
      OptionParser.parse(args,
        strict: [control_plane_url: :string, rtmp_port: :integer]
      )

    if positional != [] or invalid != [] do
      Mix.raise("usage: mix zer0_media.dev [--control-plane-url URL] [--rtmp-port PORT]")
    end

    if control_plane_url = options[:control_plane_url] do
      Application.put_env(:zer0_media, :control_plane_url, control_plane_url)
    end

    Mix.Task.run("app.start")

    case Zer0Media.RTMPServer.start_link(port: options[:rtmp_port] || 1935) do
      {:ok, _pid} -> Process.sleep(:infinity)
      {:error, reason} -> Mix.raise("could not start RTMP listener: #{inspect(reason)}")
    end
  end
end
