defmodule Vdr.Benchmark.Scenarios.StringCommands do
  @moduledoc """
  Benchmark scenario for string commands (SET, DEL).
  """

  @doc """
  Returns scenario configurations for string commands at different intensities.
  """
  def scenarios do
    [
      extreme_intensity()
    ]
  end

  defp extreme_intensity do
    %{
      name: "strings_20k",
      duration_seconds: 5,
      intensity: 20_000,
      command_fn: &generate_command/0,
      reader_count: 4,
      read_fn: &generate_read/0
    }
  end

  # Alternates between SET and DEL commands
  defp generate_command do
    key_num = :rand.uniform(10000)
    key = "str:#{key_num}"

    if :rand.uniform(2) == 1 do
      value = "value_#{:rand.uniform(1000)}"
      ["SET", key, value]
    else
      ["DEL", key]
    end
  end

  # Generates read operations - random string keys
  defp generate_read do
    key_num = :rand.uniform(10000)
    key = "str:#{key_num}"

    read_op = fn vdr_id -> Veidrodelis.get(vdr_id, 0, key) end
    hit_check = fn result -> result != nil end

    {read_op, hit_check}
  end
end
