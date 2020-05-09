defmodule Tortoise.Package.ConnackTest do
  use ExUnit.Case
  # use EQC.ExUnit
  doctest Tortoise.Package.Connack

  # import Tortoise.TestGenerators, only: [gen_connack: 0]

  # alias Tortoise.Package

  # property "encoding and decoding connack messages" do
  #   forall connack <- gen_connack() do
  #     ensure(
  #       connack ==
  #         connack
  #         |> Package.encode()
  #         |> Package.decode()
  #     )
  #   end
  # end
  @tag :skip
  test "encoding and decoding connack messages"
end
