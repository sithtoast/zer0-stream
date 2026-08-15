Mix.install([{:boombox, "~> 0.2.13"}])

input =
  System.get_env("BOOMBOX_INPUT_URL") ||
    raise "BOOMBOX_INPUT_URL is required, for example rtmp://127.0.0.1:1935/live/stream-key"

output = System.get_env("BOOMBOX_OUTPUT") || "priv/hls-boombox/index.m3u8"

output
|> Path.dirname()
|> File.mkdir_p!()

IO.puts("Boombox input: #{input}")
IO.puts("Boombox output: #{output}")
Boombox.run(input: input, output: output)
