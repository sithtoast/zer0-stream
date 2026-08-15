defmodule Zer0Media.HLSPipeline do
  use Membrane.Pipeline

  @audio_group_id "AUDIO"

  @impl true
  def handle_init(_ctx, opts) do
    output_dir = Keyword.fetch!(opts, :output_dir)
    storage = HLS.Storage.File.new(base_dir: output_dir)
    segment_duration = configured_duration(:hls_segment_duration, Membrane.Time.seconds(30))
    safety_delay = configured_duration(:hls_safety_delay, segment_duration)
    audio_rate = configured_rate(:aac_timestamp_rate, 1.0)

    # The muxer only cuts a segment at the next keyframe AFTER segment_duration is
    # reached, so a real segment is always segment_duration + up to one GOP long.
    # The packager separately enforces target_segment_duration as a hard RFC 8216
    # ceiling and rejects any segment exceeding it, so the ceiling must be given
    # real headroom above the cut trigger or every segment eventually gets rejected
    # regardless of encoder/GOP jitter. Default margin doubles the cut trigger.
    target_segment_duration =
      configured_duration(:hls_target_segment_duration, segment_duration * 2)

    structure = [
      child(:source, %Membrane.RTMP.SourceBin{client_ref: opts[:client_ref]})
      |> via_out(:audio)
      |> child(:audio_normalizer, %Zer0Media.AudioTimestampNormalizer{rate: audio_rate})
      |> child(:audio_parser, %Membrane.AAC.Parser{
        out_encapsulation: :none,
        output_config: :esds
      })
      |> via_in(Pad.ref(:input, 1),
        options: [
          encoding: :AAC,
          segment_duration: segment_duration,
          build_stream: fn _format ->
            %HLS.AlternativeRendition{
              type: :audio,
              group_id: @audio_group_id,
              name: "audio",
              language: "und",
              autoselect: true,
              default: true
            }
          end
        ]
      )
      |> get_child(:hls),
      get_child(:source)
      |> via_out(:video)
      |> child(:video_parser, %Membrane.H264.Parser{output_stream_structure: :avc1})
      |> via_in(Pad.ref(:input, 0),
        options: [
          encoding: :H264,
          segment_duration: segment_duration,
          build_stream: fn _format -> %HLS.VariantStream{audio: @audio_group_id} end
        ]
      )
      |> get_child(:hls),
      child(:hls, %Membrane.HLS.SinkBin{
        storage: storage,
        manifest_uri: URI.parse("master.m3u8"),
        playlist_mode: {:event, safety_delay},
        target_segment_duration: target_segment_duration,
        trim_align?: true
      })
    ]

    {[spec: structure], %{parent: opts[:parent], output_dir: output_dir}}
  end

  @impl true
  def handle_element_end_of_stream(:hls, _pad, _ctx, state) do
    send(state.parent, {:hls_complete, state.output_dir})
    {[terminate: :normal], state}
  end

  @impl true
  def handle_element_end_of_stream(_child, _pad, _ctx, state), do: {[], state}

  defp configured_duration(key, default) do
    value =
      Application.get_env(:zer0_media, key) ||
        System.get_env(key |> Atom.to_string() |> String.upcase())

    case value do
      nil -> default
      value when is_integer(value) -> value
      value -> String.to_integer(value)
    end
  end

  defp configured_rate(key, default) do
    value =
      Application.get_env(:zer0_media, key) ||
        System.get_env(key |> Atom.to_string() |> String.upcase())

    case value do
      nil ->
        default

      value when is_number(value) ->
        value * 1.0

      value when is_binary(value) ->
        case Float.parse(value) do
          {parsed, _rest} -> parsed
          :error -> default
        end
    end
  end
end
