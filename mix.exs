defmodule Veidrodelis.MixProject do
  use Mix.Project

  @version "0.1.3"
  @github_url "https://github.com/savonarola/veidrodelis"
  @doc_extras [
    "README.md",
    "doc/string-write.md",
    "doc/hash-write.md",
    "doc/list-write.md",
    "doc/set-write.md",
    "doc/sorted-set-write.md",
    "doc/acl.txt",
    "LICENSE"
  ]

  def project do
    [
      app: :veidrodelis,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      description: "In-memory projection of Redis/Valkey data",
      deps: deps(),
      erlc_paths: ["src"],
      compilers: Mix.compilers(),
      erlc_options: [:debug_info],
      elixirc_paths: elixirc_paths(Mix.env()),
      test_coverage: [
        tool: ExCoveralls,
        ignore_paths: ["benchmark", "test", "lib/mix/tasks"]
      ],
      package: [
        files: ~w(lib mix.exs README.md LICENSE),
        licenses: ["Apache-2.0"],
        links: %{
          "GitHub" => @github_url
        }
      ],
      docs: [
        main: "Veidrodelis",
        extras: @doc_extras,
        source_ref: "v#{@version}",
        source_url: @github_url
      ]
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger],
      mod: {Vdr.Application, []}
    ]
  end

  defp deps do
    [
      {:rustler, "~> 0.36", runtime: false},
      {:redix, "~> 1.5", optional: true},
      {:castore, only: [:dev, :test]},
      {:req, "~> 0.5", only: :test},
      {:excoveralls, "~> 0.18", only: :test},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end
end
