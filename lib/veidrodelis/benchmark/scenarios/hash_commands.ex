defmodule Vdr.Benchmark.Scenarios.HashCommands do
  @moduledoc """
  Benchmark scenario for hash commands (HSET, HDEL).
  """

  @doc """
  Returns scenario configurations for hash commands at different intensities.
  """
  def scenarios do
    [
      %{
        name: "hashes_100k",
        duration_seconds: 120,
        intensity: 100_000,
        command_fn: &generate_command/0
      },
      %{
        name: "hashes_50k",
        duration_seconds: 60,
        intensity: 50_000,
        command_fn: &generate_command/0
      }
    ]
  end


  # Alternates between HSET and HDEL commands
  defp generate_command do
    key_num = :rand.uniform(1000)
    key = "hash:#{key_num}"
    field = "field_#{:rand.uniform(100)}"

    if :rand.uniform(3) == 1 do
      ["HDEL", key, field]
    else
      value = "value_#{:rand.uniform(1000)}"
      ["HSET", key, field, value]
    end
  end
end
