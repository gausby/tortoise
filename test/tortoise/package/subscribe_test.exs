defmodule Tortoise.Package.SubscribeTest do
  use ExUnit.Case
  use EQC.ExUnit
  doctest Tortoise.Package.Subscribe

  import Tortoise.TestGenerators, only: [gen_subscribe: 0]

  alias Tortoise.Package
  alias Tortoise.Package.Subscribe

  property "encoding and decoding subscribe messages" do
    forall subscribe <- gen_subscribe() do
      ensure(
        subscribe ==
          subscribe
          |> Package.encode()
          |> Package.decode()
      )
    end
  end

  describe "Collectable" do
    test "Pick the largest QoS when topic filters repeat in input" do
      topic_filters = [{"a", 2}, {"a", 1}, {"a", 0}]
      assert %Subscribe{topics: [{"a", 2}]} = Enum.into(topic_filters, %Subscribe{})

      topic_filters = [{"a", 0}, {"a", 1}, {"a", 2}]
      assert %Subscribe{topics: [{"a", 2}]} = Enum.into(topic_filters, %Subscribe{})

      topic_filters = [{"a", 1}, {"a", 0}]
      assert %Subscribe{topics: [{"a", 1}]} = Enum.into(topic_filters, %Subscribe{})

      topic_filters = [{"a", 0}, {"a", 0}]
      assert %Subscribe{topics: [{"a", 0}]} = Enum.into(topic_filters, %Subscribe{})

      # if no qos is given it will default to 0, make sure we still
      # pick the biggest QoS given in the list in that case
      topic_filters = ["b", {"b", 2}, "b"]
      assert %Subscribe{topics: [{"b", 2}]} = Enum.into(topic_filters, %Subscribe{})
    end

    test "If no QoS is given it should default to zero" do
      topic_filters = ["a"]
      assert %Subscribe{topics: [{"a", 0}]} = Enum.into(topic_filters, %Subscribe{})
    end
  end
end
