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
    Represents a Redis RPUSH command.

    ## Example
        %Veidrodelis.Command.RPush{key: "mylist", values: ["elem1", "elem2"]}
    """
    @type t :: %__MODULE__{
            key: binary(),
            values: [binary()]
          }

    defstruct [:key, :values]
  end

  defmodule SAdd do
    @moduledoc """
    Represents a Redis SADD command.

    ## Example
        %Veidrodelis.Command.SAdd{key: "myset", members: ["member1", "member2"]}
    """
    @type t :: %__MODULE__{
            key: binary(),
            members: [binary()]
          }

    defstruct [:key, :members]
  end

  defmodule ZAdd do
    @moduledoc """
    Represents a Redis ZADD command.

    ## Example
        %Veidrodelis.Command.ZAdd{key: "myzset", members: [{1.5, "member1"}, {2.0, "member2"}]}
    """
    @type t :: %__MODULE__{
            key: binary(),
            members: [{float() | :nan | :pos_inf | :neg_inf, binary()}]
          }

    defstruct [:key, :members]
  end

  defmodule HSet do
    @moduledoc """
    Represents a Redis HSET command.

    ## Example
        %Veidrodelis.Command.HSet{key: "myhash", fields: [{"field1", "value1"}, {"field2", "value2"}]}
    """
    @type t :: %__MODULE__{
            key: binary(),
            fields: [{binary(), binary()}]
          }

    defstruct [:key, :fields]
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

  # Generic and Key-Level Commands

  defmodule Del do
    @moduledoc """
    Represents a Redis DEL command for deleting one or more keys.

    ## Example
        %Veidrodelis.Command.Del{keys: ["key1", "key2"]}
    """
    @type t :: %__MODULE__{
            keys: [binary()]
          }

    defstruct [:keys]
  end

  defmodule Rename do
    @moduledoc """
    Represents a Redis RENAME command.

    ## Example
        %Veidrodelis.Command.Rename{key: "oldkey", newkey: "newkey"}
    """
    @type t :: %__MODULE__{
            key: binary(),
            newkey: binary()
          }

    defstruct [:key, :newkey]
  end

  defmodule RenameNX do
    @moduledoc """
    Represents a Redis RENAMENX command.

    ## Example
        %Veidrodelis.Command.RenameNX{key: "oldkey", newkey: "newkey"}
    """
    @type t :: %__MODULE__{
            key: binary(),
            newkey: binary()
          }

    defstruct [:key, :newkey]
  end

  defmodule Move do
    @moduledoc """
    Represents a Redis MOVE command.

    ## Example
        %Veidrodelis.Command.Move{key: "mykey", db: 1}
    """
    @type t :: %__MODULE__{
            key: binary(),
            db: non_neg_integer()
          }

    defstruct [:key, :db]
  end

  # String Commands

  defmodule MSet do
    @moduledoc """
    Represents a Redis MSET command for setting multiple keys.

    ## Example
        %Veidrodelis.Command.MSet{pairs: [{"key1", "value1"}, {"key2", "value2"}]}
    """
    @type t :: %__MODULE__{
            pairs: [{binary(), binary()}]
          }

    defstruct [:pairs]
  end

  defmodule Append do
    @moduledoc """
    Represents a Redis APPEND command.

    ## Example
        %Veidrodelis.Command.Append{key: "mykey", value: "data"}
    """
    @type t :: %__MODULE__{
            key: binary(),
            value: binary()
          }

    defstruct [:key, :value]
  end

  defmodule SetRange do
    @moduledoc """
    Represents a Redis SETRANGE command.

    ## Example
        %Veidrodelis.Command.SetRange{key: "mykey", offset: 10, value: "data"}
    """
    @type t :: %__MODULE__{
            key: binary(),
            offset: non_neg_integer(),
            value: binary()
          }

    defstruct [:key, :offset, :value]
  end

  defmodule SetBit do
    @moduledoc """
    Represents a Redis SETBIT command.

    ## Example
        %Veidrodelis.Command.SetBit{key: "mykey", offset: 100, value: 1}
    """
    @type t :: %__MODULE__{
            key: binary(),
            offset: non_neg_integer(),
            value: 0 | 1
          }

    defstruct [:key, :offset, :value]
  end

  # List Commands

  defmodule LPush do
    @moduledoc """
    Represents a Redis LPUSH command.

    ## Example
        %Veidrodelis.Command.LPush{key: "mylist", values: ["elem1", "elem2"]}
    """
    @type t :: %__MODULE__{
            key: binary(),
            values: [binary()]
          }

    defstruct [:key, :values]
  end

  defmodule LPushX do
    @moduledoc """
    Represents a Redis LPUSHX command.

    ## Example
        %Veidrodelis.Command.LPushX{key: "mylist", values: ["elem1"]}
    """
    @type t :: %__MODULE__{
            key: binary(),
            values: [binary()]
          }

    defstruct [:key, :values]
  end

  defmodule RPushX do
    @moduledoc """
    Represents a Redis RPUSHX command.

    ## Example
        %Veidrodelis.Command.RPushX{key: "mylist", values: ["elem1"]}
    """
    @type t :: %__MODULE__{
            key: binary(),
            values: [binary()]
          }

    defstruct [:key, :values]
  end

  defmodule LPop do
    @moduledoc """
    Represents a Redis LPOP command.

    ## Example
        %Veidrodelis.Command.LPop{key: "mylist"}
    """
    @type t :: %__MODULE__{
            key: binary()
          }

    defstruct [:key]
  end

  defmodule RPop do
    @moduledoc """
    Represents a Redis RPOP command.

    ## Example
        %Veidrodelis.Command.RPop{key: "mylist"}
    """
    @type t :: %__MODULE__{
            key: binary()
          }

    defstruct [:key]
  end

  defmodule LRem do
    @moduledoc """
    Represents a Redis LREM command.

    ## Example
        %Veidrodelis.Command.LRem{key: "mylist", count: 2, value: "element"}
    """
    @type t :: %__MODULE__{
            key: binary(),
            count: integer(),
            value: binary()
          }

    defstruct [:key, :count, :value]
  end

  defmodule LTrim do
    @moduledoc """
    Represents a Redis LTRIM command.

    ## Example
        %Veidrodelis.Command.LTrim{key: "mylist", start: 0, stop: 99}
    """
    @type t :: %__MODULE__{
            key: binary(),
            start: integer(),
            stop: integer()
          }

    defstruct [:key, :start, :stop]
  end

  defmodule LSet do
    @moduledoc """
    Represents a Redis LSET command.

    ## Example
        %Veidrodelis.Command.LSet{key: "mylist", index: 0, value: "element"}
    """
    @type t :: %__MODULE__{
            key: binary(),
            index: integer(),
            value: binary()
          }

    defstruct [:key, :index, :value]
  end

  defmodule LInsert do
    @moduledoc """
    Represents a Redis LINSERT command.

    ## Example
        %Veidrodelis.Command.LInsert{key: "mylist", before_after: :before, pivot: "marker", element: "new"}
    """
    @type t :: %__MODULE__{
            key: binary(),
            before_after: :before | :after,
            pivot: binary(),
            element: binary()
          }

    defstruct [:key, :before_after, :pivot, :element]
  end

  defmodule RPopLPush do
    @moduledoc """
    Represents a Redis RPOPLPUSH command.

    ## Example
        %Veidrodelis.Command.RPopLPush{source: "source_list", destination: "dest_list"}
    """
    @type t :: %__MODULE__{
            source: binary(),
            destination: binary()
          }

    defstruct [:source, :destination]
  end

  # Hash Commands

  defmodule HDel do
    @moduledoc """
    Represents a Redis HDEL command.

    ## Example
        %Veidrodelis.Command.HDel{key: "myhash", fields: ["field1", "field2"]}
    """
    @type t :: %__MODULE__{
            key: binary(),
            fields: [binary()]
          }

    defstruct [:key, :fields]
  end

  # Set Commands

  defmodule SRem do
    @moduledoc """
    Represents a Redis SREM command.

    ## Example
        %Veidrodelis.Command.SRem{key: "myset", members: ["member1", "member2"]}
    """
    @type t :: %__MODULE__{
            key: binary(),
            members: [binary()]
          }

    defstruct [:key, :members]
  end

  defmodule SMove do
    @moduledoc """
    Represents a Redis SMOVE command.

    ## Example
        %Veidrodelis.Command.SMove{source: "set1", destination: "set2", member: "value"}
    """
    @type t :: %__MODULE__{
            source: binary(),
            destination: binary(),
            member: binary()
          }

    defstruct [:source, :destination, :member]
  end

  defmodule SInterStore do
    @moduledoc """
    Represents a Redis SINTERSTORE command.

    ## Example
        %Veidrodelis.Command.SInterStore{destination: "result", keys: ["set1", "set2"]}
    """
    @type t :: %__MODULE__{
            destination: binary(),
            keys: [binary()]
          }

    defstruct [:destination, :keys]
  end

  defmodule SUnionStore do
    @moduledoc """
    Represents a Redis SUNIONSTORE command.

    ## Example
        %Veidrodelis.Command.SUnionStore{destination: "result", keys: ["set1", "set2"]}
    """
    @type t :: %__MODULE__{
            destination: binary(),
            keys: [binary()]
          }

    defstruct [:destination, :keys]
  end

  defmodule SDiffStore do
    @moduledoc """
    Represents a Redis SDIFFSTORE command.

    ## Example
        %Veidrodelis.Command.SDiffStore{destination: "result", keys: ["set1", "set2"]}
    """
    @type t :: %__MODULE__{
            destination: binary(),
            keys: [binary()]
          }

    defstruct [:destination, :keys]
  end

  # Sorted Set Commands

  defmodule ZRem do
    @moduledoc """
    Represents a Redis ZREM command.

    ## Example
        %Veidrodelis.Command.ZRem{key: "myzset", members: ["member1", "member2"]}
    """
    @type t :: %__MODULE__{
            key: binary(),
            members: [binary()]
          }

    defstruct [:key, :members]
  end

  defmodule ZPopMax do
    @moduledoc """
    Represents a Redis ZPOPMAX command.

    ## Example
        %Veidrodelis.Command.ZPopMax{key: "myzset", count: 1}
    """
    @type t :: %__MODULE__{
            key: binary(),
            count: pos_integer()
          }

    defstruct key: nil, count: 1
  end

  defmodule ZPopMin do
    @moduledoc """
    Represents a Redis ZPOPMIN command.

    ## Example
        %Veidrodelis.Command.ZPopMin{key: "myzset", count: 1}
    """
    @type t :: %__MODULE__{
            key: binary(),
            count: pos_integer()
          }

    defstruct key: nil, count: 1
  end

  defmodule ZRemRangeByRank do
    @moduledoc """
    Represents a Redis ZREMRANGEBYRANK command.

    ## Example
        %Veidrodelis.Command.ZRemRangeByRank{key: "myzset", start: 0, stop: 10}
    """
    @type t :: %__MODULE__{
            key: binary(),
            start: integer(),
            stop: integer()
          }

    defstruct [:key, :start, :stop]
  end

  defmodule ZRemRangeByScore do
    @moduledoc """
    Represents a Redis ZREMRANGEBYSCORE command.

    ## Example
        %Veidrodelis.Command.ZRemRangeByScore{key: "myzset", min: "0", max: "100"}
    """
    @type t :: %__MODULE__{
            key: binary(),
            min: binary(),
            max: binary()
          }

    defstruct [:key, :min, :max]
  end

  defmodule ZRemRangeByLex do
    @moduledoc """
    Represents a Redis ZREMRANGEBYLEX command.

    ## Example
        %Veidrodelis.Command.ZRemRangeByLex{key: "myzset", min: "[a", max: "[z"}
    """
    @type t :: %__MODULE__{
            key: binary(),
            min: binary(),
            max: binary()
          }

    defstruct [:key, :min, :max]
  end

  defmodule ZUnionStore do
    @moduledoc """
    Represents a Redis ZUNIONSTORE command.

    ## Example
        %Veidrodelis.Command.ZUnionStore{destination: "result", keys: ["zset1", "zset2"], weights: [1.0, 2.0], aggregate: :sum}
    """
    @type t :: %__MODULE__{
            destination: binary(),
            keys: [binary()],
            weights: [float()] | nil,
            aggregate: :sum | :min | :max | nil
          }

    defstruct [:destination, :keys, :weights, :aggregate]
  end

  defmodule ZInterStore do
    @moduledoc """
    Represents a Redis ZINTERSTORE command.

    ## Example
        %Veidrodelis.Command.ZInterStore{destination: "result", keys: ["zset1", "zset2"], weights: [1.0, 2.0], aggregate: :sum}
    """
    @type t :: %__MODULE__{
            destination: binary(),
            keys: [binary()],
            weights: [float()] | nil,
            aggregate: :sum | :min | :max | nil
          }

    defstruct [:destination, :keys, :weights, :aggregate]
  end

  # Generic Command

  defmodule Generic do
    @moduledoc """
    Represents a generic Redis command with raw arguments.

    Used for commands that don't have a specific struct definition.

    ## Example
        %Veidrodelis.Command.Generic{args: ["PING"]}
        %Veidrodelis.Command.Generic{args: ["CONFIG", "SET", "timeout", "300"]}
    """
    @type t :: %__MODULE__{
            args: [binary()]
          }

    defstruct [:args]
  end

  @type t ::
          Set.t()
          | RPush.t()
          | SAdd.t()
          | ZAdd.t()
          | HSet.t()
          | PExpireAt.t()
          | Del.t()
          | Rename.t()
          | RenameNX.t()
          | Move.t()
          | MSet.t()
          | Append.t()
          | SetRange.t()
          | SetBit.t()
          | LPush.t()
          | LPushX.t()
          | RPushX.t()
          | LPop.t()
          | RPop.t()
          | LRem.t()
          | LTrim.t()
          | LSet.t()
          | LInsert.t()
          | RPopLPush.t()
          | HDel.t()
          | SRem.t()
          | SMove.t()
          | SInterStore.t()
          | SUnionStore.t()
          | SDiffStore.t()
          | ZRem.t()
          | ZPopMax.t()
          | ZPopMin.t()
          | ZRemRangeByRank.t()
          | ZRemRangeByScore.t()
          | ZRemRangeByLex.t()
          | ZUnionStore.t()
          | ZInterStore.t()
          | Generic.t()
end
