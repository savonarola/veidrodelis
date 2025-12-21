defmodule Vdr.TS do
  @moduledoc """
  Term Storage (TS) - Thread-safe binary storage.

  Provides independent storage instances that hold binary key-value pairs.
  Storage is process-independent and thread-safe, allowing concurrent access
  from multiple processes.

  Both keys and values must be binaries. The storage uses a Rust-native
  structure for efficient memory management.

  ## Example

      storage = Vdr.TS.create()

      :ok = Vdr.TS.set(storage, "user:1", "Alice")
      :ok = Vdr.TS.set(storage, "user:2", "Bob")

      "Alice" = Vdr.TS.get(storage, "user:1")
      nil = Vdr.TS.get(storage, "missing")

      :ok = Vdr.TS.del(storage, "user:1")
      :ok = Vdr.TS.destroy(storage)

  ## Thread Safety

  Storage instances are thread-safe and can be safely shared across
  multiple processes. All operations are protected by internal locking.

  ## Memory Management

  Binary data is stored in Rust-native structures. When you destroy
  a storage instance or it is garbage collected, all stored data is
  automatically freed.
  """

  use Rustler,
    otp_app: :veidrodelis,
    crate: :vdr_ts_nif,
    mode: if(Mix.env() == :prod, do: :release, else: :debug)

  @doc """
  Creates a new storage instance.

  Each call creates an independent storage with its own data.

  Returns an opaque reference to the storage that can be used with
  other functions.

  ## Examples

      storage = Vdr.TS.create()
      is_reference(storage)
      #=> true

      # Create multiple independent storages
      storage1 = Vdr.TS.create()
      storage2 = Vdr.TS.create()
      Vdr.TS.set(storage1, "key", "value1")
      Vdr.TS.set(storage2, "key", "value2")
      Vdr.TS.get(storage1, "key")
      #=> "value1"
      Vdr.TS.get(storage2, "key")
      #=> "value2"
  """
  @spec create() :: reference()
  def create(), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Stores a binary value with the given binary key.

  Both keys and values must be binaries. If the key already exists,
  its value is overwritten.

  ## Examples

      storage = Vdr.TS.create()

      # Store binary values
      :ok = Vdr.TS.set(storage, "key", "value")
      :ok = Vdr.TS.set(storage, "data", <<1, 2, 3, 4>>)

      # Overwrite existing key
      :ok = Vdr.TS.set(storage, "key", "new_value")
  """
  @spec set(reference(), binary(), binary()) :: :ok
  def set(_storage, _key, _value), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Retrieves a binary value by key.

  Returns the stored binary, or `nil` if the key doesn't exist.

  ## Examples

      storage = Vdr.TS.create()
      Vdr.TS.set(storage, "key", "value")

      Vdr.TS.get(storage, "key")
      #=> "value"

      Vdr.TS.get(storage, "missing")
      #=> nil

      # Binary data is preserved exactly
      data = <<0, 1, 2, 255, 254, 253>>
      Vdr.TS.set(storage, "binary", data)
      Vdr.TS.get(storage, "binary")
      #=> <<0, 1, 2, 255, 254, 253>>
  """
  @spec get(reference(), binary()) :: binary() | nil
  def get(_storage, _key), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Deletes a key from storage.

  Always returns `:ok`, even if the key doesn't exist. This makes
  deletion idempotent.

  ## Examples

      storage = Vdr.TS.create()
      Vdr.TS.set(storage, "key", "value")

      :ok = Vdr.TS.del(storage, "key")
      Vdr.TS.get(storage, "key")
      #=> nil

      # Deleting non-existent key still returns :ok
      :ok = Vdr.TS.del(storage, "missing")
  """
  @spec del(reference(), binary()) :: :ok
  def del(_storage, _key), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Destroys a storage instance, clearing all data.

  This clears the key-value map, freeing all stored binary data.

  After calling `destroy/1`, the storage can still be used (it will
  be empty), but it's generally better to create a new storage if
  you need one.

  ## Examples

      storage = Vdr.TS.create()
      Vdr.TS.set(storage, "key1", "value1")
      Vdr.TS.set(storage, "key2", "value2")

      :ok = Vdr.TS.destroy(storage)

      Vdr.TS.get(storage, "key1")
      #=> nil
      Vdr.TS.get(storage, "key2")
      #=> nil
  """
  @spec destroy(reference()) :: :ok
  def destroy(_storage), do: :erlang.nif_error(:nif_not_loaded)
end
