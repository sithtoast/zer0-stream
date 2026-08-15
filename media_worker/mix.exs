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
      {:membrane_hls_plugin, "~> 3.0"},
      {:req, "~> 0.5"},
      {:bandit, "~> 1.5"},
      {:plug, "~> 1.16"}
    ]
  end
end
