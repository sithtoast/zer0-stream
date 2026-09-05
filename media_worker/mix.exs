defmodule Zer0Media.MixProject do
  use Mix.Project

  def project do
    [
      app: :zer0_media,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Zer0Media.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:membrane_rtmp_plugin, "~> 0.29.5"},
      {:membrane_http_adaptive_stream_plugin, "~> 0.20"},
      {:membrane_webrtc_plugin, "~> 0.26"},
      {:membrane_tee_plugin, "~> 0.12"},
      {:membrane_opus_plugin, "~> 0.20"},
      {:membrane_aac_fdk_plugin, "~> 0.18"},
      {:req, "~> 0.5"},
      {:bandit, "~> 1.5"},
      {:plug, "~> 1.16"},
      # Override transitive ex_ice ~> 0.13.0 pinned by ex_webrtc/membrane_webrtc_plugin:
      # 0.16.0 fixes a crash on TURN refresh_permission send errors
      # (handle_ex_turn_msg badmatch on {:error, :closed}) that was killing
      # long-running WebRTC sessions in production. The vendored 0.16.1 also
      # preserves TURN routing when a successful check reports a different mapped address.
      {:ex_ice, path: "vendor/ex_ice", override: true}
    ]
  end
end
