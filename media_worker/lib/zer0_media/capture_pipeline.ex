defmodule Zer0Media.CapturePipeline do
  use Membrane.Pipeline

  @impl true
  def handle_init(_ctx, opts) do
    output_file = Keyword.fetch!(opts, :output_file)

    structure = [
      child(:source, %Membrane.RTMP.SourceBin{client_ref: opts[:client_ref]})
      |> via_out(:audio)
      |> child(:audio_parser, %Membrane.AAC.Parser{
        out_encapsulation: :none,
        output_config: :audio_specific_config
      })
      |> via_in(Pad.ref(:audio, 0))
      |> child(:muxer, Membrane.FLV.Muxer)
      |> child(:sink, %Membrane.File.Sink{location: output_file}),
      get_child(:source)
      |> via_out(:video)
      |> child(:video_parser, %Membrane.H264.Parser{output_stream_structure: :avc1})
      |> via_in(Pad.ref(:video, 0))
      |> get_child(:muxer)
    ]

    {[spec: structure], %{output_file: output_file, parent: opts[:parent]}}
  end

  @impl true
  def handle_element_end_of_stream(:sink, _pad, _ctx, state) do
    notify_parent(state, {:capture_complete, state.output_file})
    {[terminate: :normal], state}
  end

  @impl true
  def handle_element_end_of_stream(_child, _pad, _ctx, state), do: {[], state}

  defp notify_parent(%{parent: parent}, message), do: send(parent, message)
end
