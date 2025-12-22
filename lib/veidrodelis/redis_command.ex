defmodule Vdr.RedisCommand do
  @moduledoc """
  Redis command structs representing write operations parsed from RDB files.

  Each struct corresponds to a Redis command that would have been issued to create
  the data stored in the RDB file.
  """

  defmodule Set do
    @moduledoc """
    Represents a Redis SET command.

    ## Example
        %Vdr.RedisCommand.Set{key: "mykey", value: "myvalue"}
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
        %Vdr.RedisCommand.RPush{key: "mylist", values: ["elem1", "elem2"]}
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
        %Vdr.RedisCommand.SAdd{key: "myset", members: ["member1", "member2"]}
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
        %Vdr.RedisCommand.ZAdd{key: "myzset", members: [{1.5, "member1"}, {2.0, "member2"}]}
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
        %Vdr.RedisCommand.HSet{key: "myhash", fields: [{"field1", "value1"}, {"field2", "value2"}]}
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
        %Vdr.RedisCommand.PExpireAt{key: "mykey", timestamp_ms: 1609459200000}
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
        %Vdr.RedisCommand.Del{keys: ["key1", "key2"]}
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
        %Vdr.RedisCommand.Rename{key: "oldkey", newkey: "newkey"}
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
        %Vdr.RedisCommand.RenameNX{key: "oldkey", newkey: "newkey"}
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
        %Vdr.RedisCommand.Move{key: "mykey", db: 1}
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
        %Vdr.RedisCommand.MSet{pairs: [{"key1", "value1"}, {"key2", "value2"}]}
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
        %Vdr.RedisCommand.Append{key: "mykey", value: "data"}
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
        %Vdr.RedisCommand.SetRange{key: "mykey", offset: 10, value: "data"}
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
        %Vdr.RedisCommand.SetBit{key: "mykey", offset: 100, value: 1}
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
        %Vdr.RedisCommand.LPush{key: "mylist", values: ["elem1", "elem2"]}
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
        %Vdr.RedisCommand.LPushX{key: "mylist", values: ["elem1"]}
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
        %Vdr.RedisCommand.RPushX{key: "mylist", values: ["elem1"]}
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
        %Vdr.RedisCommand.LPop{key: "mylist"}
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
        %Vdr.RedisCommand.RPop{key: "mylist"}
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
        %Vdr.RedisCommand.LRem{key: "mylist", count: 2, value: "element"}
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
        %Vdr.RedisCommand.LTrim{key: "mylist", start: 0, stop: 99}
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
        %Vdr.RedisCommand.LSet{key: "mylist", index: 0, value: "element"}
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
        %Vdr.RedisCommand.LInsert{key: "mylist", before_after: :before, pivot: "marker", element: "new"}
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
        %Vdr.RedisCommand.RPopLPush{source: "source_list", destination: "dest_list"}
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
        %Vdr.RedisCommand.HDel{key: "myhash", fields: ["field1", "field2"]}
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
        %Vdr.RedisCommand.SRem{key: "myset", members: ["member1", "member2"]}
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
        %Vdr.RedisCommand.SMove{source: "set1", destination: "set2", member: "value"}
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
        %Vdr.RedisCommand.SInterStore{destination: "result", keys: ["set1", "set2"]}
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
        %Vdr.RedisCommand.SUnionStore{destination: "result", keys: ["set1", "set2"]}
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
        %Vdr.RedisCommand.SDiffStore{destination: "result", keys: ["set1", "set2"]}
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
        %Vdr.RedisCommand.ZRem{key: "myzset", members: ["member1", "member2"]}
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
        %Vdr.RedisCommand.ZPopMax{key: "myzset", count: 1}
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
        %Vdr.RedisCommand.ZPopMin{key: "myzset", count: 1}
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
        %Vdr.RedisCommand.ZRemRangeByRank{key: "myzset", start: 0, stop: 10}
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
        %Vdr.RedisCommand.ZRemRangeByScore{key: "myzset", min: "0", max: "100"}
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
        %Vdr.RedisCommand.ZRemRangeByLex{key: "myzset", min: "[a", max: "[z"}
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
        %Vdr.RedisCommand.ZUnionStore{destination: "result", keys: ["zset1", "zset2"], weights: [1.0, 2.0], aggregate: :sum}
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
        %Vdr.RedisCommand.ZInterStore{destination: "result", keys: ["zset1", "zset2"], weights: [1.0, 2.0], aggregate: :sum}
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
        %Vdr.RedisCommand.Generic{args: ["PING"]}
        %Vdr.RedisCommand.Generic{args: ["CONFIG", "SET", "timeout", "300"]}
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
