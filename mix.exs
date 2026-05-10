defmodule Veidrodelis.MixProject do
  use Mix.Project

  @version "0.1.7"
  @github_url "https://github.com/savonarola/veidrodelis"
  @doc_extras [
    "doc/about.md",
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
        files:
          ~w(lib mix.exs README.md LICENSE) ++
            ~w(native/vdr_redis_nif/Cargo.toml native/vdr_redis_nif/Cargo.lock native/vdr_redis_nif/build.rs native/vdr_redis_nif/src native/vdr_redis_nif/c_src) ++
            ~w(native/vdr_ts_nif/Cargo.toml native/vdr_ts_nif/Cargo.lock native/vdr_ts_nif/src),
        licenses: ["Apache-2.0"],
        links: %{
          "GitHub" => @github_url
        }
      ],
      docs: [
        main: "about",
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
        "coveralls.html": :test,
        "coveralls.lcov": :test,
        "coveralls.multiple": :test
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
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:req, "~> 0.5", only: :test},
      {:excoveralls, "~> 0.18", only: :test},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end
end
