defmodule IntegrationHelpers do
  @moduledoc """
  Shared constants and helpers for integration tests.
  """

  use CommandMatchers
  import ExUnit.Assertions

  @redis_host "localhost"
  @redis_port 16378
  @id "vdr_id"

  def redis_host, do: @redis_host
  def redis_port, do: @redis_port
  def vdr_id, do: @id

  @doc """
  Standard setup for integration tests: connects to Redis and flushes all data.
  """
  def setup_redis do
    {:ok, redis} = Redix.start_link(host: @redis_host, port: @redis_port)
    Redix.command!(redis, ["FLUSHALL"])
    {:ok, redis: redis}
  end

  @doc """
  Standard setup for integration tests with Veidrodelis instance.
  Starts Veidrodelis with TSProj and waits for streaming state.
  """
  def setup_veidrodelis(redis) do
    {:ok, vdr} =
      Veidrodelis.start_link(
        id: @id,
        host: @redis_host,
        port: @redis_port
      )

    assert_within 5000 do
      assert :streaming == Veidrodelis.get_replication_state(vdr)
    end

    {:ok, redis: redis, vdr: vdr}
  end

  defmacro __using__(_opts) do
    quote do
      import IntegrationHelpers
    end
  end
end
