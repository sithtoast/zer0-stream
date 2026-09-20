# Local synthetic browser fixture. Run with --no-start; never against production media roots.
# LLHLS_BROWSER_DIR must contain index.html and the bundled frontend player.js.
defmodule BrowserHoldEnd do
  use Membrane.Filter
  def_input_pad(:input, accepted_format: _any, flow_control: :auto)
  def_output_pad(:output, accepted_format: _any, flow_control: :auto)
  def handle_buffer(:input, buffer, _ctx, state), do: {[buffer: {:output, buffer}], state}
  def handle_end_of_stream(:input, _ctx, state), do: {[], state}
end

defmodule BrowserSource do
  use Membrane.Bin
  def_output_pad(:audio, accepted_format: _any)
  def_output_pad(:video, accepted_format: _any)

  def handle_init(_ctx, _opts) do
    specs = [
      child(:audio, %Membrane.File.Source{location: "test/fixtures/llhls/audio.aac"})
      |> child(:aac, %Membrane.AAC.Parser{out_encapsulation: :ADTS})
      |> child(:hold_audio, BrowserHoldEnd)
      |> bin_output(:audio),
      child(:video, %Membrane.File.Source{location: "test/fixtures/llhls/video.h264"})
      |> child(:h264, %Membrane.H264.Parser{
        output_stream_structure: :avc1,
        generate_best_effort_timestamps: %{framerate: {30, 1}, add_dts_offset: false}
      })
      |> child(:hold_video, BrowserHoldEnd)
      |> bin_output(:video)
    ]

    {[spec: specs], %{}}
  end
end

defmodule BrowserFixtureRouter do
  import Plug.Conn
  def init(opts), do: opts

  def call(%{request_path: "/"} = conn, _),
    do:
      conn
      |> put_resp_content_type("text/html")
      |> send_file(200, Path.join(System.fetch_env!("LLHLS_BROWSER_DIR"), "index.html"))

  def call(%{request_path: "/player.js"} = conn, _),
    do:
      conn
      |> put_resp_content_type("text/javascript")
      |> send_file(200, Path.join(System.fetch_env!("LLHLS_BROWSER_DIR"), "player.js"))

  def call(%{request_path: "/fixture.json"} = conn, _),
    do:
      conn
      |> put_resp_content_type("application/json")
      |> send_file(200, Path.join(System.fetch_env!("LLHLS_BROWSER_DIR"), "fixture.json"))

  def call(conn, _), do: Zer0Media.HLSRouter.call(conn, [])
end

fixture = System.fetch_env!("LLHLS_BROWSER_DIR") |> Path.expand()

root =
  Path.join(fixture, "media-#{Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)}")

System.put_env("PLAYBACK_TOKEN_SECRET", "llhls-browser-fixture-only")
System.put_env("HLS_HTTP_PORT", "0")
Application.put_env(:zer0_media, :hls_dir, root <> "/hls")
Application.put_env(:zer0_media, :llhls_dir, root <> "/llhls")
Application.put_env(:zer0_media, :llhls_cookie_secure, false)
Application.put_env(:zer0_media, :boombox_hls_dir, root <> "/boombox")
{:ok, _} = Application.ensure_all_started(:zer0_media)
File.mkdir_p!(root <> "/hls/stream-session-70001")
{:ok, server} = Bandit.start_link(plug: BrowserFixtureRouter, port: 0, ip: {127, 0, 0, 1})
{:ok, {_, port}} = ThousandIsland.listener_info(server)

{:ok, _, _} =
  Membrane.Pipeline.start_link(Zer0Media.LivePipeline,
    client_ref: self(),
    parent: self(),
    session_id: 70001,
    output_dir: root <> "/hls/stream-session-70001",
    source: BrowserSource,
    llhls: %{Zer0Media.MediaConfig.llhls() | enabled?: true}
  )

payload = "v2:70001:#{System.system_time(:second) + 3600}:browser-fixture"

sig =
  :crypto.mac(:hmac, :sha256, "llhls-browser-fixture-only", payload)
  |> Base.url_encode64(padding: false)

token = Base.url_encode64(payload <> ":" <> sig, padding: false)
base = "http://127.0.0.1:#{port}"
System.put_env("HLS_ALLOWED_ORIGINS", base)

File.write!(
  Path.join(System.fetch_env!("LLHLS_BROWSER_DIR"), "fixture.json"),
  Jason.encode!(%{
    session_id: 70001,
    playback_url: base <> "/hls/stream-session-70001/master.m3u8?token=" <> token,
    llhls: %{
      session_url: base <> "/llhls/70001/session",
      token: token,
      expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
    }
  })
)

File.write!(Path.join(System.fetch_env!("LLHLS_BROWSER_DIR"), "url"), base)
IO.puts("Browser fixture: " <> base)

receive do
  :stop -> :ok
after
  900_000 -> :ok
end
