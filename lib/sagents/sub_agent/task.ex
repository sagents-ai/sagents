defmodule Sagents.SubAgent.Task do
  @moduledoc """
  Behaviour for task modules that describe a named sub-agent "skill".

  Each task module describes a sub-agent that is registered on the parent
  agent's `Sagents.Middleware.SubAgent` and invoked via the built-in
  `task` tool. The sub-agent runs in an isolated context with its own
  middleware/tool stack, performs task-specific work, and reports back
  to the parent.

  Task modules are typically compiled into `Sagents.SubAgent.Compiled`
  entries by host applications, which combine the task's `instructions/0`
  with `Sagents.SubAgent.task_subagent_boilerplate/0` to form the child
  agent's system prompt.

  ## Callbacks

  - `task_name/0` — short, kebab-case identifier exposed to the parent LLM
    as the `task_name` enum value (e.g. `"search-web"`).
  - `description/0` — one-line blurb surfaced in the `task` tool's auto-
    generated menu. Always in the parent's context.
  - `use_instructions/0` — *optional.* Detailed "how to invoke this" guide
    for the parent LLM. Lazy-loaded via `get_task_instructions` only
    when the parent decides it wants to use this task. Describes
    prerequisites (what inputs/source data must exist), what to pass
    in the `instructions` arg, and what outputs the task produces. If
    not implemented, the host should treat this as "no lazy-loaded
    docs" — the task is invoked using only `description/0` as parent-
    visible guidance.
  - `instructions/0` — the task's internal working prompt. Baked into the
    child sub-agent's system prompt at invocation. Never shown to the
    parent. Should focus on the substantive procedure — the universal
    boilerplate (no user questions, complete-or-fail, etc.) is supplied
    by `Sagents.SubAgent.task_subagent_boilerplate/0`.
  - `display_text/0` — *optional.* Human-facing status string shown in
    the host UI while this task is running. If not implemented, the
    middleware falls back to a generic `"Running task"` label (see
    `Sagents.Middleware.SubAgent`); host compilers may instead derive
    a humanized form of `task_name/0`.
  - `model_override/0` — *optional.* If defined and returns a non-nil
    value, the host should use the returned model (e.g. a configured
    chat-model struct) for this task's sub-agent instead of the default
    model supplied at compile time. Useful for narrow, bounded tasks
    where a cheaper/faster model is sufficient (e.g. summarization,
    classification). Returning `nil` — or not implementing this
    callback at all — means "use the host's default."

  Host compilers should guard optional callbacks with
  `function_exported?/3` before calling them, and supply the documented
  fallback when absent.
  """

  @callback task_name() :: String.t()
  @callback description() :: String.t()
  @callback use_instructions() :: String.t()
  @callback instructions() :: String.t()
  @callback display_text() :: String.t()
  @callback model_override() :: term() | nil

  @optional_callbacks use_instructions: 0, display_text: 0, model_override: 0
end
