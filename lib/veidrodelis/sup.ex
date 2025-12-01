defmodule Vdr.Sup do
  @moduledoc false

  use Supervisor

  def child_spec() do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, []},
      type: :supervisor,
      restart: :permanent,
      shutdown: 5000
    }
  end

  def start_link(_opts) do
    Supervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_opts) do
    children = []
    Supervisor.init(children, strategy: :one_for_one)
  end
end
