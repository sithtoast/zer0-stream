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
    Boombox.run(input: input, output: output)
  end
end
