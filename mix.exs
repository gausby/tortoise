defmodule Tortoise.MixProject do
  use Mix.Project

  def project do
    [
      app: :tortoise,
      version: "0.1.0",
      elixir: "~> 1.6.3",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Tortoise.App, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:gen_state_machine, "~> 2.0"},
      {:eqc_ex, "~> 1.4"},
      {:dialyxir, "~> 0.5", only: [:dev, :test], runtime: false}
    ]
  end
end
