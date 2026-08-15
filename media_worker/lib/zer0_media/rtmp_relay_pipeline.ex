defmodule Zer0Media.RTMPRelayPipeline do
  use Membrane.Pipeline

  @impl true
  def handle_init(_ctx, opts) do
    relay_url = Keyword.fetch!(opts, :relay_url)

    structure = [
      child(:source, %Membrane.RTMP.SourceBin{client_ref: opts[:client_ref]})
      |> via_out(:audio)
      |> child(:audio_parser, %Membrane.AAC.Parser{
        out_encapsulation: :none,
        output_config: :esds
      })
      |> via_in(Pad.ref(:audio, 0))
      |> get_child(:sink),
      get_child(:source)
      |> via_out(:video)
      |> child(:video_parser, %Membrane.H264.Parser{output_stream_structure: :avc1})
      |> via_in(Pad.ref(:video, 0))
      |> get_child(:sink),
      child(:sink, %Membrane.RTMP.Sink{
        rtmp_url: relay_url,
        max_attempts: :infinity,
        reset_timestamps: true
      })
    ]

    {[spec: structure], %{parent: opts[:parent]}}
  end
end
