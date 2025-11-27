defmodule Veidrodelis.Command do
  @moduledoc """
  Redis command structs representing write operations parsed from RDB files.

  Each struct corresponds to a Redis command that would have been issued to create
  the data stored in the RDB file.
  """

  defmodule Set do
    @moduledoc """
    Represents a Redis SET command.

    ## Example
        %Veidrodelis.Command.Set{key: "mykey", value: "myvalue"}
    """
    @type t :: %__MODULE__{
            key: binary(),
            value: binary()
          }

    defstruct [:key, :value]
  end

  defmodule RPush do
    @moduledoc """
    Represents a Redis RPUSH command for a single list element.

    ## Example
        %Veidrodelis.Command.RPush{key: "mylist", value: "element"}
    """
    @type t :: %__MODULE__{
            key: binary(),
            value: binary()
          }

    defstruct [:key, :value]
  end

  defmodule SAdd do
    @moduledoc """
    Represents a Redis SADD command for a single set member.

    ## Example
        %Veidrodelis.Command.SAdd{key: "myset", member: "value"}
    """
    @type t :: %__MODULE__{
            key: binary(),
            member: binary()
          }

    defstruct [:key, :member]
  end

  defmodule ZAdd do
    @moduledoc """
    Represents a Redis ZADD command for a single sorted set member.

    ## Example
        %Veidrodelis.Command.ZAdd{key: "myzset", score: 1.5, member: "value"}
    """
    @type t :: %__MODULE__{
            key: binary(),
            score: float() | :nan | :pos_inf | :neg_inf,
            member: binary()
          }

    defstruct [:key, :score, :member]
  end

  defmodule HSet do
    @moduledoc """
    Represents a Redis HSET command for a single hash field.

    ## Example
        %Veidrodelis.Command.HSet{key: "myhash", field: "field1", value: "value1"}
    """
    @type t :: %__MODULE__{
            key: binary(),
            field: binary(),
            value: binary()
          }

    defstruct [:key, :field, :value]
  end

  defmodule PExpireAt do
    @moduledoc """
    Represents a Redis PEXPIREAT command for setting key expiration.

    ## Example
        %Veidrodelis.Command.PExpireAt{key: "mykey", timestamp_ms: 1609459200000}
    """
    @type t :: %__MODULE__{
            key: binary(),
            timestamp_ms: non_neg_integer()
          }

    defstruct [:key, :timestamp_ms]
  end

  @type t ::
          Set.t()
          | RPush.t()
          | SAdd.t()
          | ZAdd.t()
          | HSet.t()
          | PExpireAt.t()
end
