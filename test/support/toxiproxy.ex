defmodule Veidrodelis.Test.Toxiproxy do
  @moduledoc """
  Test helper module for managing Toxiproxy disruptions.

  Toxiproxy is a proxy that allows you to simulate network and system conditions
  for testing. This module provides a simple interface to manage toxics (disruptions)
  via the Toxiproxy HTTP API.

  ## Network Disruption Examples

      # Add latency to all requests
      Toxiproxy.add_latency("redis", 1000)

      # Limit bandwidth
      Toxiproxy.add_bandwidth_limit("redis", 100)

      # Add timeouts
      Toxiproxy.add_timeout("redis", 5000)

  ## Connection Breaking Examples

      # Hard reset connection (TCP RST)
      Toxiproxy.add_reset_peer("redis")

      # Break connection completely
      Toxiproxy.break_connection("redis")
      # ... test disconnection handling ...
      Toxiproxy.restore_connection("redis")

      # Simulate a brief outage
      Toxiproxy.simulate_outage("redis", 2000)  # 2 second outage

  ## Proxy Management

      # Disable the proxy entirely
      Toxiproxy.disable("redis")

      # Re-enable the proxy
      Toxiproxy.enable("redis")

      # Remove all toxics (reset to clean state)
      Toxiproxy.reset("redis")
  """

  @base_url "http://localhost:8474"

  @doc """
  Adds latency toxic to the specified proxy.

  ## Parameters
    - proxy: The name of the proxy (e.g., "redis")
    - latency_ms: Latency in milliseconds
    - jitter_ms: Optional jitter in milliseconds (default: 0)
    - stream: :upstream or :downstream (default: :downstream)

  ## Returns
    - {:ok, toxic} on success
    - {:error, reason} on failure
  """
  def add_latency(proxy, latency_ms, jitter_ms \\ 0, stream \\ :downstream) do
    add_toxic(proxy, "latency_#{stream}", "latency", stream, %{
      latency: latency_ms,
      jitter: jitter_ms
    })
  end

  @doc """
  Adds bandwidth limitation toxic to the specified proxy.

  ## Parameters
    - proxy: The name of the proxy (e.g., "redis")
    - rate_kb: Bandwidth rate in KB/s
    - stream: :upstream or :downstream (default: :downstream)

  ## Returns
    - {:ok, toxic} on success
    - {:error, reason} on failure
  """
  def add_bandwidth_limit(proxy, rate_kb, stream \\ :downstream) do
    add_toxic(proxy, "bandwidth_#{stream}", "bandwidth", stream, %{
      rate: rate_kb
    })
  end

  @doc """
  Adds slow close toxic - delays TCP socket close.

  ## Parameters
    - proxy: The name of the proxy (e.g., "redis")
    - delay_ms: Delay in milliseconds
    - stream: :upstream or :downstream (default: :downstream)

  ## Returns
    - {:ok, toxic} on success
    - {:error, reason} on failure
  """
  def add_slow_close(proxy, delay_ms, stream \\ :downstream) do
    add_toxic(proxy, "slow_close_#{stream}", "slow_close", stream, %{
      delay: delay_ms
    })
  end

  @doc """
  Adds timeout toxic - stops all data from getting through and closes connection after timeout.

  ## Parameters
    - proxy: The name of the proxy (e.g., "redis")
    - timeout_ms: Timeout in milliseconds
    - stream: :upstream or :downstream (default: :downstream)

  ## Returns
    - {:ok, toxic} on success
    - {:error, reason} on failure
  """
  def add_timeout(proxy, timeout_ms, stream \\ :downstream) do
    add_toxic(proxy, "timeout_#{stream}", "timeout", stream, %{
      timeout: timeout_ms
    })
  end

  @doc """
  Adds slicer toxic - slices TCP packets to simulate partial data transfers.

  ## Parameters
    - proxy: The name of the proxy (e.g., "redis")
    - average_size: Average size of slices in bytes
    - size_variation: Variation in slice size
    - delay_ms: Delay between slices in microseconds
    - stream: :upstream or :downstream (default: :downstream)

  ## Returns
    - {:ok, toxic} on success
    - {:error, reason} on failure
  """
  def add_slicer(proxy, average_size, size_variation, delay_ms, stream \\ :downstream) do
    add_toxic(proxy, "slicer_#{stream}", "slicer", stream, %{
      average_size: average_size,
      size_variation: size_variation,
      delay: delay_ms
    })
  end

  @doc """
  Adds limit_data toxic - closes connection after transmitting a certain amount of data.

  ## Parameters
    - proxy: The name of the proxy (e.g., "redis")
    - bytes: Number of bytes to transmit before closing
    - stream: :upstream or :downstream (default: :downstream)

  ## Returns
    - {:ok, toxic} on success
    - {:error, reason} on failure
  """
  def add_limit_data(proxy, bytes, stream \\ :downstream) do
    add_toxic(proxy, "limit_data_#{stream}", "limit_data", stream, %{
      bytes: bytes
    })
  end

  @doc """
  Adds reset_peer toxic - immediately closes connection by sending TCP RST.

  This simulates a hard connection reset, useful for testing reconnection logic.

  ## Parameters
    - proxy: The name of the proxy (e.g., "redis")
    - timeout_ms: Time to wait before resetting the connection (default: 0)
    - stream: :upstream or :downstream (default: :downstream)

  ## Returns
    - {:ok, toxic} on success
    - {:error, reason} on failure
  """
  def add_reset_peer(proxy, timeout_ms \\ 0, stream \\ :downstream) do
    add_toxic(proxy, "reset_peer_#{stream}_#{:erlang.unique_integer([:positive])}", "reset_peer", stream, %{
      timeout: timeout_ms
    })
  end

  @doc """
  Breaks the connection by disabling the proxy temporarily.

  This completely cuts off the connection and is useful for testing
  reconnection behavior. The connection remains broken until you call
  `enable/1` or `reset/1`.

  ## Parameters
    - proxy: The name of the proxy (e.g., "redis")

  ## Returns
    - :ok on success
    - {:error, reason} on failure

  ## Example

      # Break connection
      :ok = Toxiproxy.break_connection("redis")

      # Test that your code handles the disconnection...

      # Restore connection
      :ok = Toxiproxy.restore_connection("redis")
  """
  def break_connection(proxy) do
    disable(proxy)
  end

  @doc """
  Restores a previously broken connection.

  This re-enables the proxy and clears all toxics, returning to a clean state.

  ## Parameters
    - proxy: The name of the proxy (e.g., "redis")

  ## Returns
    - :ok on success
    - {:error, reason} on failure
  """
  def restore_connection(proxy) do
    with :ok <- enable(proxy),
         :ok <- reset(proxy) do
      :ok
    end
  end

  @doc """
  Temporarily breaks and restores the connection with a delay.

  This is a convenience method that simulates a brief connection outage.
  It disables the proxy, waits for the specified duration, then re-enables it.

  ## Parameters
    - proxy: The name of the proxy (e.g., "redis")
    - duration_ms: How long to keep the connection broken (default: 100ms)

  ## Returns
    - :ok on success
    - {:error, reason} on failure

  ## Example

      # Simulate a 2-second connection outage
      :ok = Toxiproxy.simulate_outage("redis", 2000)
  """
  def simulate_outage(proxy, duration_ms \\ 100) do
    with :ok <- disable(proxy) do
      Process.sleep(duration_ms)
      enable(proxy)
    end
  end

  @doc """
  Adds a custom toxic to the specified proxy.

  ## Parameters
    - proxy: The name of the proxy (e.g., "redis")
    - name: A unique name for this toxic
    - type: The type of toxic (e.g., "latency", "bandwidth", "timeout")
    - stream: :upstream or :downstream
    - attributes: A map of toxic-specific attributes
    - toxicity: Probability of toxic being applied (0.0 to 1.0, default: 1.0)

  ## Returns
    - {:ok, toxic} on success
    - {:error, reason} on failure
  """
  def add_toxic(proxy, name, type, stream, attributes, toxicity \\ 1.0) do
    body = %{
      name: name,
      type: type,
      stream: to_string(stream),
      toxicity: toxicity,
      attributes: attributes
    }

    case Req.post("#{@base_url}/proxies/#{proxy}/toxics", json: body) do
      {:ok, %{status: status, body: response}} when status in 200..299 ->
        {:ok, response}

      {:ok, %{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{inspect(body)}"}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Removes a specific toxic from the proxy.

  ## Parameters
    - proxy: The name of the proxy (e.g., "redis")
    - toxic_name: The name of the toxic to remove

  ## Returns
    - :ok on success
    - {:error, reason} on failure
  """
  def remove_toxic(proxy, toxic_name) do
    case Req.delete("#{@base_url}/proxies/#{proxy}/toxics/#{toxic_name}") do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{inspect(body)}"}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Removes all toxics from the proxy (resets to clean state).

  ## Parameters
    - proxy: The name of the proxy (e.g., "redis")

  ## Returns
    - :ok on success
    - {:error, reason} on failure
  """
  def reset(proxy) do
    with {:ok, toxics} <- list_toxics(proxy) do
      Enum.each(toxics, fn toxic ->
        remove_toxic(proxy, toxic["name"])
      end)

      :ok
    end
  end

  @doc """
  Lists all toxics for a proxy.

  ## Parameters
    - proxy: The name of the proxy (e.g., "redis")

  ## Returns
    - {:ok, toxics} on success where toxics is a list of toxic maps
    - {:error, reason} on failure
  """
  def list_toxics(proxy) do
    case Req.get("#{@base_url}/proxies/#{proxy}/toxics") do
      {:ok, %{status: 200, body: toxics}} ->
        {:ok, toxics}

      {:ok, %{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{inspect(body)}"}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Disables a proxy (stops forwarding traffic).

  ## Parameters
    - proxy: The name of the proxy (e.g., "redis")

  ## Returns
    - :ok on success
    - {:error, reason} on failure
  """
  def disable(proxy) do
    update_proxy(proxy, %{enabled: false})
  end

  @doc """
  Enables a proxy (resumes forwarding traffic).

  ## Parameters
    - proxy: The name of the proxy (e.g., "redis")

  ## Returns
    - :ok on success
    - {:error, reason} on failure
  """
  def enable(proxy) do
    update_proxy(proxy, %{enabled: true})
  end

  @doc """
  Gets the current status of a proxy.

  ## Parameters
    - proxy: The name of the proxy (e.g., "redis")

  ## Returns
    - {:ok, proxy_info} on success
    - {:error, reason} on failure
  """
  def get_proxy(proxy) do
    case Req.get("#{@base_url}/proxies/#{proxy}") do
      {:ok, %{status: 200, body: proxy_info}} ->
        {:ok, proxy_info}

      {:ok, %{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{inspect(body)}"}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Lists all proxies.

  ## Returns
    - {:ok, proxies} on success where proxies is a map of proxy name to proxy info
    - {:error, reason} on failure
  """
  def list_proxies do
    case Req.get("#{@base_url}/proxies") do
      {:ok, %{status: 200, body: proxies}} ->
        {:ok, proxies}

      {:ok, %{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{inspect(body)}"}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Updates a proxy's configuration.

  ## Parameters
    - proxy: The name of the proxy (e.g., "redis")
    - updates: A map of fields to update (e.g., %{enabled: false})

  ## Returns
    - :ok on success
    - {:error, reason} on failure
  """
  def update_proxy(proxy, updates) do
    case Req.post("#{@base_url}/proxies/#{proxy}", json: updates) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{inspect(body)}"}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Waits for Toxiproxy to be ready by polling the API.

  ## Parameters
    - timeout_ms: Maximum time to wait in milliseconds (default: 10000)
    - interval_ms: Interval between checks in milliseconds (default: 100)

  ## Returns
    - :ok when Toxiproxy is ready
    - {:error, :timeout} if timeout is reached
  """
  def wait_until_ready(timeout_ms \\ 10_000, interval_ms \\ 100) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until_ready(deadline, interval_ms)
  end

  defp do_wait_until_ready(deadline, interval_ms) do
    case list_proxies() do
      {:ok, _} ->
        :ok

      {:error, _} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(interval_ms)
          do_wait_until_ready(deadline, interval_ms)
        end
    end
  end
end
