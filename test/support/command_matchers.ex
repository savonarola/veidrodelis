defmodule CommandMatchers do
  defmacro __using__(_opts) do
    quote do
      import unquote(__MODULE__)
    end
  end

  defmacro command_in_list(command, command_list) do
    quote do
      Enum.any?(unquote(command_list), fn
        unquote(command) -> true
        _ -> false
      end)
    end
  end

  defmacro filter_commands(command, command_list) do
    quote do
      Enum.filter(unquote(command_list), fn
        unquote(command) -> true
        _ -> false
      end)
    end
  end

  defmacro assert_within(timeout, do: block) do
    quote do
      deadline = System.monotonic_time(:millisecond) + unquote(timeout)
      check_fn = fn -> unquote(block) end

      CommandMatchers.poll_until(check_fn, deadline)
    end
  end

  defmodule AssertWithinFail do
    defexception [:message, :cause]

    @impl Exception
    def message(t) do
      "#{t.message}, cause: #{Exception.message(t.cause)}"
    end
  end

  def poll_until(check_fn, deadline, exc \\ nil) do
    if System.monotonic_time(:millisecond) < deadline do
      try do
        check_fn.()
        :ok
      rescue
        e ->
          Process.sleep(100)
          poll_until(check_fn, deadline, e)
      end
    else
      raise %AssertWithinFail{message: "Assert failed to succeed within timeout", cause: exc}
    end
  end
end
