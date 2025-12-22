defmodule Vdr.RedisStream.ReplicaCommand do
  @moduledoc """
  Represents a Redis command in a replication stream context.

  This struct encapsulates all information about a command being processed
  during replication, including the database number, the parsed command,
  the raw generic command, and a context map for filters and callbacks.
  """

  alias Vdr.RedisStream.Command, as: RedisCommand

  @type t :: %__MODULE__{
          db: non_neg_integer(),
          command: RedisCommand.t(),
          raw_command: RedisCommand.Generic.t(),
          context: map()
        }

  @enforce_keys [:db, :command, :raw_command]
  defstruct [:db, :command, :raw_command, context: %{}]
end
