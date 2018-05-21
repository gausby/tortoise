defmodule Tortoise.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :tortoise,
      version: @version,
      elixir: "~> 1.6.5",
      start_permanent: Mix.env() == :prod,
      description: description(),
      package: package(),
      deps: deps(),
      dialyzer: dialyzer(),
      docs: docs(),
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env:
        cli_env_for(:test, [
          "coveralls",
          "coveralls.detail",
          "coveralls.html",
          "coveralls.json",
          "coveralls.post"
        ])
    ]
  end

  defp description() do
    """
    A MQTT client for Elixir.
    """
  end

  defp cli_env_for(env, tasks) do
    Enum.reduce(tasks, [], fn key, acc -> Keyword.put(acc, :"#{key}", env) end)
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
      {:excoveralls, "~> 0.8", only: :test},
      {:ex_doc, "~> 0.18", only: :docs}
    ]
  end

  defp package() do
    [
      maintainers: ["Martin Gausby"],
      licenses: ["Apache 2.0"],
      files: ["lib", "priv", "mix.exs", "README*", "CHANGELOG*", "LICENSE*", "license*"],
      links: %{"GitHub" => "https://github.com/gausby/tortoise"}
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
