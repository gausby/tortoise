defmodule Tortoise.Package.SubscribeTest do
  use ExUnit.Case
  # use EQC.ExUnit
  doctest Tortoise.Package.Subscribe

  # import Tortoise.TestGenerators, only: [gen_subscribe: 0]

  # alias Tortoise.Package
  # alias Tortoise.Package.Subscribe

  @tag :skip
  test "encoding and decoding subscribe messages"

  # property "encoding and decoding subscribe messages" do
  #   forall subscribe <- gen_subscribe() do
  #     ensure(
  #       subscribe ==
  #         subscribe
  #         |> Package.encode()
  #         |> Package.decode()
  #     )
  #   end
  # end

  # describe "Collectable" do
  #   test "Accept tuples of {binary(), opts()} as input" do
  #     assert %Subscribe{topics: [{"a", [qos: 1, no_local: true]}]} =
  #              [{"a", [qos: 1, no_local: true]}]
  #              |> Enum.into(%Subscribe{})
  #   end

  #   test "Accept tuples of {binary(), qos()} as input" do
  #     assert %Subscribe{topics: [{"a", [qos: 0]}]} =
  #              [{"a", 0}]
  #              |> Enum.into(%Subscribe{})
  #   end

  #   test "If no QoS is given it should default to zero" do
  #     assert %Subscribe{topics: [{"a", [qos: 0]}]} =
  #              ["a"]
  #              |> Enum.into(%Subscribe{})
  #   end

  #   test "If two topics are the same the last write should win" do
  #     assert %Subscribe{topics: [{"a", [qos: 1]}]} =
  #              [{"a", qos: 2}, {"a", qos: 0}, {"a", qos: 1}]
  #              |> Enum.into(%Subscribe{})
  #   end
  # end
end
