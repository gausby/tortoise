defmodule Tortoise.MixProject do
  use Mix.Project

  def project do
    [
      app: :tortoise,
      version: "0.1.0",
      elixir: "~> 1.6.3",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: dialyzer()
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
      # "~> 2.0"
      {:gen_state_machine, github: "ericentin/gen_state_machine"},
      {:eqc_ex, "~> 1.4"},
      {:dialyxir, "~> 0.5", only: [:dev, :test], runtime: false}
    ]
  end

  defp dialyzer() do
    [
      ignore_warnings: "dialyzer.ignore"
    ]
  end
end
