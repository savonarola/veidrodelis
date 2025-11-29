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
      compilers: [:elixir_make] ++ Mix.compilers(),
      make_targets: ["all"],
      make_clean: ["clean"],
      # Include Erlang source files
      erlc_options: [:debug_info]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Veidrodelis.Application, []}
    ]
  end

  defp deps do
    [
      {:elixir_make, "~> 0.6", runtime: false},
      {:redix, "~> 1.5", only: :test}
    ]
  end
end
