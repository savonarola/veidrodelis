# Redis Sentinel connection helpers
defmodule RS do

  def primary() do
    redix_start_link(
      host: "localhost",
      port: 16390
    )
  end

  def replica() do
    redix_start_link(
      host: "localhost",
      port: 16391
    )
  end

  def sentinel(n \\ 1) do
    redix_start_link(
      host: "localhost",
      port: 27379 + n - 1
    )
  end

  def veidrodelis(id \\ :v) do
    {:ok, pid} = Veidrodelis.start_link(
      id: id,
      sentinel: [
        sentinels: [
          [host: "localhost", port: 27379],
          [host: "localhost", port: 27380],
          [host: "localhost", port: 27381]
        ],
        group: "mymaster",
        role: :primary,
        timeout: 5000,
        host_map: %{
          "172.28.0.20" => "localhost",
          "172.28.0.21" => "localhost",
          "172.28.0.31" => "localhost",
          "172.28.0.32" => "localhost",
          "172.28.0.33" => "localhost"
        }
      ]
    )
    pid
  end

  def veidrodelis_n(n \\ 1) do
    for i <- 1..n do
      veidrodelis(:"v#{i}")
    end
  end

  defp redix_start_link(opts) do
    {:ok, pid} = Redix.start_link(opts)
    pid
  end

end
