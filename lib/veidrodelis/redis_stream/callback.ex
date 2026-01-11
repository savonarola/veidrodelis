defmodule Vdr.RedisStream.Callback do
  @moduledoc false

  alias Vdr.RedisStream.ReplicaCommand

  @callback init(opts :: keyword()) :: {:ok, term()} | {:error, term()}
  @callback handle_replication_start(state :: term()) :: {:ok, term()} | {:error, term()}
  @callback handle_streaming_start(state :: term()) :: {:ok, term()} | {:error, term()}
  @callback handle_command(
              state :: term(),
              replica_command :: ReplicaCommand.t()
            ) ::
              {:ok, term()} | {:error, term()}

  @callback handle_call(state :: term(), message :: term()) ::
              {:reply, term(), term()} | {:noreply, term()} | {:error, term()}

  @callback handle_info(state :: term(), message :: term()) ::
              {:noreply, term()} | {:error, term()}

  @callback handle_destroy(state :: term()) :: :ok | {:error, term()}

  @optional_callbacks handle_destroy: 1, handle_call: 2, handle_info: 2
end
