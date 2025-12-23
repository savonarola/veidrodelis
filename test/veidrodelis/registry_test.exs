defmodule Vdr.RegistryTest do
  use ExUnit.Case, async: false

  alias Vdr.Registry

  setup do
    # Start the registry if it's not already started
    case GenServer.whereis(Registry) do
      nil ->
        {:ok, _pid} = Registry.start_link([])
        :ok

      _pid ->
        :ok
    end

    # Clean up any leftover registrations
    # Note: We can't easily clear ETS from outside, so we'll use unique IDs per test
    :ok
  end

  describe "register/3" do
    test "successfully registers a process with an id and handle" do
      test_pid = spawn(fn -> Process.sleep(:infinity) end)
      id = make_ref()
      handle = %{some: "data"}

      assert :ok = Registry.register(test_pid, id, handle)

      # Verify we can lookup the handle
      assert {:ok, ^handle} = Registry.lookup(id)

      # Cleanup
      Process.exit(test_pid, :kill)
    end

    test "returns error when pid is already registered with a different id" do
      test_pid = spawn(fn -> Process.sleep(:infinity) end)
      id1 = make_ref()
      id2 = make_ref()
      handle1 = %{first: "handle"}
      handle2 = %{second: "handle"}

      assert :ok = Registry.register(test_pid, id1, handle1)

      assert {:error,
              %{
                reason: :already_registered_with_different_id,
                id: ^id2,
                other_id: ^id1,
                pid: ^test_pid
              }} = Registry.register(test_pid, id2, handle2)

      # First registration should still be valid
      assert {:ok, ^handle1} = Registry.lookup(id1)
      assert :not_found = Registry.lookup(id2)

      # Cleanup
      Process.exit(test_pid, :kill)
    end

    test "allows re-registering the same pid with the same id (updates handle)" do
      test_pid = spawn(fn -> Process.sleep(:infinity) end)
      id = make_ref()
      handle1 = %{first: "handle"}
      handle2 = %{second: "handle"}

      # Initial registration
      assert :ok = Registry.register(test_pid, id, handle1)
      assert {:ok, ^handle1} = Registry.lookup(id)

      # Re-register with same pid and id but different handle
      assert :ok = Registry.register(test_pid, id, handle2)
      assert {:ok, ^handle2} = Registry.lookup(id)

      # Cleanup
      Process.exit(test_pid, :kill)
    end

    test "prevents different processes from registering with the same id" do
      test_pid1 = spawn(fn -> Process.sleep(:infinity) end)
      test_pid2 = spawn(fn -> Process.sleep(:infinity) end)
      id = make_ref()
      handle1 = %{first: "handle"}
      handle2 = %{second: "handle"}

      assert :ok = Registry.register(test_pid1, id, handle1)
      assert {:ok, ^handle1} = Registry.lookup(id)

      # Second process cannot register with the same id
      assert {:error, %{reason: :id_already_registered, id: ^id, pid: ^test_pid2}} =
               Registry.register(test_pid2, id, handle2)

      # First registration should still be valid
      assert {:ok, ^handle1} = Registry.lookup(id)

      # Cleanup
      Process.exit(test_pid1, :kill)
      Process.exit(test_pid2, :kill)
    end

    test "can register different processes with different ids" do
      test_pid1 = spawn(fn -> Process.sleep(:infinity) end)
      test_pid2 = spawn(fn -> Process.sleep(:infinity) end)
      id1 = make_ref()
      id2 = make_ref()
      handle1 = %{first: "handle"}
      handle2 = %{second: "handle"}

      assert :ok = Registry.register(test_pid1, id1, handle1)
      assert :ok = Registry.register(test_pid2, id2, handle2)

      assert {:ok, ^handle1} = Registry.lookup(id1)
      assert {:ok, ^handle2} = Registry.lookup(id2)

      # Cleanup
      Process.exit(test_pid1, :kill)
      Process.exit(test_pid2, :kill)
    end
  end

  describe "lookup/1" do
    test "returns {:ok, handle} for registered id" do
      test_pid = spawn(fn -> Process.sleep(:infinity) end)
      id = make_ref()
      handle = %{test: "data", number: 42}

      Registry.register(test_pid, id, handle)

      assert {:ok, ^handle} = Registry.lookup(id)

      # Cleanup
      Process.exit(test_pid, :kill)
    end

    test "returns :not_found for unregistered id" do
      unregistered_id = make_ref()
      assert :not_found = Registry.lookup(unregistered_id)
    end

    test "handles various handle types" do
      test_pid = spawn(fn -> Process.sleep(:infinity) end)

      # String handle
      id1 = make_ref()
      assert :ok = Registry.register(test_pid, id1, "string_handle")
      assert {:ok, "string_handle"} = Registry.lookup(id1)

      # Cleanup and test another
      Process.exit(test_pid, :kill)
      Process.sleep(50)

      test_pid2 = spawn(fn -> Process.sleep(:infinity) end)

      # Integer handle
      id2 = make_ref()
      assert :ok = Registry.register(test_pid2, id2, 12345)
      assert {:ok, 12345} = Registry.lookup(id2)

      # Cleanup
      Process.exit(test_pid2, :kill)
    end
  end

  describe "unregister/2" do
    test "successfully unregisters a process" do
      test_pid = spawn(fn -> Process.sleep(:infinity) end)
      id = make_ref()
      handle = %{data: "test"}

      Registry.register(test_pid, id, handle)
      assert {:ok, ^handle} = Registry.lookup(id)

      assert :ok = Registry.unregister(test_pid, id)
      assert :not_found = Registry.lookup(id)

      # Cleanup
      Process.exit(test_pid, :kill)
    end

    test "returns error when unregistering non-existent registration" do
      test_pid = spawn(fn -> Process.sleep(:infinity) end)
      id = make_ref()

      assert {:error, {:not_registered, ^test_pid}} = Registry.unregister(test_pid, id)

      # Cleanup
      Process.exit(test_pid, :kill)
    end

    test "returns error when pid is not registered" do
      registered_pid = spawn(fn -> Process.sleep(:infinity) end)
      unregistered_pid = spawn(fn -> Process.sleep(:infinity) end)
      id = make_ref()
      handle = %{data: "test"}

      Registry.register(registered_pid, id, handle)

      # Try to unregister with a different pid
      assert {:error, {:not_registered, ^unregistered_pid}} =
               Registry.unregister(unregistered_pid, id)

      # Original registration should still be valid
      assert {:ok, ^handle} = Registry.lookup(id)

      # Cleanup
      Process.exit(registered_pid, :kill)
      Process.exit(unregistered_pid, :kill)
    end

    test "allows re-registration after unregistering" do
      test_pid = spawn(fn -> Process.sleep(:infinity) end)
      id = make_ref()
      handle1 = %{first: "handle"}
      handle2 = %{second: "handle"}

      # Register, unregister, register again
      assert :ok = Registry.register(test_pid, id, handle1)
      assert :ok = Registry.unregister(test_pid, id)
      assert :ok = Registry.register(test_pid, id, handle2)

      assert {:ok, ^handle2} = Registry.lookup(id)

      # Cleanup
      Process.exit(test_pid, :kill)
    end
  end

  describe "process monitoring" do
    test "automatically cleans up when registered process dies" do
      id = make_ref()
      handle = %{data: "test"}

      # Spawn a process and register it
      test_pid =
        spawn(fn ->
          receive do
            :exit -> :ok
          end
        end)

      Registry.register(test_pid, id, handle)
      assert {:ok, ^handle} = Registry.lookup(id)

      # Kill the process
      send(test_pid, :exit)
      Process.sleep(50)

      # Registration should be cleaned up
      assert :not_found = Registry.lookup(id)
    end

    test "cleans up when process exits abnormally" do
      id = make_ref()
      handle = %{data: "test"}

      test_pid = spawn(fn -> raise "error" end)
      Registry.register(test_pid, id, handle)

      # Wait for process to die and cleanup to happen
      Process.sleep(50)

      assert :not_found = Registry.lookup(id)
    end

    test "multiple process deaths are handled independently" do
      id1 = make_ref()
      id2 = make_ref()
      handle1 = %{first: "data"}
      handle2 = %{second: "data"}

      test_pid1 =
        spawn(fn ->
          receive do
            :exit -> :ok
          end
        end)

      test_pid2 = spawn(fn -> Process.sleep(:infinity) end)

      Registry.register(test_pid1, id1, handle1)
      Registry.register(test_pid2, id2, handle2)

      # Kill first process
      send(test_pid1, :exit)
      Process.sleep(50)

      # First should be cleaned up, second should remain
      assert :not_found = Registry.lookup(id1)
      assert {:ok, ^handle2} = Registry.lookup(id2)

      # Cleanup
      Process.exit(test_pid2, :kill)
    end
  end

  describe "edge cases" do
    test "handles unknown GenServer calls" do
      assert {:error, :unknown_call} = GenServer.call(Registry, :unknown_message)
    end

    test "handles registering self()" do
      id = make_ref()
      handle = %{self: "registration"}

      # We can't easily test this in the test process itself without cleanup issues,
      # so we spawn a process that registers itself
      parent = self()

      spawn(fn ->
        result = Registry.register(self(), id, handle)
        send(parent, {:register_result, result})
        Process.sleep(:infinity)
      end)

      assert_receive {:register_result, :ok}, 1000
      assert {:ok, ^handle} = Registry.lookup(id)
    end
  end
end
