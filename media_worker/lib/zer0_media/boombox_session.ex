defmodule Zer0Media.BoomboxSession do
  use GenServer

  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      type: :worker
    }
  end

  def relay_url(pid), do: GenServer.call(pid, :relay_url)

  def prewarm do
    executable = System.find_executable("mix") || raise "mix executable not found"
    runtime_dir = System.get_env("BOOMBOX_RUNTIME_DIR", boombox_runtime_dir())
    mix_home = Path.expand("../.mix-boombox", runtime_dir)
    hex_home = Path.expand("../.hex-boombox", runtime_dir)

    Logger.info("Prewarming Boombox runtime")

    case System.cmd(
           executable,
           [
             "run",
             "-e",
             "Application.ensure_all_started(:boombox)"
           ],
           cd: runtime_dir,
           env: [{"MIX_ENV", boombox_mix_env()}, {"MIX_HOME", mix_home}, {"HEX_HOME", hex_home}],
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        Logger.info("Boombox runtime ready")
        :ok

      {output, status} ->
        raise "Boombox prewarm failed with status #{status}: #{output}"
    end
  end

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    port = Keyword.get(opts, :port, free_port())
    input_url = "rtmp://127.0.0.1:#{port}/live/#{session_id}"
    output_dir = Path.join(boombox_hls_dir(), "stream-session-#{session_id}")
    output = Path.join(output_dir, "master.m3u8")
    File.mkdir_p!(Path.dirname(output))

    executable = System.find_executable("mix") || raise "mix executable not found"
    runtime_dir = System.get_env("BOOMBOX_RUNTIME_DIR", boombox_runtime_dir())

    port_handle =
      Port.open({:spawn_executable, executable}, [
        :binary,
        {:args,
         ["run", "--no-compile", "--no-deps-check", "--no-halt", "-e", "Zer0Boombox.run()"]},
        {:cd, runtime_dir},
        {:env,
         [
           {~c"MIX_ENV", String.to_charlist(boombox_mix_env())},
           {~c"MIX_HOME", String.to_charlist(Path.expand("../.mix-boombox", runtime_dir))},
           {~c"HEX_HOME", String.to_charlist(Path.expand("../.hex-boombox", runtime_dir))},
           {~c"BOOMBOX_INPUT_URL", String.to_charlist(input_url)},
           {~c"BOOMBOX_OUTPUT", String.to_charlist(output)}
         ]}
      ])

    await_listener!(port)
    Logger.info("Boombox session #{session_id} starting on #{input_url}")
    {:ok, %{port: port_handle, relay_url: input_url, output: output}}
  end

  @impl true
  def handle_call(:relay_url, _from, state), do: {:reply, state.relay_url, state}

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    Logger.debug("Boombox[#{state.relay_url}]: #{String.trim(data)}")
    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.error("Boombox exited with status #{status}: #{state.relay_url}")
    {:stop, {:boombox_exit, status}, state}
  end

  @impl true
  def terminate(_reason, %{port: port, output: output}) do
    if Port.info(port), do: Port.close(port)
    Zer0Media.HLSCleanup.schedule(Path.dirname(output))
    :ok
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(socket)
    :gen_tcp.close(socket)
    port
  end

  defp boombox_hls_dir do
    Application.get_env(:zer0_media, :boombox_hls_dir, Path.join(File.cwd!(), "priv/hls-boombox"))
  end

  defp boombox_runtime_dir do
    Path.expand("../boombox_runtime", File.cwd!())
  end

  defp boombox_mix_env do
    System.get_env("BOOMBOX_MIX_ENV", System.get_env("MIX_ENV", "dev"))
  end

  defp await_listener!(port, attempts \\ 300)

  defp await_listener!(_port, 0), do: raise("Boombox RTMP listener did not become ready")

  defp await_listener!(port, attempts) do
    case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 100) do
      {:ok, socket} ->
        :gen_tcp.close(socket)

      {:error, _reason} ->
        Process.sleep(100)
        await_listener!(port, attempts - 1)
    end
  end
end
