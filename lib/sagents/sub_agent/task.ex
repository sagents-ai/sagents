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
    as the `subagent_type` enum value (e.g. `"search-web"`).
  - `description/0` — one-line blurb surfaced in the `task` tool's auto-
    generated menu. Always in the parent's context.
  - `use_instructions/0` — detailed "how to invoke this" guide for the
    parent LLM. Lazy-loaded via `get_task_instructions` only when the
    parent decides it wants to use this task. Describes prerequisites
    (what inputs/source data must exist), what to pass in the
    `instructions` arg, and what outputs the task produces.
  - `instructions/0` — the task's internal working prompt. Baked into the
    child sub-agent's system prompt at invocation. Never shown to the
    parent. Should focus on the substantive procedure — the universal
    boilerplate (no user questions, complete-or-fail, etc.) is supplied
    by `Sagents.SubAgent.task_subagent_boilerplate/0`.
  - `display_text/0` — human-facing status string shown in the host UI
    while this task is running.
  """

  @callback task_name() :: String.t()
  @callback description() :: String.t()
  @callback use_instructions() :: String.t()
  @callback instructions() :: String.t()
  @callback display_text() :: String.t()
end
