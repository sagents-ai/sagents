defmodule Sagents.FactoryRouterTest do
  use Sagents.BaseCase, async: true

  alias Sagents.FactoryRouter

  describe "behaviour" do
    test "@callback resolve/3 is declared" do
      callbacks = FactoryRouter.behaviour_info(:callbacks)
      assert {:resolve, 3} in callbacks
    end
  end

  describe "Sagents.Routers.Single" do
    defmodule FakeFactory do
      def create_agent(_agent_id, _config), do: {:ok, :fake_agent, []}
    end

    defmodule FakeConfig do
      use Ecto.Schema
      import Ecto.Changeset

      @primary_key false
      embedded_schema do
        field :extra, :string
        field :scope, :any, virtual: true
        field :conversation_id, :any, virtual: true
      end

      def from_inputs(%{} = inputs) do
        attrs = %{extra: Map.get(inputs, :extra)}

        %__MODULE__{}
        |> cast(attrs, [:extra])
        |> put_change(:scope, Map.get(inputs, :scope))
        |> put_change(:conversation_id, Map.get(inputs, :conversation_id))
      end

      def build(%Ecto.Changeset{} = cs) do
        cs
        |> validate_required([:scope, :conversation_id])
        |> apply_action(:build)
      end
    end

    defmodule InvalidConfig do
      use Ecto.Schema
      import Ecto.Changeset

      @primary_key false
      embedded_schema do
        field :must_be_present, :string
        field :scope, :any, virtual: true
        field :conversation_id, :any, virtual: true
      end

      def from_inputs(%{} = inputs) do
        attrs = %{must_be_present: Map.get(inputs, :must_be_present)}

        %__MODULE__{}
        |> cast(attrs, [:must_be_present])
        |> put_change(:scope, Map.get(inputs, :scope))
        |> put_change(:conversation_id, Map.get(inputs, :conversation_id))
      end

      def build(%Ecto.Changeset{} = cs) do
        cs
        |> validate_required([:must_be_present, :scope, :conversation_id])
        |> apply_action(:build)
      end
    end

    defmodule SingleRouter do
      use Sagents.Routers.Single, factory: FakeFactory, config: FakeConfig
    end

    defmodule InvalidRouter do
      use Sagents.Routers.Single, factory: FakeFactory, config: InvalidConfig
    end

    test "implements the FactoryRouter behaviour" do
      assert function_exported?(SingleRouter, :resolve, 3)
    end

    test "successful build returns {:ok, factory, %ConfigStruct{}}" do
      assert {:ok, FakeFactory, %FakeConfig{} = config} =
               SingleRouter.resolve(:my_scope, "conv-1", [])

      assert config.scope == :my_scope
      assert config.conversation_id == "conv-1"
    end

    test "request_opts keys flow into the inputs map" do
      assert {:ok, FakeFactory, %FakeConfig{} = config} =
               SingleRouter.resolve(:s, "conv-7", extra: "hello")

      assert config.extra == "hello"
      assert config.scope == :s
      assert config.conversation_id == "conv-7"
    end

    test "build with missing required field returns {:error, %Ecto.Changeset{}}" do
      assert {:error, %Ecto.Changeset{} = cs} =
               InvalidRouter.resolve(:s, "conv-1", [])

      refute cs.valid?
      assert {_msg, [validation: :required]} = cs.errors[:must_be_present]
    end

    test "raises at compile-time without :factory option" do
      assert_raise KeyError, fn ->
        Code.eval_string("""
        defmodule BadRouterNoFactory do
          use Sagents.Routers.Single, config: Sagents.FactoryRouterTest.FakeConfig
        end
        """)
      end
    end

    test "raises at compile-time without :config option" do
      assert_raise KeyError, fn ->
        Code.eval_string("""
        defmodule BadRouterNoConfig do
          use Sagents.Routers.Single, factory: Sagents.FactoryRouterTest.FakeFactory
        end
        """)
      end
    end
  end
end
