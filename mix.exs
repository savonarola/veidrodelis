defmodule Veidrodelis.MixProject do
  use Mix.Project

  def project do
    [
      app: :veidrodelis,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      erlc_paths: ["src"],
      compilers: Mix.compilers(),
      erlc_options: [:debug_info],
      elixirc_paths: elixirc_paths(Mix.env())
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
      {:redix, "~> 1.5", only: [:dev, :test]},
      {:castore, only: [:dev, :test]},
      {:req, "~> 0.5", only: :test}
    ]
  end
end
