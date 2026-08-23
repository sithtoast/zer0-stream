defmodule Zer0Boombox do
  require Logger

  def run do
    input =
      System.get_env("BOOMBOX_INPUT_URL") ||
        raise "BOOMBOX_INPUT_URL is required"

    case System.get_env("BOOMBOX_OUTPUT_MODE", "hls") do
      "webrtc" ->
        port =
          System.get_env("BOOMBOX_WEBRTC_PORT", "8443")
          |> String.to_integer()

        signaling_url = "ws://0.0.0.0:#{port}"

        Logger.info("Starting Boombox input=#{input} output=webrtc(#{signaling_url})")

        # WebRTC output with WebSocket signaling. The Sink sends an SDP offer to
        # the browser, which answers it, and the stream flows over RTCPeerConnection
        # for sub-second latency.
        Boombox.run(input: input, output: {:webrtc, signaling_url})

      _hls ->
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
end
