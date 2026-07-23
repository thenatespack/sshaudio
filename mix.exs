defmodule SSHAudio.MixProject do
  use Mix.Project

  def project do
    [
      app: :sshaudio,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :crypto, :public_key, :ssh],
      mod: {SSHAudio.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:phoenix_pubsub, "~> 2.1"},
      {:id3vx, "~> 0.0.1"}
    ]
  end
end
