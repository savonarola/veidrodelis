defmodule Vdr.RedisStream.CommandFilter do
  @moduledoc """
  Defines a filter for processing Redis commands before and after callback execution.

  Filters can modify commands, add context, or skip commands entirely. The context
  map in ReplicaCommand can be used to pass data between pre_handle and post_handle.
  """

  alias Vdr.RedisStream.ReplicaCommand

  @type pre_handle :: (ReplicaCommand.t() -> {:ok, ReplicaCommand.t()} | :skip)
  @type post_handle :: (ReplicaCommand.t() -> :ok)

  @type t :: %__MODULE__{
          pre_handle: pre_handle(),
          post_handle: post_handle()
        }

  defstruct pre_handle: &__MODULE__.identity_pre_handle/1,
            post_handle: &__MODULE__.identity_post_handle/1

  @doc """
  Default pre_handle that passes the command through unchanged.
  """
  def identity_pre_handle(replica_command) do
    {:ok, replica_command}
  end

  @doc """
  Default post_handle that does nothing.
  """
  def identity_post_handle(_replica_command) do
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
  Applies a filter to a ReplicaCommand and executes a function if not skipped.

  ## Flow

  1. Calls `filter.pre_handle(replica_command)`
  2. If `:skip`, returns `:ok` without executing the function
  3. If `{:ok, replica_command}`, executes `fun.(replica_command)`
  4. Calls `filter.post_handle(replica_command)`
  5. Returns the result from the function

  ## Parameters

    * `filter` - The CommandFilter to apply
    * `replica_command` - The ReplicaCommand to process
    * `fun` - Function to execute if not skipped (receives the potentially modified ReplicaCommand)

  ## Examples

      CommandFilter.apply(filter, replica_command, fn rc ->
        callback_module.handle_command(state, rc)
      end)

  """
  def apply(filter, replica_command, fun) do
    case filter.pre_handle.(replica_command) do
      :skip ->
        :ok

      {:ok, replica_command} ->
        result = fun.(replica_command)
        :ok = filter.post_handle.(replica_command)
        result
    end
  end
end
