defmodule Vdr.WatchEvent do
  @moduledoc """
  Watch event message types sent to watchers when subscribed keys are modified.
  """

  defmodule Update do
    @moduledoc """
    Notification sent when a watched key is modified by a Redis command.

    Contains the command that modified the key and the database number where
    the modification occurred.

    ## Fields

      * `command` - The Redis command struct that modified the key (from `Vdr.RedisStream.Command`)
      * `db` - The database number where the modification occurred

    ## Example

      When a watcher receives this message:

          receive do
            {ref, %Vdr.WatchEvent.Update{command: cmd, db: db}} ->
              # Handle the update
              IO.inspect({ref, cmd, db})
          end
    """

    @type t :: %__MODULE__{
            command: Vdr.RedisStream.Command.t(),
            db: non_neg_integer()
          }

    defstruct [:command, :db]
  end

  defmodule Init do
    @moduledoc """
    Notification sent when the replica transitions to streaming mode.

    This message is sent to all watchers when the replica completes an RDB
    transfer and begins streaming mode. It signals that the in-memory state
    is now synchronized with Redis and subsequent Update messages will follow.

    ## Example

      When a watcher receives this message:

          receive do
            {ref, %Vdr.WatchEvent.Init{}} ->
              # Replica is now in streaming mode
              # Future updates will arrive as Update messages
              :ready
          end
    """

    @type t :: %__MODULE__{}

    defstruct []
  end
end
