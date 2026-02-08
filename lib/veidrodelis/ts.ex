defmodule Vdr.TS do
  @moduledoc false

  use Rustler,
    otp_app: :veidrodelis,
    crate: :vdr_ts_nif,
    mode: if(Mix.env() == :test, do: :debug, else: :release)

  @spec create() :: reference()
  def create(), do: :erlang.nif_error(:nif_not_loaded)

  @spec destroy(reference()) :: :ok
  def destroy(_storage), do: :erlang.nif_error(:nif_not_loaded)

  @spec tx(reference(), [tuple()]) :: [term()]
  def tx(_storage, _commands), do: :erlang.nif_error(:nif_not_loaded)

  @spec lua_load(reference(), binary()) :: {:ok, binary()} | {:error, term()}
  def lua_load(_storage, _script), do: :erlang.nif_error(:nif_not_loaded)

  @spec read_tx(reference(), non_neg_integer(), [tuple()]) :: {:ok, [term()]} | {:error, term()}
  def read_tx(storage, db, commands) when is_list(commands) do
    read_tx_commands(storage, db, commands)
  end

  def read_tx(storage, db, script) when is_binary(script) do
    read_tx_lua(storage, db, script)
  end

  @spec read_tx_lua(reference(), non_neg_integer(), binary()) :: {:ok, term()} | {:error, term()}
  defp read_tx_lua(_storage, _db, _script_or_bytecode),
    do: :erlang.nif_error(:nif_not_loaded)

  @spec read_tx_commands(reference(), non_neg_integer(), [tuple()]) ::
          {:ok, [term()]} | {:error, term()}
  defp read_tx_commands(_storage, _db, _commands),
    do: :erlang.nif_error(:nif_not_loaded)
end
