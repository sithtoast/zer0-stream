defmodule Zer0Boombox do
  require Logger

  def run do
    input =
      System.get_env("BOOMBOX_INPUT_URL") ||
        raise "BOOMBOX_INPUT_URL is required"

    output =
      System.get_env("BOOMBOX_OUTPUT") ||
        raise "BOOMBOX_OUTPUT is required"

    output
    |> Path.dirname()
    |> File.mkdir_p!()

    Logger.info("Starting Boombox input=#{input} output=#{output}")

    # Use live HLS mode (not the :vod default) so the packager emits a proper
    # sliding live playlist with a bounded window instead of accumulating every
    # segment as on-demand. This lets the player stay close to the live edge
    # instead of buffering far behind it, which is the biggest lever on latency.
    Boombox.run(input: input, output: {output, mode: :live})
  end
end
