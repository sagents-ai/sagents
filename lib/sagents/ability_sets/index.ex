defmodule Sagents.AbilitySets.Index do
  @moduledoc """
  What an agent with ability sets sends for each set, computed once in
  `Sagents.Agent.new/2`.

  - `:config` - the `Sagents.Middleware.AbilitySetSwitcher` entry's config
  - `:effective` - map of set name (and `nil`, for rails only) to the
    `%{middleware: [...], tools: [...], system_prompt: "..."}` a chain built
    for that set carries
  - `:tool_sets` - map of tool name to the sets providing it, for every tool
    that belongs to a set

  Precomputing each set keeps chain builds free of work and gives every request
  in a set a byte-identical prompt and tool list.
  """

  @type effective :: %{
          middleware: [Sagents.MiddlewareEntry.t()],
          tools: [LangChain.Function.t()],
          system_prompt: String.t()
        }

  @type t :: %__MODULE__{
          config: map(),
          effective: %{optional(String.t() | nil) => effective()},
          tool_sets: %{optional(String.t()) => [String.t()]}
        }

  defstruct [:config, effective: %{}, tool_sets: %{}]
end
