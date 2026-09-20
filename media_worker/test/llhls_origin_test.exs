defmodule Zer0Media.LLHLS.OriginTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn
  alias Zer0Media.LLHLS.{Origin, Storage, Stream, LocalStore, Router}
  @part 200_000_000

  setup do
    session = Integer.to_string(System.unique_integer([:positive]))
    root = Path.join(System.tmp_dir!(), "zer0-origin-#{session}")
    previous = Application.get_env(:zer0_media, :llhls_dir)
    Application.put_env(:zer0_media, :llhls_dir, root)

    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    config = %{Zer0Media.MediaConfig.llhls() | enabled?: true, target_duration: 2_000_000_000}
    {:ok, origin} = Origin.start_generation(session, owner, Path.join(root, "legacy"), config)
    info = Origin.info(origin)
    storage = Storage.init(%Storage{directory: Path.join(root, "legacy"), origin: origin})

    storage =
      Enum.reduce([:audio, :video], storage, fn track, storage ->
        {:ok, storage} =
          Storage.store(
            track,
            "#{track}_init.mp4",
            "init-#{track}",
            %{},
            %{type: :header},
            storage
          )

        storage
      end)

    on_exit(fn ->
      stop_generation(origin)
      Process.exit(owner, :kill)

      if previous,
        do: Application.put_env(:zer0_media, :llhls_dir, previous),
        else: Application.delete_env(:zer0_media, :llhls_dir)

      File.rm_rf!(root)
    end)

    %{
      session: session,
      root: root,
      origin: origin,
      owner: owner,
      config: config,
      storage: storage,
      base: "/llhls/#{session}/#{info.generation}",
      token: token(session)
    }
  end

  test "atomic objects cannot be overwritten and incomplete temporary files are never published",
       ctx do
    path = Path.join(ctx.root, "object.m4s")
    assert :ok = LocalStore.put(path, "whole-part")
    assert {:error, :eexist} = LocalStore.put(path, "replacement")
    assert File.read!(path) == "whole-part"
    assert Path.wildcard(path <> ".tmp-*") == []
    assert :ok = LocalStore.put(path, "new-manifest", :replace)
    assert File.read!(path) == "new-manifest"
  end

  test "storage publishes bytes before releasing a blocked playlist and object request", ctx do
    {:ok, stream, directory} = Origin.track(ctx.origin, :video)
    playlist = :gen_server.send_request(stream, {:await, 0, 0, :default})
    object = :gen_server.send_request(stream, {:await_part, 0, 0, :default})
    assert %{waiters: 2} = Stream.stats(stream)
    _storage = part(ctx.storage, :video, 0)
    assert {:reply, {:ok, body}} = :gen_server.receive_response(playlist, 2000)
    assert body =~ "part-0-0.m4s"
    assert {:reply, {:ok, :available}} = :gen_server.receive_response(object, 2000)
    assert File.read!(Path.join(directory, "part-0-0.m4s")) == "part-0"
    assert %{waiters: 0} = Stream.stats(stream)
  end

  test "startup playlist waits for first media and guessed future objects fail immediately",
       ctx do
    {:ok, stream, _} = Origin.track(ctx.origin, :video)
    pending = :gen_server.send_request(stream, {:await, nil, nil, :default})
    assert %{waiters: 1} = Stream.stats(stream)
    assert {:error, :not_found} = Stream.await_part(stream, 2, 0)
    _storage = part(ctx.storage, :video, 0)
    assert {:reply, {:ok, _}} = :gen_server.receive_response(pending, 2000)
  end

  test "an unmaterialized hint returns not-found on segment rollover rather than another part",
       ctx do
    storage = part(ctx.storage, :video, 0)
    {:ok, stream, _} = Origin.track(ctx.origin, :video)
    hint = :gen_server.send_request(stream, {:await_part, 0, 1, :default})
    reload = :gen_server.send_request(stream, {:await, 0, 1, :default})
    assert %{waiters: 2} = Stream.stats(stream)
    storage = segment(storage, :video, 0)
    assert {:reply, {:error, :not_found}} = :gen_server.receive_response(hint, 2000)
    assert %{waiters: 1} = Stream.stats(stream)
    _storage = part(storage, :video, 0)
    assert {:reply, {:ok, _}} = :gen_server.receive_response(reload, 2000)
  end

  test "invalid byte offsets and reconfiguration fail closed", ctx do
    assert {{:error, :out_of_order}, _} =
             Storage.store(
               :video,
               "video_0.m4s",
               "bytes",
               %{sequence_number: 0, byte_offset: 9, duration: @part, independent?: true},
               %{type: :partial_segment},
               ctx.storage
             )

    assert {{:error, :codec_change_requires_new_generation}, _} =
             Storage.store(:video, "new_init.mp4", "new", %{}, %{type: :header}, ctx.storage)

    storage = part(ctx.storage, :video, 0)

    assert {{:error, :invalid_segment}, _} =
             Storage.store(
               :video,
               "video_0.m4s",
               "wrong",
               %{sequence_number: 0, duration: @part},
               %{type: :segment},
               storage
             )
  end

  test "HTTP authorizes before registering waits and returns bounded directive errors", ctx do
    path = ctx.base <> "/video/index.m3u8?_HLS_msn=0&_HLS_part=0"
    assert request(:get, path, nil).status == 401
    assert request(:get, path, token("999999999")).status == 401
    {:ok, stream, _} = Origin.track(ctx.origin, :video)
    assert %{waiters: 0} = Stream.stats(stream)

    for query <- [
          "_HLS_part=0",
          "_HLS_msn=-1",
          "_HLS_msn=1&_HLS_msn=2",
          "_HLS_msn=9999",
          "_HLS_msn=0&_HLS_part=999",
          "_HLS_msn=1.0"
        ] do
      response = request(:get, ctx.base <> "/video/index.m3u8?" <> query, ctx.token)
      assert response.status == 400
      assert get_resp_header(response, "cache-control") == ["private, no-store"]
    end

    assert request(:get, ctx.base <> "/video/part-2-0.m4s", ctx.token).status == 404
    assert request(:get, ctx.base <> "/video/private.txt", ctx.token).status == 404
  end

  test "blocking HTTP response is awakened by actual storage publication", ctx do
    {:ok, stream, _} = Origin.track(ctx.origin, :video)
    watch_waits(stream)

    pending =
      Task.async(fn ->
        request(:get, ctx.base <> "/video/index.m3u8?_HLS_msn=0&_HLS_part=0", ctx.token)
      end)

    assert_receive :waiting
    _storage = part(ctx.storage, :video, 0)
    response = Task.await(pending)
    assert response.status == 200
    assert response.resp_body =~ "#EXT-X-PART:"
    refute response.resp_body =~ "viewer_id"
    refute response.resp_body =~ "token="
    # Media fetches deliberately do not update viewer accounting.
    assert Zer0Media.ViewerTracker.count(ctx.session).viewer_count == 0
  end

  test "hinted HTTP objects block, then return a complete immutable body", ctx do
    {:ok, stream, _} = Origin.track(ctx.origin, :video)
    watch_waits(stream)
    pending = Task.async(fn -> request(:get, ctx.base <> "/video/part-0-0.m4s", ctx.token) end)
    assert_receive :waiting
    _storage = part(ctx.storage, :video, 0)
    response = Task.await(pending)
    assert response.status == 200
    assert response.resp_body == "part-0"
    assert get_resp_header(response, "cache-control") == ["private, max-age=3600, immutable"]
  end

  test "blocking HTTP timeout returns 503 and frees its waiter", ctx do
    {:ok, stream, _} = Origin.track(ctx.origin, :video)
    watch_waits(stream)

    pending =
      Task.async(fn ->
        request(:get, ctx.base <> "/video/index.m3u8?_HLS_msn=0&_HLS_part=0", ctx.token)
      end)

    assert_receive :waiting
    [ref] = Map.keys(:sys.get_state(stream).waiters)
    send(stream, {:wait_timeout, ref})
    assert Task.await(pending).status == 503
    assert %{waiters: 0} = Stream.stats(stream)
  end

  test "session cookie is scoped and heartbeat identity is separate from media transport", ctx do
    storage = ctx.storage |> part(:video, 0) |> part(:audio, 0)

    {:ok, _storage} =
      Storage.store(
        :master,
        "master.m3u8",
        "#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"audio\",URI=\"audio.m3u8\"\n#EXT-X-STREAM-INF:BANDWIDTH=100000,AUDIO=\"audio\"\nvideo.m3u8\n",
        %{},
        %{type: :manifest},
        storage
      )

    response = request(:post, "/llhls/#{ctx.session}/session", ctx.token)
    assert response.status == 200
    assert response.resp_cookies["zer0_llhls"].path == "/llhls/#{ctx.session}/"
    assert response.resp_cookies["zer0_llhls"].secure
    assert response.resp_cookies["zer0_llhls"].http_only
    assert Jason.decode!(response.resp_body)["url"] == ctx.base <> "/master.m3u8"
    assert Zer0Media.ViewerTracker.count(ctx.session).viewer_count == 1

    media =
      conn(:get, ctx.base <> "/video/index.m3u8")
      |> put_req_cookie("zer0_llhls", ctx.token)
      |> Zer0Media.HLSRouter.call([])

    assert media.status == 200
    heartbeat = request(:post, "/llhls/#{ctx.session}/heartbeat", ctx.token)
    assert heartbeat.status == 204
    assert Zer0Media.ViewerTracker.count(ctx.session).viewer_count == 1
    assert request(:post, "/llhls/#{ctx.session}/session", nil).status == 401
  end

  test "allowed CORS origins permit credentialed clients; other origins cannot open sessions",
       ctx do
    conn =
      conn(:options, "/llhls/#{ctx.session}/session")
      |> put_req_header("origin", "http://localhost:4000")
      |> Zer0Media.HLSRouter.call([])

    assert conn.status == 204
    assert get_resp_header(conn, "access-control-allow-credentials") == ["true"]

    forbidden =
      conn(:post, "/llhls/#{ctx.session}/session")
      |> put_req_header("origin", "https://untrusted.example")
      |> put_req_header("authorization", "Bearer " <> ctx.token)
      |> Zer0Media.HLSRouter.call([])

    assert forbidden.status == 403
  end

  test "lost publisher drains requests and reconnect gets fresh isolated URLs", ctx do
    {:ok, old_stream, _} = Origin.track(ctx.origin, :video)
    pending = :gen_server.send_request(old_stream, {:await, 0, 0, :default})
    assert %{waiters: 1} = Stream.stats(old_stream)
    send(ctx.owner, :stop)
    assert {:reply, {:error, reason}} = :gen_server.receive_response(pending, 2000)
    assert reason in [:publisher_down, :terminated]

    {:ok, fresh} =
      Origin.start_generation(ctx.session, self(), Path.join(ctx.root, "legacy-2"), ctx.config)

    on_exit(fn -> stop_generation(fresh) end)
    assert Origin.info(fresh).generation != Origin.info(ctx.origin).generation
    assert Origin.current(ctx.session) == fresh
    assert request(:get, ctx.base <> "/video/index.m3u8", ctx.token).status == 503
  end

  test "retirement defers deletion and cannot remove another generation", ctx do
    own = Path.join(Origin.info(ctx.origin).directory, "old-part.m4s")
    File.write!(own, "retained")
    assert :ok = Origin.retire(ctx.origin, [own])
    assert File.exists?(own)
    [ref] = Map.keys(:sys.get_state(ctx.origin).retired)
    send(ctx.origin, {:retire, ref})
    _ = Origin.info(ctx.origin)
    refute File.exists?(own)
    assert {:error, :invalid_path} = Origin.retire(ctx.origin, [Path.join(ctx.root, "elsewhere")])
  end

  test "the network server supports blocking playlist reload", ctx do
    server = start_supervised!({Bandit, plug: Zer0Media.HLSRouter, port: 0})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    {:ok, stream, _} = Origin.track(ctx.origin, :video)
    watch_waits(stream)

    pending =
      Task.async(fn ->
        Req.get!(
          "http://127.0.0.1:#{port}" <> ctx.base <> "/video/index.m3u8?_HLS_msn=0&_HLS_part=0",
          headers: [{"authorization", "Bearer " <> ctx.token}],
          retry: false
        )
      end)

    assert_receive :waiting, 2000
    _storage = part(ctx.storage, :video, 0)
    response = Task.await(pending)
    assert response.status == 200
    assert response.body =~ "part-0-0.m4s"
    assert %{waiters: 0} = Stream.stats(stream)
  end

  test "noncanonical object names never register hinted waits", ctx do
    for name <- [
          "part-00-0.m4s",
          "part-0-00.m4s",
          "part-18446744073709551616-0.m4s",
          "segment-00.m4s"
        ] do
      assert request(:get, ctx.base <> "/video/" <> name, ctx.token).status == 404
    end

    {:ok, stream, _} = Origin.track(ctx.origin, :video)
    assert %{waiters: 0} = Stream.stats(stream)
  end

  test "final playlists ignore delivery directives and expire before their objects", ctx do
    storage =
      ctx.storage
      |> part(:video, 0)
      |> segment(:video, 0)
      |> part(:audio, 0)
      |> segment(:audio, 0)

    for track <- [:video, :audio] do
      assert {:ok, _} =
               Storage.store(
                 track,
                 "#{track}.m3u8",
                 "#EXTM3U\n#EXT-X-ENDLIST\n",
                 %{},
                 %{type: :manifest},
                 storage
               )
    end

    assert Origin.info(ctx.origin).status == :ended

    response =
      request(:get, ctx.base <> "/video/index.m3u8?_HLS_msn=invalid&_HLS_part=-1", ctx.token)

    assert response.status == 200
    assert response.resp_body =~ "#EXT-X-ENDLIST"
    assert request(:post, "/llhls/#{ctx.session}/heartbeat", ctx.token).status == 410
    send(ctx.origin, :cleanup)
    assert Origin.info(ctx.origin).status == :retired
    assert request(:get, ctx.base <> "/video/index.m3u8", ctx.token).status == 503
    assert request(:get, ctx.base <> "/video/segment-0.m4s", ctx.token).status == 200
    directory = Origin.info(ctx.origin).directory
    ref = Process.monitor(ctx.origin)
    send(ctx.origin, :cleanup)
    assert_receive {:DOWN, ^ref, :process, _, :normal}
    refute File.exists?(directory)
  end

  test "lost rendition fails its generation without disturbing another publisher", ctx do
    {:ok, other} =
      Origin.start_generation(
        "9" <> ctx.session,
        self(),
        Path.join(ctx.root, "other"),
        ctx.config
      )

    on_exit(fn -> stop_generation(other) end)
    {:ok, audio, _} = Origin.track(ctx.origin, :audio)
    {:ok, video, _} = Origin.track(ctx.origin, :video)
    pending = :gen_server.send_request(audio, {:await, 0, 0, :default})
    assert %{waiters: 1} = Stream.stats(audio)
    Process.exit(video, :kill)
    assert {:reply, {:error, :terminated}} = :gen_server.receive_response(pending, 2000)
    assert Origin.info(ctx.origin).status == :failed
    assert Origin.info(other).status == :live
    {:ok, other_stream, _} = Origin.track(other, :video)
    assert Process.alive?(other_stream)
  end

  test "directive parser rejects duplicates and overflow without allocating a waiter" do
    assert {:ok, 0, 1} = Router.directives("_HLS_msn=0&_HLS_part=1")
    assert {:error, :invalid_request} = Router.directives("_HLS_msn=18446744073709551616")
    assert {:error, :invalid_request} = Router.directives(String.duplicate("x", 2049))
  end

  defp part(storage, track, index) do
    current = storage.tracks[track]

    {:ok, storage} =
      Storage.store(
        track,
        "#{track}_#{current.msn}.m4s",
        "part-#{index}",
        %{
          sequence_number: index,
          byte_offset: current.bytes,
          duration: @part,
          independent?: index == 0
        },
        %{type: :partial_segment},
        storage
      )

    storage
  end

  defp segment(storage, track, msn) do
    current = storage.tracks[track]

    {:ok, storage} =
      Storage.store(
        track,
        "#{track}_#{msn}.m4s",
        "part-0",
        %{sequence_number: msn, duration: current.duration},
        %{type: :segment},
        storage
      )

    storage
  end

  defp request(method, path, token) do
    conn = conn(method, path)
    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
    Zer0Media.HLSRouter.call(conn, [])
  end

  defp token(session) do
    payload = "v2:#{session}:#{System.system_time(:second) + 60}:fixture"

    signature =
      :crypto.mac(
        :hmac,
        :sha256,
        System.get_env("PLAYBACK_TOKEN_SECRET", "dev-playback-secret"),
        payload
      )
      |> Base.url_encode64(padding: false)

    Base.url_encode64(payload <> ":" <> signature, padding: false)
  end

  defp watch_waits(stream) do
    ref = make_ref()

    :ok =
      :telemetry.attach(
        ref,
        [:zer0_media, :llhls, :wait_start],
        &__MODULE__.wait_started/4,
        {self(), stream}
      )

    on_exit(fn -> :telemetry.detach(ref) end)
  end

  def wait_started(_event, _measurements, _metadata, {parent, stream}) do
    if self() == stream, do: send(parent, :waiting)
  end

  defp stop_generation(origin) do
    if Process.alive?(origin) do
      # The generation supervisor is the origin's OTP parent.
      {:dictionary, dictionary} = Process.info(origin, :dictionary)
      [supervisor | _] = Keyword.fetch!(dictionary, :"$ancestors")
      DynamicSupervisor.terminate_child(Zer0Media.LLHLS.Supervisor, supervisor)
    end
  end
end
