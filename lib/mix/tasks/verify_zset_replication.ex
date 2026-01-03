defmodule Mix.Tasks.VerifyZsetReplication do
  @moduledoc """
  Verifies ZSET replication command transformations by sending diverse ZSET commands
  to Redis and capturing what appears in the replication stream.

  Usage:
      mix verify_zset_replication
  """
  use Mix.Task

  alias Vdr.RedisStream.Replica
  alias Vdr.RedisStream.Command, as: Cmd

  @redis_host "localhost"
  @redis_port 16378

  defmodule CapturingCallback do
    @moduledoc """
    Callback module that captures all commands with their order.
    """
    @behaviour Vdr.RedisStream.Callback

    @impl true
    def init(_opts) do
      {:ok, %{commands: [], order: 0}}
    end

    @impl true
    def handle_replication_start(state) do
      {:ok, state}
    end

    @impl true
    def handle_streaming_start(state) do
      {:ok, state}
    end

    @impl true
    def handle_command(state, %Vdr.RedisStream.ReplicaCommand{db: _db, command: command}) do
      order = state.order
      commands = [{order, command} | state.commands]
      new_state = %{state | commands: commands, order: order + 1}
      {:ok, new_state}
    end

    def get_commands(state) do
      state.commands
      |> Enum.reverse()
      |> Enum.map(fn {_order, cmd} -> cmd end)
    end
  end

  @impl Mix.Task
  def run(_args) do
    # Start the application to ensure all dependencies are available
    Mix.Task.run("app.start")

    IO.puts("=== ZSET Replication Verification ===\n")

    # Start Redix connection
    {:ok, redis} = Redix.start_link(host: @redis_host, port: @redis_port)

    # Flush all data
    Redix.command!(redis, ["FLUSHALL"])
    IO.puts("Flushed Redis database\n")

    # Start replica
    opts = [
      host: @redis_host,
      port: @redis_port,
      callback_module: CapturingCallback,
      callback_state: %{commands: [], order: 0}
    ]

    {:ok, replica} = Replica.start_link(opts)
    IO.puts("Started replica\n")

    # Wait for replica to be in streaming state
    wait_for_streaming(replica)
    IO.puts("Replica is streaming\n")

    # Wait a bit for any initial RDB commands to settle
    :timer.sleep(100)

    # Get the initial command count to use as baseline
    initial_state = Replica.get_callback_state(replica)
    initial_commands = CapturingCallback.get_commands(initial_state)
    baseline_count = length(initial_commands)

    IO.puts("Baseline command count: #{baseline_count}\n")

    # Define test cases
    test_cases = define_test_cases()

    # Execute test cases and collect results
    results =
      Enum.map(test_cases, fn {description, command, setup_fn} ->
        # Run setup if provided
        if setup_fn, do: setup_fn.(redis)

        # Mark the point before command
        state_before = Replica.get_callback_state(replica)
        commands_before = CapturingCallback.get_commands(state_before)
        count_before = length(commands_before)

        # Execute command
        result = Redix.command(redis, command)

        # Wait for replication
        :timer.sleep(150)

        # Get commands after
        state_after = Replica.get_callback_state(replica)
        commands_after = CapturingCallback.get_commands(state_after)
        _count_after = length(commands_after)

        # Find new commands (those that appeared after count_before)
        new_commands = Enum.drop(commands_after, count_before)

        # Filter to only ZSET-related commands (ignore setup commands from setup_fn)
        zset_commands =
          Enum.filter(new_commands, fn cmd ->
            match?(%Cmd.ZAdd{}, cmd) or
              match?(%Cmd.ZRem{}, cmd) or
              match?(%Cmd.ZPopMax{}, cmd) or
              match?(%Cmd.ZPopMin{}, cmd) or
              match?(%Cmd.ZRemRangeByRank{}, cmd) or
              match?(%Cmd.ZRemRangeByScore{}, cmd) or
              match?(%Cmd.ZRemRangeByLex{}, cmd) or
              match?(%Cmd.ZUnionStore{}, cmd) or
              match?(%Cmd.ZInterStore{}, cmd)
          end)

        {description, command, zset_commands, result}
      end)

    # Stop replica
    Replica.stop(replica)
    Redix.stop(redis)

    # Print results
    IO.puts("\n=== Results ===\n")

    Enum.each(results, fn {description, command, replicated_cmds, _result} ->
      IO.puts("#{description}:")
      IO.puts("  Client: #{format_command(command)}")

      case replicated_cmds do
        [] ->
          IO.puts("  Replicated: (none)")

        cmds ->
          Enum.each(cmds, fn cmd ->
            IO.puts("  Replicated: #{format_replicated_command(cmd)}")
          end)
      end

      IO.puts("")
    end)

    # Generate markdown
    markdown = generate_markdown_table(results)

    # Write to file
    output_file = "doc/zset-replication.md"
    File.write!(output_file, markdown)

    IO.puts("\n=== Markdown table written to #{output_file} ===")
  end

  defp define_test_cases do
    [
      # Basic ZADD
      {
        "ZADD basic",
        ["ZADD", "zset1", "1.0", "member1", "2.5", "member2"],
        nil
      },
      {
        "ZADD with single member",
        ["ZADD", "zset2", "3.14", "pi"],
        nil
      },
      {
        "ZADD with negative score",
        ["ZADD", "zset3", "-5.5", "negative"],
        nil
      },
      # ZADD with options (should strip options in replication)
      {
        "ZADD with NX (new member)",
        ["ZADD", "zset4", "NX", "10", "new_member"],
        nil
      },
      {
        "ZADD with XX (existing member)",
        ["ZADD", "zset_existing", "XX", "10", "existing"],
        fn redis ->
          Redix.command!(redis, ["ZADD", "zset_existing", "5", "existing"])
        end
      },
      {
        "ZADD with GT (greater than)",
        ["ZADD", "zset_gt", "GT", "10", "member"],
        fn redis ->
          Redix.command!(redis, ["ZADD", "zset_gt", "5", "member"])
        end
      },
      {
        "ZADD with LT (less than)",
        ["ZADD", "zset_lt", "LT", "2", "member"],
        fn redis ->
          Redix.command!(redis, ["ZADD", "zset_lt", "5", "member"])
        end
      },
      {
        "ZADD with CH (changed)",
        ["ZADD", "zset5", "CH", "7", "member_ch"],
        nil
      },
      {
        "ZADD with INCR",
        ["ZADD", "zset6", "INCR", "2.5", "incr_member"],
        fn redis ->
          Redix.command!(redis, ["ZADD", "zset6", "5", "incr_member"])
        end
      },
      # ZINCRBY
      {
        "ZINCRBY positive",
        ["ZINCRBY", "zset7", "3.5", "zincrby_member"],
        fn redis ->
          Redix.command!(redis, ["ZADD", "zset7", "10", "zincrby_member"])
        end
      },
      {
        "ZINCRBY negative",
        ["ZINCRBY", "zset8", "-2.0", "zincrby_neg"],
        fn redis ->
          Redix.command!(redis, ["ZADD", "zset8", "10", "zincrby_neg"])
        end
      },
      # ZREM
      {
        "ZREM single member",
        ["ZREM", "zset9", "to_remove"],
        fn redis ->
          Redix.command!(redis, ["ZADD", "zset9", "1", "to_remove", "2", "keep"])
        end
      },
      {
        "ZREM multiple members",
        ["ZREM", "zset10", "remove1", "remove2"],
        fn redis ->
          Redix.command!(redis, ["ZADD", "zset10", "1", "remove1", "2", "remove2", "3", "keep"])
        end
      },
      # ZPOPMIN
      {
        "ZPOPMIN without count",
        ["ZPOPMIN", "zset11"],
        fn redis ->
          Redix.command!(redis, ["ZADD", "zset11", "1", "a", "2", "b", "3", "c"])
        end
      },
      {
        "ZPOPMIN with count",
        ["ZPOPMIN", "zset12", "2"],
        fn redis ->
          Redix.command!(redis, ["ZADD", "zset12", "1", "a", "2", "b", "3", "c"])
        end
      },
      # ZPOPMAX
      {
        "ZPOPMAX without count",
        ["ZPOPMAX", "zset13"],
        fn redis ->
          Redix.command!(redis, ["ZADD", "zset13", "1", "a", "2", "b", "3", "c"])
        end
      },
      {
        "ZPOPMAX with count",
        ["ZPOPMAX", "zset14", "2"],
        fn redis ->
          Redix.command!(redis, ["ZADD", "zset14", "1", "a", "2", "b", "3", "c"])
        end
      },
      # ZREMRANGEBYRANK
      {
        "ZREMRANGEBYRANK positive indices",
        ["ZREMRANGEBYRANK", "zset15", "0", "1"],
        fn redis ->
          Redix.command!(redis, ["ZADD", "zset15", "1", "a", "2", "b", "3", "c", "4", "d"])
        end
      },
      {
        "ZREMRANGEBYRANK negative indices",
        ["ZREMRANGEBYRANK", "zset16", "-2", "-1"],
        fn redis ->
          Redix.command!(redis, ["ZADD", "zset16", "1", "a", "2", "b", "3", "c", "4", "d"])
        end
      },
      {
        "ZREMRANGEBYRANK all elements",
        ["ZREMRANGEBYRANK", "zset17", "0", "-1"],
        fn redis ->
          Redix.command!(redis, ["ZADD", "zset17", "1", "a", "2", "b"])
        end
      },
      # ZREMRANGEBYSCORE - inclusive
      {
        "ZREMRANGEBYSCORE inclusive range",
        ["ZREMRANGEBYSCORE", "zset18", "2", "4"],
        fn redis ->
          Redix.command!(redis, [
            "ZADD",
            "zset18",
            "1",
            "a",
            "2",
            "b",
            "3",
            "c",
            "4",
            "d",
            "5",
            "e"
          ])
        end
      },
      # ZREMRANGEBYSCORE - exclusive
      {
        "ZREMRANGEBYSCORE exclusive min",
        ["ZREMRANGEBYSCORE", "zset19", "(2", "4"],
        fn redis ->
          Redix.command!(redis, [
            "ZADD",
            "zset19",
            "1",
            "a",
            "2",
            "b",
            "3",
            "c",
            "4",
            "d",
            "5",
            "e"
          ])
        end
      },
      {
        "ZREMRANGEBYSCORE exclusive max",
        ["ZREMRANGEBYSCORE", "zset20", "2", "(4"],
        fn redis ->
          Redix.command!(redis, [
            "ZADD",
            "zset20",
            "1",
            "a",
            "2",
            "b",
            "3",
            "c",
            "4",
            "d",
            "5",
            "e"
          ])
        end
      },
      {
        "ZREMRANGEBYSCORE both exclusive",
        ["ZREMRANGEBYSCORE", "zset21", "(2", "(4"],
        fn redis ->
          Redix.command!(redis, [
            "ZADD",
            "zset21",
            "1",
            "a",
            "2",
            "b",
            "3",
            "c",
            "4",
            "d",
            "5",
            "e"
          ])
        end
      },
      # ZREMRANGEBYSCORE - infinity
      {
        "ZREMRANGEBYSCORE -inf to value",
        ["ZREMRANGEBYSCORE", "zset22", "-inf", "3"],
        fn redis ->
          Redix.command!(redis, [
            "ZADD",
            "zset22",
            "1",
            "a",
            "2",
            "b",
            "3",
            "c",
            "4",
            "d",
            "5",
            "e"
          ])
        end
      },
      {
        "ZREMRANGEBYSCORE value to +inf",
        ["ZREMRANGEBYSCORE", "zset23", "3", "+inf"],
        fn redis ->
          Redix.command!(redis, [
            "ZADD",
            "zset23",
            "1",
            "a",
            "2",
            "b",
            "3",
            "c",
            "4",
            "d",
            "5",
            "e"
          ])
        end
      },
      {
        "ZREMRANGEBYSCORE -inf to +inf",
        ["ZREMRANGEBYSCORE", "zset24", "-inf", "+inf"],
        fn redis ->
          Redix.command!(redis, ["ZADD", "zset24", "1", "a", "2", "b"])
        end
      },
      # ZREMRANGEBYLEX
      {
        "ZREMRANGEBYLEX inclusive range",
        ["ZREMRANGEBYLEX", "zset25", "[b", "[d"],
        fn redis ->
          Redix.command!(redis, [
            "ZADD",
            "zset25",
            "0",
            "a",
            "0",
            "b",
            "0",
            "c",
            "0",
            "d",
            "0",
            "e"
          ])
        end
      },
      {
        "ZREMRANGEBYLEX exclusive range",
        ["ZREMRANGEBYLEX", "zset26", "(b", "(d"],
        fn redis ->
          Redix.command!(redis, [
            "ZADD",
            "zset26",
            "0",
            "a",
            "0",
            "b",
            "0",
            "c",
            "0",
            "d",
            "0",
            "e"
          ])
        end
      },
      {
        "ZREMRANGEBYLEX min to max",
        ["ZREMRANGEBYLEX", "zset27", "-", "+"],
        fn redis ->
          Redix.command!(redis, ["ZADD", "zset27", "0", "a", "0", "b"])
        end
      },
      {
        "ZREMRANGEBYLEX from min",
        ["ZREMRANGEBYLEX", "zset28", "-", "[c"],
        fn redis ->
          Redix.command!(redis, ["ZADD", "zset28", "0", "a", "0", "b", "0", "c", "0", "d"])
        end
      },
      # ZUNIONSTORE
      {
        "ZUNIONSTORE basic",
        ["ZUNIONSTORE", "zset_union1", "2", "zset_u1", "zset_u2"],
        fn redis ->
          Redix.command!(redis, ["ZADD", "zset_u1", "1", "a", "2", "b"])
          Redix.command!(redis, ["ZADD", "zset_u2", "2", "b", "3", "c"])
        end
      },
      {
        "ZUNIONSTORE with WEIGHTS",
        ["ZUNIONSTORE", "zset_union2", "2", "zset_uw1", "zset_uw2", "WEIGHTS", "2", "3"],
        fn redis ->
          Redix.command!(redis, ["ZADD", "zset_uw1", "1", "a", "2", "b"])
          Redix.command!(redis, ["ZADD", "zset_uw2", "1", "b", "2", "c"])
        end
      },
      {
        "ZUNIONSTORE with AGGREGATE SUM",
        ["ZUNIONSTORE", "zset_union3", "2", "zset_us1", "zset_us2", "AGGREGATE", "SUM"],
        fn redis ->
          Redix.command!(redis, ["ZADD", "zset_us1", "1", "a", "2", "b"])
          Redix.command!(redis, ["ZADD", "zset_us2", "3", "b", "4", "c"])
        end
      },
      {
        "ZUNIONSTORE with AGGREGATE MIN",
        ["ZUNIONSTORE", "zset_union4", "2", "zset_umin1", "zset_umin2", "AGGREGATE", "MIN"],
        fn redis ->
          Redix.command!(redis, ["ZADD", "zset_umin1", "1", "a", "5", "b"])
          Redix.command!(redis, ["ZADD", "zset_umin2", "3", "b", "4", "c"])
        end
      },
      {
        "ZUNIONSTORE with AGGREGATE MAX",
        ["ZUNIONSTORE", "zset_union5", "2", "zset_umax1", "zset_umax2", "AGGREGATE", "MAX"],
        fn redis ->
          Redix.command!(redis, ["ZADD", "zset_umax1", "1", "a", "5", "b"])
          Redix.command!(redis, ["ZADD", "zset_umax2", "3", "b", "4", "c"])
        end
      },
      # ZINTERSTORE
      {
        "ZINTERSTORE basic",
        ["ZINTERSTORE", "zset_inter1", "2", "zset_i1", "zset_i2"],
        fn redis ->
          Redix.command!(redis, ["ZADD", "zset_i1", "1", "a", "2", "b", "3", "c"])
          Redix.command!(redis, ["ZADD", "zset_i2", "2", "b", "3", "c", "4", "d"])
        end
      },
      {
        "ZINTERSTORE with WEIGHTS",
        ["ZINTERSTORE", "zset_inter2", "2", "zset_iw1", "zset_iw2", "WEIGHTS", "2", "3"],
        fn redis ->
          Redix.command!(redis, ["ZADD", "zset_iw1", "1", "a", "2", "b"])
          Redix.command!(redis, ["ZADD", "zset_iw2", "1", "b", "2", "c"])
        end
      },
      {
        "ZINTERSTORE with AGGREGATE MAX",
        ["ZINTERSTORE", "zset_inter3", "2", "zset_imax1", "zset_imax2", "AGGREGATE", "MAX"],
        fn redis ->
          Redix.command!(redis, ["ZADD", "zset_imax1", "1", "a", "5", "b"])
          Redix.command!(redis, ["ZADD", "zset_imax2", "3", "b", "4", "c"])
        end
      }
    ]
  end

  defp wait_for_streaming(replica, timeout \\ 5000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_streaming(replica, deadline)
  end

  defp do_wait_for_streaming(replica, deadline) do
    if System.monotonic_time(:millisecond) < deadline do
      case Replica.get_replication_state(replica) do
        :streaming ->
          :ok

        _ ->
          :timer.sleep(100)
          do_wait_for_streaming(replica, deadline)
      end
    else
      raise "Replica did not reach streaming state within timeout"
    end
  end

  defp format_command(command) when is_list(command) do
    Enum.join(command, " ")
  end

  defp format_replicated_command(%Cmd.ZAdd{key: key, members: members, options: options}) do
    options_str =
      if options != [] do
        " " <> Enum.join(Enum.map(options, &String.upcase(to_string(&1))), " ")
      else
        ""
      end

    member_strs =
      Enum.map(members, fn {score, member} ->
        "#{format_score(score)} #{member}"
      end)

    "ZADD #{key}#{options_str} #{Enum.join(member_strs, " ")}"
  end

  defp format_replicated_command(%Cmd.ZRem{key: key, members: members}) do
    "ZREM #{key} #{Enum.join(members, " ")}"
  end

  defp format_replicated_command(%Cmd.ZPopMax{key: key, count: count}) do
    if count == 1 do
      "ZPOPMAX #{key}"
    else
      "ZPOPMAX #{key} #{count}"
    end
  end

  defp format_replicated_command(%Cmd.ZPopMin{key: key, count: count}) do
    if count == 1 do
      "ZPOPMIN #{key}"
    else
      "ZPOPMIN #{key} #{count}"
    end
  end

  defp format_replicated_command(%Cmd.ZRemRangeByRank{key: key, start: start, stop: stop}) do
    "ZREMRANGEBYRANK #{key} #{start} #{stop}"
  end

  defp format_replicated_command(%Cmd.ZRemRangeByScore{key: key, min: min, max: max}) do
    "ZREMRANGEBYSCORE #{key} #{min} #{max}"
  end

  defp format_replicated_command(%Cmd.ZRemRangeByLex{key: key, min: min, max: max}) do
    "ZREMRANGEBYLEX #{key} #{min} #{max}"
  end

  defp format_replicated_command(%Cmd.ZUnionStore{
         destination: dest,
         keys: keys,
         weights: weights,
         aggregate: agg
       }) do
    base = "ZUNIONSTORE #{dest} #{length(keys)} #{Enum.join(keys, " ")}"

    weights_str =
      if weights,
        do: " WEIGHTS #{Enum.join(Enum.map(weights, &Float.to_string/1), " ")}",
        else: ""

    agg_str = if agg, do: " AGGREGATE #{String.upcase(to_string(agg))}", else: ""
    base <> weights_str <> agg_str
  end

  defp format_replicated_command(%Cmd.ZInterStore{
         destination: dest,
         keys: keys,
         weights: weights,
         aggregate: agg
       }) do
    base = "ZINTERSTORE #{dest} #{length(keys)} #{Enum.join(keys, " ")}"

    weights_str =
      if weights,
        do: " WEIGHTS #{Enum.join(Enum.map(weights, &Float.to_string/1), " ")}",
        else: ""

    agg_str = if agg, do: " AGGREGATE #{String.upcase(to_string(agg))}", else: ""
    base <> weights_str <> agg_str
  end

  defp format_replicated_command(cmd) do
    inspect(cmd)
  end

  defp format_score(score) when is_float(score), do: Float.to_string(score)
  defp format_score(:pos_inf), do: "+inf"
  defp format_score(:neg_inf), do: "-inf"
  defp format_score(:nan), do: "nan"
  defp format_score(score), do: to_string(score)

  defp generate_markdown_table(results) do
    lines = [
      "# ZSET Replication Command Verification",
      "",
      "This document shows the actual replication behavior of Redis ZSET commands.",
      "Generated by: `mix verify_zset_replication`",
      "",
      "| Test Case | Client Command | Replicated Command | Notes |",
      "|:----------|:---------------|:-------------------|:------|"
    ]

    result_lines =
      Enum.map(results, fn {description, command, replicated_cmds, result} ->
        client_cmd = format_command(command)

        {replicated_str, notes} =
          case replicated_cmds do
            [] ->
              success = match?({:ok, _}, result)

              if success do
                {"*(none)*",
                 "Command succeeded but was not replicated (conditional operation failed or no-op)"}
              else
                {"*(error)*", "Command failed: #{inspect(result)}"}
              end

            [single_cmd] ->
              {format_replicated_command(single_cmd), ""}

            multiple_cmds ->
              formatted = Enum.map(multiple_cmds, &format_replicated_command/1)
              {Enum.join(formatted, "<br>"), "Multiple commands replicated"}
          end

        "| #{description} | `#{client_cmd}` | `#{replicated_str}` | #{notes} |"
      end)

    Enum.join(lines ++ result_lines, "\n")
  end
end
