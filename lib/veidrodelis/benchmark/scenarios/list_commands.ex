defmodule Vdr.Benchmark.Scenarios.ListCommands do
  @moduledoc """
  Benchmark scenario for list commands (LPUSH, RPUSH, DEL).
  """

  @doc """
  Returns scenario configurations for list commands at different intensities.
  """
  def scenarios do
    [
      extreme_intensity()
    ]
  end

  defp extreme_intensity do
    %{
      name: "lists_20k",
      duration_seconds: 30,
      intensity: 20_000,
      command_fn: &generate_command/0
    }
  end

  # Alternates between LPUSH, RPUSH and DEL commands
  defp generate_command do
    key_num = :rand.uniform(1000)
    key = "list:#{key_num}"

    case :rand.uniform(10) do
      n when n <= 4 ->
        value = "value_#{:rand.uniform(1000)}"
        ["LPUSH", key, value]

      n when n <= 8 ->
        value = "value_#{:rand.uniform(1000)}"
        ["RPUSH", key, value]

      _ ->
        ["DEL", key]
    end
  end
end
