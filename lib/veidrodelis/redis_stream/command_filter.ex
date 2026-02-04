defmodule Vdr.RedisStream.CommandFilter do
  @moduledoc """
  Defines a filter for processing Redis commands in replica before and after callback execution.

  Filters can modify commands, add context, or skip commands entirely. The context
  map in ReplicaCommand can be used to pass data between pre_handle and post_handle.
  """

  alias Vdr.RedisStream.ReplicaCommand

  @type pre_handle :: (ReplicaCommand.t() -> {:ok, ReplicaCommand.t()} | :skip)
  @type post_handle :: (ReplicaCommand.t(), :ok | {:error, term()} -> :ok)

  @type t :: %__MODULE__{
          pre_handle: pre_handle(),
          post_handle: post_handle()
        }

  defstruct pre_handle: &__MODULE__.identity_pre_handle/1,
            post_handle: &__MODULE__.identity_post_handle/2

  @doc """
  Default pre_handle that passes the command through unchanged.
  """
  def identity_pre_handle(replica_command) do
    {:ok, replica_command}
  end

  @doc """
  Default post_handle that does nothing.
  """
  def identity_post_handle(_replica_command, _result) do
    :ok
  end

  @doc """
  Combines two filters into a single filter.

  The outer filter's pre_handle runs first, then the inner filter's pre_handle.
  Post-handles run in reverse order (inner first, then outer).

  If either pre_handle returns :skip, the combined filter returns :skip.
  """
  def combine(outer_filter, inner_filter) do
    %__MODULE__{
      pre_handle: fn replica_command ->
        case outer_filter.pre_handle.(replica_command) do
          {:ok, replica_command} ->
            inner_filter.pre_handle.(replica_command)

          :skip ->
            :skip
        end
      end,
      post_handle: fn replica_command ->
        :ok = inner_filter.post_handle.(replica_command)
        :ok = outer_filter.post_handle.(replica_command)
      end
    }
  end

  @doc """
  Applies the filter to the list of replica commands. Used internally by the replica.
  """
  def apply_pre(filter, replica_commands, filtered_commands \\ [])

  def apply_pre(_filter, [], filtered_commands) do
    Enum.reverse(filtered_commands)
  end

  def apply_pre(filter, [replica_command | rest], filtered_commands) do
    case filter.pre_handle.(replica_command) do
      {:ok, new_replica_command} ->
        apply_pre(filter, rest, [new_replica_command | filtered_commands])

      :skip ->
        apply_pre(filter, rest, filtered_commands)
    end
  end

  @doc """
  Applies the filter to the list of replica commands. Used internally by the replica.
  """
  def apply_post(filter, replica_commands, result) do
    do_apply_post(filter, Enum.reverse(replica_commands), result)
  end

  defp do_apply_post(_filter, [], _result) do
    :ok
  end

  defp do_apply_post(filter, [replica_command | rest], result) do
    :ok = filter.post_handle.(replica_command, result)
    do_apply_post(filter, rest, result)
  end
end
