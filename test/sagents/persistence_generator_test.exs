defmodule Sagents.PersistenceGeneratorTest do
  @moduledoc """
  The persistence generator writes every schema the generated context names.
  """
  # Changes the working directory, which is global to the VM.
  use ExUnit.Case, async: false

  alias Mix.Sagents.Gen.Persistence.Generator

  @moduletag :tmp_dir

  test "writes the user request schema next to the others", %{tmp_dir: tmp_dir} do
    config = %{
      context_module: "MyApp.Conversations",
      owner_module: "MyApp.Accounts.User",
      scope_module: "MyApp.Accounts.Scope",
      repo: "MyApp.Repo",
      table_prefix: "sagents_",
      owner_type: "user",
      owner_field: "user_id",
      agent_persistence_module: "MyApp.Agents.AgentPersistence"
    }

    paths = File.cd!(tmp_dir, fn -> Generator.generate(config) end)

    assert "lib/my_app/conversations/user_request.ex" in paths

    source = File.read!(Path.join(tmp_dir, "lib/my_app/conversations/user_request.ex"))
    assert {:ok, _ast} = Code.string_to_quoted(source)
    assert source =~ "defmodule MyApp.Conversations.UserRequest do"
  end
end
