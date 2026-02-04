defmodule Vdr.Benchmark.Scenarios.LuaAggregate do
  @moduledoc false

  @hash_count 100
  @fields_per_hash 20

  def scenarios do
    [
      %{
        name: "lua_aggregate",
        duration_seconds: 15,
        intensity: 50_000,
        command_fn: &generate_command/0,
        reader_count: 3,
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

  defp generate_read(vdr_id) do
    keys =
      for _ <- 1..5 do
        hash_num = :rand.uniform(@hash_count)
        field_num = :rand.uniform(@fields_per_hash)
        {"agg:#{hash_num}", "f#{field_num}"}
      end

    script = build_lua_script(keys)
    {:ok, bytecode} = Veidrodelis.lua_load(vdr_id, script)

    read_op = fn vdr_id ->
      # Get or compile bytecode, caching in process dictionary
      case Veidrodelis.read_tx(vdr_id, 0, bytecode) do
        {:ok, sum} when is_integer(sum) -> sum
        {:ok, sum} when is_float(sum) -> trunc(sum)
        _ -> 0
      end
    end

    hit_check = fn result -> result > 0 end

    {read_op, hit_check}
  end

  defp build_lua_script(keys) do
    reads =
      keys
      |> Enum.with_index(1)
      |> Enum.map(fn {{hash, field}, i} ->
        "local v#{i} = tonumber(ts.hget('#{hash}', '#{field}')) or 0"
      end)
      |> Enum.join("\n")

    sum_expr = Enum.map(1..5, fn i -> "v#{i}" end) |> Enum.join(" + ")

    """
    #{reads}
    return #{sum_expr}
    """
  end
end
