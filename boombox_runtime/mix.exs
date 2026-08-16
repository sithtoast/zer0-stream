defmodule Zer0Boombox.MixProject do
  use Mix.Project

  def project do
    [
      app: :zer0_boombox,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:boombox, "~> 0.2.13"},
      {:vix, "~> 0.40.0"}
    ]
  end
end
