defmodule Sagents.AbilitySetTest do
  use ExUnit.Case, async: true

  alias LangChain.LangChainError
  alias Sagents.AbilitySet

  describe "new/1" do
    test "builds a set with defaults" do
      assert {:ok, %AbilitySet{} = set} = AbilitySet.new(%{when_to_use: "Billing questions."})

      assert set.when_to_use == "Billing questions."
      assert set.name == nil
      assert set.switch_message == nil
      assert set.middleware == []
    end

    test "accepts a keyword list and every field" do
      message = fn %{name: name} -> "Now in #{name}." end

      assert {:ok, set} =
               AbilitySet.new(
                 name: "Billing",
                 when_to_use: "Billing questions.",
                 switch_message: message,
                 middleware: [SomeMiddleware]
               )

      assert set.name == "Billing"
      assert set.switch_message == message
      assert set.middleware == [SomeMiddleware]
    end

    test "accepts a {module, function, args} switch_message" do
      assert {:ok, %AbilitySet{switch_message: {String, :upcase, []}}} =
               AbilitySet.new(%{when_to_use: "x", switch_message: {String, :upcase, []}})
    end

    test "requires when_to_use" do
      assert {:error, changeset} = AbilitySet.new(%{name: "Billing"})
      assert {"can't be blank", _opts} = changeset.errors[:when_to_use]
    end

    test "rejects an unknown key instead of ignoring it" do
      assert {:error, changeset} = AbilitySet.new(%{when_to_use: "x", when_to_us: "typo"})
      assert {message, _opts} = changeset.errors[:attrs]
      assert message =~ "unknown keys [:when_to_us]"
    end

    test "rejects an unknown string key" do
      assert {:error, changeset} = AbilitySet.new(%{"when_to_use" => "x", "mode" => "billing"})
      assert {message, _opts} = changeset.errors[:attrs]
      assert message =~ ~s(unknown keys ["mode"])
    end

    test "rejects an empty name, an invalid switch_message and non-list middleware" do
      assert {:error, changeset} =
               AbilitySet.new(%{
                 when_to_use: "x",
                 name: "",
                 switch_message: "",
                 middleware: SomeMiddleware
               })

      assert Keyword.has_key?(changeset.errors, :name)
      assert Keyword.has_key?(changeset.errors, :switch_message)
      assert Keyword.has_key?(changeset.errors, :middleware)

      for bad <- [42, fn -> "no arity" end, {String, :upcase}] do
        assert {:error, changeset} = AbilitySet.new(%{when_to_use: "x", switch_message: bad})
        assert Keyword.has_key?(changeset.errors, :switch_message)
      end
    end
  end

  describe "new!/1" do
    test "returns the set" do
      assert %AbilitySet{when_to_use: "x"} = AbilitySet.new!(%{when_to_use: "x"})
    end

    test "raises on an unknown key" do
      assert_raise LangChainError, ~r/unknown keys \[:midleware\]/, fn ->
        AbilitySet.new!(%{when_to_use: "x", midleware: []})
      end
    end
  end
end
