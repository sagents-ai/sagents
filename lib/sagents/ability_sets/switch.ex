defmodule Sagents.AbilitySets.Switch do
  @moduledoc """
  The result a chain ends with when the model switched ability sets.

  `Sagents.Mode.Steps.check_ability_switch/2` ends the chain with
  `{:ok, chain, %Switch{}}` once a `switch_mode` call has changed the active set.
  `Sagents.Agent.execute/3` recognizes it and continues the same call on a new
  chain built from the new set. It never reaches the caller.

  - `:from` - the set the chain was built for (`nil` for rails only)
  - `:to` - the set the state now names
  - `:mode_state` - the chain's `custom_context.mode_state`, so the next chain
    continues the `:max_runs` budget rather than starting a new one
  """

  @type t :: %__MODULE__{
          from: String.t() | nil,
          to: String.t() | nil,
          mode_state: map() | nil
        }

  defstruct [:from, :to, :mode_state]
end
