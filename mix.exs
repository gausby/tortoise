defmodule Tortoise.MixProject do
  use Mix.Project

  @version "0.9.2"

  def project do
    [
      app: :tortoise,
      version: @version,
      elixir: "~> 1.6",
      start_permanent: Mix.env() == :prod,
      description: description(),
      package: package(),
      deps: deps(),
      dialyzer: dialyzer(),
      docs: docs(),
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.html": :test,
        "coveralls.json": :test,
        "coveralls.post": :test,
        docs: :docs
      ],
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  defp description() do
    """
    A MQTT client for Elixir.
    """
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :ssl],
      mod: {Tortoise.App, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:gen_state_machine, "~> 2.0"},
      {:dialyxir, "~> 1.0.0-rc.3", only: [:dev], runtime: false},
      {:eqc_ex, "~> 1.4", only: :test},
      {:excoveralls, "~> 0.10", only: :test},
      {:ex_doc, "~> 0.19", only: :docs},
      {:ct_helper, github: "ninenines/ct_helper", only: :test}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp package() do
    [
      maintainers: ["Martin Gausby"],
      licenses: ["Apache 2.0"],
      files: ["lib", "mix.exs", "README*", "CHANGELOG*", "LICENSE*"],
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
        "docs/introduction.md",
        "docs/connecting_to_a_mqtt_broker.md",
        "docs/connection_supervision.md",
        "docs/publishing_messages.md"
      ]
    ]
  end

  defp dialyzer() do
    [
      ignore_warnings: "dialyzer.ignore",
      flags: [:error_handling, :race_conditions, :underspecs]
    ]
  end
end
