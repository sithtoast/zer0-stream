defmodule Zer0Media.Test.LLHLSFixtureSource do
  use Membrane.Bin
  def_options(directory: [])
  def_output_pad(:audio, accepted_format: _any)
  def_output_pad(:video, accepted_format: _any)

  @impl true
  def handle_init(_ctx, opts) do
    spec = [
      child(:audio, %Membrane.File.Source{location: Path.join(opts.directory, "audio.aac")})
      |> child(:audio_parser, %Membrane.AAC.Parser{out_encapsulation: :ADTS})
      |> bin_output(:audio),
      child(:video, %Membrane.File.Source{location: Path.join(opts.directory, "video.h264")})
      |> child(:video_parser, %Membrane.H264.Parser{
        output_stream_structure: :avc1,
        generate_best_effort_timestamps: %{framerate: {30, 1}, add_dts_offset: false}
      })
      |> bin_output(:video)
    ]

    {[spec: spec], %{}}
  end
end
