defmodule Tortoise.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :tortoise,
      version: @version,
      elixir: "~> 1.6.5",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: dialyzer(),
      docs: docs()
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
      {:gen_state_machine, "~> 2.0.2"},
      {:eqc_ex, "~> 1.4"},
      {:dialyxir, "~> 0.5", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.18", only: :docs}
    ]
  end

  defp docs() do
    [
      name: "Tortoise",
      source_ref: "v#{@version}",
      main: "introduction",
      canonical: "http://hexdocs.pm/tortoise",
      source_url: "https://github.com/gausby/tortoise",
      extras: [
        "docs/introduction.md"
      ]
    ]
  end

  defp dialyzer() do
    [
      ignore_warnings: "dialyzer.ignore"
    ]
  end
end
