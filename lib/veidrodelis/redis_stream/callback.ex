defmodule Vdr.RedisStream.Callback do
  @moduledoc """
  Callback module for the Redis stream replica.

  You may implement this callback module to make your own handling of commands
  replicated from a Redis/Valkey instance.
  """

  alias Vdr.RedisStream.ReplicaCommand

  @typedoc """
  The state of the callback module.
  """
  @type state :: term()

  @typedoc """
  The options passed by user to the callback module when starting the replica.
  """
  @type opts :: keyword()

  @typedoc """
  The reply from the callback module.
  """
  @type reply :: term()

  @typedoc """
  The message from the callback module.
  """
  @type message :: term()

  @doc """
  Called when the replica is started.
  """
  @callback init(opts()) :: {:ok, state()} | {:error, term()}

  @doc """
  Called when the replica has established a connection to the Redis
  and is about to start replicating.
  """
  @callback handle_replication_start(state()) :: {:ok, state()} | {:error, term()}

  @doc """
  Called when the replica has read and handle the RDB snapshot from the Redis
  and starts to stream online commands.
  """
  @callback handle_streaming_start(state()) :: {:ok, state()} | {:error, term()}

  @doc """
  Called when the replica has received and handled a batch of commands from the Redis.
  RDB snapshot and online commands are both handled by this callback.

  RDB snapshot data is converted to corresponding ReplicaCommand structs.
  For example, if the RDB snapshot contains a list of ["a", "b", "c"] under "l" in database 0,
  it will be passed as RPUSH command to the callback:
  ```elixir
  %Vdr.RedisStream.ReplicaCommand{
    db: 0,
    command: {:rpush, "l", ["a", "b", "c"]},
    ...
  }
  ```
  """
  @callback handle_commands(
              state(),
              [ReplicaCommand.t()]
            ) ::
              {:ok, state()} | {:error, term()}

  @doc """
  Handles `&Vdr.RedisStream.Replica.call/2` calls.
  """
  @callback handle_call(state(), message()) ::
              {:reply, reply(), state()} | {:noreply, state()} | {:error, term()}

  @doc """
  Handles generic messages sent to the replica process which
  the replica process has not handled itself.
  """
  @callback handle_info(state(), message()) ::
              {:noreply, state()} | {:error, term()}

  @doc """
  Called when the replica is about to shutdown (in `&Vdr.RedisStream.Replica.terminate/2`).
  """
  @callback handle_destroy(state()) :: :ok | {:error, term()}
end
