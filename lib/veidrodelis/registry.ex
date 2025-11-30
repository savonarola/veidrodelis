defmodule Vdr.Registry do
  @moduledoc """
  Global process registry with automatic cleanup on process death.

  Maintains a registry of processes with associated cleanup functions that
  are automatically called when the monitored process dies or when explicitly
  unregistered.
  """

  use GenServer
  require Logger

  @name {:global, __MODULE__}

  # Client API

  @doc """
  Starts the registry GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put(opts, :name, @name))
  end

  @doc """
  Registers a process with an ID and cleanup function.

  The registry will monitor the process and call the cleanup function when:
  - The process dies
  - The ID is explicitly unregistered

  ## Parameters

    * `id` - Unique identifier for this registration
    * `pid` - Process to monitor
    * `cleanup_fun` - Function to call on cleanup (receives no arguments)

  ## Returns

    * `:ok` - Successfully registered
    * `{:error, :already_registered}` - ID is already registered

  ## Example

      cleanup = fn -> IO.puts("Cleaning up!") end
      :ok = Vdr.Registry.register(:my_id, self(), cleanup)
  """
  @spec register(term(), pid(), fun()) :: :ok | {:error, :already_registered}
  def register(id, pid, cleanup_fun) when is_pid(pid) and is_function(cleanup_fun, 0) do
    GenServer.call(@name, {:register, id, pid, cleanup_fun})
  end

  @doc """
  Unregisters an ID, demonitors the process, and calls the cleanup function.

  ## Parameters

    * `id` - The ID to unregister

  ## Returns

    * `:ok` - Successfully unregistered (or ID was not registered)

  ## Example

      Vdr.Registry.unregister(:my_id)
  """
  @spec unregister(term()) :: :ok
  def unregister(id) do
    GenServer.call(@name, {:unregister, id})
  end

  # Server Callbacks

  @impl true
  def init(:ok) do
    # Trap exits to ensure cleanup on terminate
    Process.flag(:trap_exit, true)
    _ = :ets.new(:veidrodelis_registry, [:set, :public, :named_table])
    # State is a map: id => {pid, cleanup_fun, monitor_ref}
    {:ok, %{}}
  end

  @impl true
  def handle_call({:register, id, pid, cleanup_fun}, _from, state) do
    case Map.get(state, id) do
      nil ->
        # Register new entry
        mref = Process.monitor(pid)
        new_state = Map.put(state, id, {pid, cleanup_fun, mref})
        {:reply, :ok, new_state}

      _existing ->
        # ID already registered
        {:reply, {:error, :already_registered}, state}
    end
  end

  @impl true
  def handle_call({:unregister, id}, _from, state) do
    case Map.get(state, id) do
      nil ->
        # Not registered, nothing to do
        {:reply, :ok, state}

      {_pid, cleanup_fun, mref} ->
        # Demonitor with flush to avoid receiving DOWN message
        Process.demonitor(mref, [:flush])

        # Call cleanup function
        call_cleanup(cleanup_fun, id)

        # Remove from state
        new_state = Map.delete(state, id)
        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_info({:DOWN, mref, :process, _pid, _reason}, state) do
    # Find the entry with this monitor reference
    case Enum.find(state, fn {_id, {_pid, _cleanup_fun, ref}} -> ref == mref end) do
      nil ->
        # Monitor not found, ignore
        {:noreply, state}

      {id, {_pid, cleanup_fun, ^mref}} ->
        # Call cleanup function
        call_cleanup(cleanup_fun, id)

        # Remove from state
        new_state = Map.delete(state, id)
        {:noreply, new_state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    # Cleanup all registered entries
    Enum.each(state, fn {id, {_pid, cleanup_fun, mref}} ->
      # Demonitor
      Process.demonitor(mref, [:flush])
      # Call cleanup
      call_cleanup(cleanup_fun, id)
    end)

    :ok
  end

  # Private helpers

  defp call_cleanup(cleanup_fun, id) do
    try do
      cleanup_fun.()
    rescue
      error ->
        Logger.error("Error in cleanup function for #{inspect(id)}: #{inspect(error)}")
    end
  end
end
