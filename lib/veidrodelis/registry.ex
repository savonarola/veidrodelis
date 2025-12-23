defmodule Vdr.Registry do
  @moduledoc """
  Registry for Veidrodelis instances.
  """

  defmodule State do
    defstruct instances: %{}
  end

  use GenServer

  require Logger

  @tab __MODULE__

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def register(pid, id, handle) do
    GenServer.call(__MODULE__, {:register, pid, id, handle})
  end

  def unregister(pid, id) do
    GenServer.call(__MODULE__, {:unregister, pid, id})
  end

  def lookup(id) do
    case :ets.lookup(@tab, id) do
      [{^id, handle}] -> {:ok, handle}
      [] -> :not_found
    end
  end

  def init(_opts) do
    :ets.new(@tab, [:named_table, :set, :protected])
    {:ok, %State{instances: %{}}}
  end

  def handle_call({:register, pid, id, handle}, _from, state) do
    case state.instances do
      %{^pid => {other_id, _}} when other_id != id ->
        {:reply, {:error, %{reason: :already_registered_with_different_id, id: id, other_id: other_id, pid: pid}}, state}
      %{^pid => {^id, _}} ->
        :ets.insert(@tab, {id, handle})
        {:reply, :ok, state}
      _ ->
        case :ets.insert_new(@tab, {id, handle}) do
          true ->
            ref = Process.monitor(pid)
            {:reply, :ok, %{state | instances: Map.put(state.instances, pid, {id, ref})}}
          false ->
            {:reply, {:error, %{reason: :id_already_registered, id: id, pid: pid}}, state}
        end
    end
  end

  def handle_call({:unregister, pid, id}, _from, state) do
    case state.instances do
      %{^pid => {^id, ref}} ->
        :ets.delete(@tab, id)
        Process.demonitor(ref, [:flush])
        {:reply, :ok, %{state | instances: Map.delete(state.instances, pid)}}
      _ ->
        {:reply, {:error, {:not_registered, pid}}, state}
    end
  end

  def handle_call(_unknown_message, _from, state) do
    {:reply, {:error, :unknown_call}, state}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case state.instances do
      %{^pid => {id, ^ref}} ->
        :ets.delete(@tab, id)
        {:noreply, %{state | instances: Map.delete(state.instances, pid)}}
      %{^pid => _} ->
        Logger.warning("Process #{inspect(pid)} is monitored with unknown ref #{inspect(ref)}")
        {:noreply, state}
      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_unknown_message, state) do
    {:noreply, state}
  end

end
