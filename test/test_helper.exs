# Load ENV keys for running live tests (optional for local testing)
Application.put_env(:langchain, :anthropic_key, System.get_env("ANTHROPIC_API_KEY", ""))
Application.put_env(:langchain, :openai_key, System.get_env("OPENAI_API_KEY", ""))

# The OpenTelemetry SDK is a test dependency, so it is loaded for every test run.
# LocalCluster starts each loaded application on its peer nodes with this node's
# env, so without an exporter setting the cluster tests boot the SDK on every
# peer with its default OTLP exporter, which is not installed.
Application.put_env(:opentelemetry, :traces_exporter, :none)

# Configure Mimic for mocking in tests
Mimic.copy(Req)
Mimic.copy(LangChain.ChatModels.ChatAnthropic)
Mimic.copy(LangChain.ChatModels.ChatOpenAI)
Mimic.copy(Sagents.SubAgentServer)
Mimic.copy(Sagents.FileSystem.FileSystemSupervisor)
Mimic.copy(Sagents.ProcessSupervisor)
Mimic.copy(Sagents.ProcessRegistry)
Mimic.copy(Sagents.AgentSupervisor)
Mimic.copy(Horde.Cluster)

# Start a shared PubSub for tests
{:ok, _pid} = Phoenix.PubSub.Supervisor.start_link(name: :test_pubsub)

# Start Sagents infrastructure (registry + dynamic supervisors)
{:ok, _pid} = Sagents.Supervisor.start_link(name: Sagents.Supervisor)

# Define a real Presence module for tests (no mocks needed)
defmodule Sagents.TestPresence do
  use Phoenix.Presence,
    otp_app: :sagents,
    pubsub_server: :test_pubsub
end

# Start the test Presence (Phoenix.Presence uses Supervisor.start_link/3 internally)
{:ok, _pid} = Supervisor.start_link([Sagents.TestPresence], strategy: :one_for_one)

Logger.configure(level: :warning)
ExUnit.configure(exclude: [live_call: true, cluster: true, slow: true])

ExUnit.start(capture_log: true)
