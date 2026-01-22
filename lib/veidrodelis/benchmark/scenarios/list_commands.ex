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
      name: "lists",
      duration_seconds: 30,
      intensity: 20_000,
      command_fn: &generate_command/0,
      reader_count: 4,
      read_fn: &generate_read/1
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

  # Generates read operations - lrange on random list keys
  defp generate_read(_vdr_id) do
    key_num = :rand.uniform(1000)
    key = "list:#{key_num}"

    read_op = fn vdr_id -> Veidrodelis.lrange(vdr_id, 0, key, 0, 10) end
    hit_check = fn result -> result != [] end

    {read_op, hit_check}
  end
end
