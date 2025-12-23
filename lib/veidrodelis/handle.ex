defmodule Vdr.Handle do
  defstruct [:callback_module, :handle_state]

  @type t :: %__MODULE__{
    callback_module: module(),
    handle_state: term()
  }

end
