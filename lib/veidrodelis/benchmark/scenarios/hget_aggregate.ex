defmodule Vdr.Benchmark.Scenarios.HgetAggregate do
  @moduledoc false

  @hash_count 1000
  @fields_per_hash 1000
  @commands_per_read 10

  def scenarios do
    [
      %{
        name: "hget_aggregate",
        duration_seconds: 120,
        intensity: 100_000,
        command_fn: &generate_command/0,
        reader_count: 1,
        read_fn: &generate_read/1
      }
    ]
  end

  defp generate_command do
    hash_num = :rand.uniform(@hash_count)
    field_num = :rand.uniform(@fields_per_hash)
    value = :rand.uniform(1000)

    key = "agg:#{hash_num}"
    field = "f#{field_num}"

    ["HSET", key, field, Integer.to_string(value)]
  end

  defp generate_read(_vdr_id) do
    commands =
      for _ <- 1..@commands_per_read do
        hash_num = :rand.uniform(@hash_count)
        field_num = :rand.uniform(@fields_per_hash)
        {:hget, "agg:#{hash_num}", "f#{field_num}"}
      end

    read_op = fn vdr_id ->
      case Veidrodelis.read_tx(vdr_id, 0, commands) do
        {:ok, values} ->
          values
          |> Enum.map(fn
            nil -> 0
            value when is_binary(value) -> String.to_integer(value)
            _ -> 0
          end)
          |> Enum.sum()

        _ ->
          0
      end
    end

    hit_check = fn result -> result > 0 end

    {read_op, hit_check}
  end
end
