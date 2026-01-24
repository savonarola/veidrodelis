defmodule Vdr.Benchmark.Scenarios.HgetAggregate do
  @moduledoc """
  Complex benchmark scenario using batched hget commands for aggregate reads.

  Write side: HSET with integer values to random hash keys/fields.
  Read side: read_tx with hget commands reading random hash fields and returning their sum.
  Hit: Counted when sum > 0 (at least one value was found).

  Key space is intentionally limited to ensure substantial hit rate.
  This scenario is comparable to LuaAggregate but uses a list of hget commands via read_tx.
  """

  # Limited key space for high hit rate
  @hash_count 10000
  @fields_per_hash 10000
  @commands_per_read 10

  @doc """
  Returns scenario configurations for hget aggregate benchmark.
  """
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

  # Generates HSET commands with integer values
  defp generate_command do
    hash_num = :rand.uniform(@hash_count)
    field_num = :rand.uniform(@fields_per_hash)
    value = :rand.uniform(1000)

    key = "agg:#{hash_num}"
    field = "f#{field_num}"

    ["HSET", key, field, Integer.to_string(value)]
  end

  # Generates a read operation that performs 5 hget commands via read_tx and sums them
  defp generate_read(_vdr_id) do
    # Generate 5 random key/field pairs
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
