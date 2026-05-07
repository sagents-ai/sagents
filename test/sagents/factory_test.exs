defmodule Sagents.FactoryTest do
  use Sagents.BaseCase, async: true

  alias Sagents.Factory

  describe "behaviour" do
    test "@callback create_agent/2 is declared" do
      callbacks = Factory.behaviour_info(:callbacks)
      assert {:create_agent, 2} in callbacks
    end
  end
end
