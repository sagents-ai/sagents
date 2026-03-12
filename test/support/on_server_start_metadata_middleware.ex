defmodule Sagents.TestOnServerStartMetadataMiddleware do
  @behaviour Sagents.Middleware

  alias Sagents.State

  @impl true
  def init(opts) do
    {:ok, %{key: Keyword.get(opts, :key, "startup_key"), value: Keyword.get(opts, :value, "set")}}
  end

  @impl true
  def on_server_start(state, config) do
    {:ok, State.put_metadata(state, config.key, config.value)}
  end
end
