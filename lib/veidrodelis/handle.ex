defmodule Vdr.Handle do
  defstruct [:callback_module, :handle_state, :pid]

  @type t :: %__MODULE__{
          callback_module: module(),
          handle_state: term(),
          pid: pid()
        }
end
