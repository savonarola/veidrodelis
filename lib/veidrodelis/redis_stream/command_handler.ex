defmodule Vdr.RedisStream.CommandFilter do
  @type piggyback :: term()
  @type pre_handle :: (RedisCommand.t() -> {:ok, piggyback, RedisCommand.t()} | :skip)
  @type post_handle :: (piggyback -> :ok)

  def identity_pre_handle(command) do
    {:ok, nil, command}
  end

  def identity_post_handle(_piggyback) do
    :ok
  end

  defstruct pre_handle: &__MODULE__.identity_pre_handle/1,
            post_handle: &__MODULE__.identity_post_handle/1

  def combine(outer_filter, inner_filter) do
    %__MODULE__{
      pre_handle: fn command ->
        case outer_filter.pre_handle.(command) do
          {:ok, piggyback_outer, command} ->
            case inner_filter.pre_handle.(command) do
              {:ok, piggyback_inner, command} ->
                {:ok, {piggyback_outer, piggyback_inner}, command}

              :skip ->
                :skip
            end

          :skip ->
            :skip
        end
      end,
      post_handle: fn {piggyback_outer, piggyback_inner} ->
        :ok = inner_filter.post_handle.(piggyback_inner)
        :ok = outer_filter.post_handle.(piggyback_outer)
      end
    }
  end

  def apply(filter, command, fun) do
    case filter.pre_handle.(command) do
      :skip ->
        :ok

      {:ok, piggyback, command} ->
        result = fun.(command)
        :ok = filter.post_handle.(piggyback)
        result
    end
  end
end
