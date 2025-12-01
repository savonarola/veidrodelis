defmodule Vdr.Benchmark.Scenarios.SetCommands do
  @moduledoc """
  Benchmark scenario for set commands (SADD, SREM).
  """

  @doc """
  Returns scenario configurations for set commands at different intensities.
  """
  def scenarios do
    [
      extreme_intensity()
    ]
  end

  defp extreme_intensity do
    %{
      name: "sets_20k",
      duration_seconds: 30,
      intensity: 20_000,
      command_fn: &generate_command/0
    }
  end

  # Alternates between SADD and SREM commands
  defp generate_command do
    key_num = :rand.uniform(1000)
    key = "set:#{key_num}"
    member = "member_#{:rand.uniform(1000)}"

    if :rand.uniform(4) == 1 do
      ["SREM", key, member]
    else
      ["SADD", key, member]
    end
  end
end
