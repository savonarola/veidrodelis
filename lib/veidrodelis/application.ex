defmodule Vdr.Application do
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    children = [
      Vdr.Registry
    ]

    opts = [strategy: :one_for_one, name: Vdr.Application.Supervisor]
    Logger.info("Starting Veidrodelis application: #{inspect(children)}")
    Supervisor.start_link(children, opts)
  end
end
