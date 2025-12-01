defmodule Vdr.InstanceSup do
  @moduledoc false

  use Supervisor
  require Logger

  def child_spec(opts) do
    id = Keyword.fetch!(opts, :id)

    %{
      id: id,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :permanent,
      shutdown: 5000
    }
  end

  def start_link(opts) do
    Logger.debug("Starting instance sup with opts: #{inspect(opts)}")
    Supervisor.start_link(__MODULE__, opts)
  end

  def init(opts) do
    Logger.debug("Initializing instance sup with opts: #{inspect(opts)}")
    pid = self()
    replica_opts = Keyword.fetch!(opts, :replica_opts)
    replica_callback_state = Keyword.fetch!(opts, :replica_callback_state)

    children = [
      Vdr.RedisStream.Replica.child_spec(
        replica_opts ++ [callback_state: Map.put(replica_callback_state, :pid, pid)]
      )
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
