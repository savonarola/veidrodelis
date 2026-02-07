defmodule Vdr.Application do
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _args) do
    children = [
      {Vdr.Registry, []}
    ]

    opts = [strategy: :one_for_one, name: Vdr.Application.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
