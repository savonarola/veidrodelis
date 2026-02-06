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

  def vdr(id \\ :v) do
    {:ok, pid} =
      Veidrodelis.start_link(
        id: id,
        sentinel: [
          sentinels: [
            [host: "localhost", port: 27379],
            [host: "localhost", port: 27380],
            [host: "localhost", port: 27381]
          ],
          group: "myprimary",
          role: :primary,
          timeout: 5000,
          host_map: fn _host -> "localhost" end
        ]
      )

    pid
  end

  # Replica
  def vdr_r(id \\ :v) do
    {:ok, pid} =
      Veidrodelis.start_link(
        id: id,
        sentinel: [
          sentinels: [
            [host: "localhost", port: 27379],
            [host: "localhost", port: 27380],
            [host: "localhost", port: 27381]
          ],
          group: "myprimary",
          role: :replica,
          timeout: 5000,
          host_map: fn _host -> "localhost" end
        ]
      )

    pid
  end

  def vdr_n(n \\ 1) do
    for i <- 1..n do
      vdr(:"v#{i}")
    end
  end

  def vdr_r_n(n \\ 1) do
    for i <- 1..n do
      vdr_r(:"v#{i}")
    end
  end

  defp redix_start_link(opts) do
    {:ok, pid} = Redix.start_link(opts)
    pid
  end
end
