defmodule Vdr.RedisStream.Callback do
  @moduledoc false

  alias Vdr.RedisStream.ReplicaCommand

  @type state :: term()
  @type opts :: keyword()
  @type reply :: term()
  @type message :: term()

  @callback init(opts()) :: {:ok, state()} | {:error, term()}
  @callback handle_replication_start(state()) :: {:ok, state()} | {:error, term()}
  @callback handle_streaming_start(state()) :: {:ok, state()} | {:error, term()}
  @callback handle_commands(
              state(),
              [ReplicaCommand.t()]
            ) ::
              {:ok, state()} | {:error, term()}

  @callback handle_call(state(), message()) ::
              {:reply, reply(), state()} | {:noreply, state()} | {:error, term()}

  @callback handle_info(state(), message()) ::
              {:noreply, state()} | {:error, term()}

  @callback handle_destroy(state()) :: :ok | {:error, term()}

  @optional_callbacks handle_destroy: 1, handle_call: 2, handle_info: 2
end
