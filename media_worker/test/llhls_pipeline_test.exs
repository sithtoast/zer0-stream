Code.require_file("support/llhls_fixture_source.ex", __DIR__)

defmodule Zer0Media.LLHLSPipelineTest do
  use ExUnit.Case, async: false
  alias Zer0Media.LLHLS.{Origin, Stream}

  test "production LivePipeline packages real AAC/H264 into playable CMAF parts and segments" do
    session = Integer.to_string(System.unique_integer([:positive]))
    output = Path.join(System.tmp_dir!(), "zer0-llhls-pipeline-#{session}")
    File.mkdir_p!(output)
    previous = Application.get_env(:zer0_media, :llhls_dir)
    Application.put_env(:zer0_media, :llhls_dir, Path.join(output, "llhls"))

    on_exit(fn ->
      if previous,
        do: Application.put_env(:zer0_media, :llhls_dir, previous),
        else: Application.delete_env(:zer0_media, :llhls_dir)

      File.rm_rf!(output)
    end)

    config = %{Zer0Media.MediaConfig.llhls() | enabled?: true}

    pipeline =
      Membrane.Testing.Pipeline.start_link_supervised!(
        module: Zer0Media.LivePipeline,
        custom_args: [
          client_ref: self(),
          output_dir: output,
          parent: self(),
          session_id: session,
          source: %Zer0Media.Test.LLHLSFixtureSource{
            directory: Path.expand("fixtures/llhls", __DIR__)
          },
          llhls: config
        ]
      )

    assert_receive {:hls_complete, ^output}, 10_000
    origin = Origin.current(session)
    assert is_pid(origin)
    info = Origin.info(origin)
    assert info.status == :ended
    assert info.ready?
    refute info.master =~ "token="
    assert info.master =~ "video/index.m3u8"

    on_exit(fn ->
      if Process.alive?(origin) do
        {:dictionary, dictionary} = Process.info(origin, :dictionary)
        [supervisor | _] = Keyword.fetch!(dictionary, :"$ancestors")
        DynamicSupervisor.terminate_child(Zer0Media.LLHLS.Supervisor, supervisor)
      end
    end)

    for rendition <- ["audio", "video"] do
      {:ok, stream, directory} = Origin.track(origin, rendition)
      assert {:ok, body} = Stream.await(stream)
      assert body =~ "#EXT-X-PART:"
      assert body =~ "#EXT-X-ENDLIST"
      assert {:ok, parsed} = ExM3U8.deserialize_media_playlist(body)
      segments = Enum.filter(parsed.timeline, &match?(%ExM3U8.Tags.Segment{}, &1))
      assert length(segments) >= 3
      model = :sys.get_state(stream).model
      assert model.ended?

      for segment <- model.segments do
        bytes = File.read!(Path.join(directory, segment.uri))
        parts = Enum.map(segment.parts, &File.read!(Path.join(directory, &1.uri)))
        assert bytes == IO.iodata_to_binary(parts)
        assert bytes =~ "moof"
        assert bytes =~ "mdat"
        assert segment.duration == Enum.sum(Enum.map(segment.parts, & &1.duration))
        assert Enum.all?(segment.parts, &(&1.duration <= model.part_target))
      end

      legacy = File.read!(Path.join(output, rendition <> ".m3u8"))
      refute legacy =~ "#EXT-X-PART"
      refute legacy =~ "CAN-BLOCK-RELOAD"
      assert {:ok, _} = ExM3U8.deserialize_media_playlist(legacy)
      validate_with_ffprobe(directory, model, rendition, output)
    end

    refute Process.alive?(pipeline)
  end

  defp validate_with_ffprobe(directory, model, rendition, output) do
    if executable = System.find_executable("ffprobe") do
      assembled = Path.join(output, rendition <> "-validation.mp4")

      bytes = [
        File.read!(Path.join(directory, "init.mp4"))
        | Enum.map(model.segments, &File.read!(Path.join(directory, &1.uri)))
      ]

      File.write!(assembled, bytes)

      {json, 0} =
        System.cmd(executable, [
          "-v",
          "error",
          "-count_frames",
          "-show_streams",
          "-show_packets",
          "-of",
          "json",
          assembled
        ])

      probe = Jason.decode!(json)
      [track] = probe["streams"]
      assert track["codec_name"] == if(rendition == "video", do: "h264", else: "aac")
      frames = String.to_integer(track["nb_read_frames"])
      if rendition == "video", do: assert(frames == 180), else: assert(frames >= 281)

      if rendition == "video" do
        # The fixture's two-second GOP must survive the real muxer boundary.
        keys = Enum.filter(probe["packets"], &String.contains?(&1["flags"], "K"))
        assert length(keys) == 3
        assert Enum.all?(model.segments, &hd(&1.parts).independent?)
      end

      timestamps = Enum.map(probe["packets"], & &1["dts"])
      assert timestamps == Enum.sort(timestamps)
      assert length(timestamps) == length(Enum.uniq(timestamps))
    end
  end
end
