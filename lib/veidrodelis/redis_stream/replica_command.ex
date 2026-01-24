defmodule Vdr.RedisStream.ReplicaCommand do
  @moduledoc """
  Represents a Redis command in a replication stream context.

  This struct encapsulates all information about a command being processed
  during replication, including the database number, the parsed command,
  the raw generic command, affected keys, and a context map for filters and callbacks.
  """

  @type t :: %__MODULE__{
          db: non_neg_integer(),
          command: tuple(),
          raw_command: tuple(),
          affected_keys: [binary()],
          context: map()
        }

  @enforce_keys [:db, :command, :raw_command, :affected_keys]
  defstruct [:db, :command, :raw_command, :affected_keys, context: %{}]
end
