defmodule Tortoise.Package.UnsubackTest do
  use ExUnit.Case
  # use EQC.ExUnit
  doctest Tortoise.Package.Unsuback

  # import Tortoise.TestGenerators, only: [gen_unsuback: 0]

  # alias Tortoise.Package

  # property "encoding and decoding unsuback messages" do
  #   forall unsuback <- gen_unsuback() do
  #     ensure(
  #       unsuback ==
  #         unsuback
  #         |> Package.encode()
  #         |> Package.decode()
  #     )
  #   end
  # end
  @tag :skip
  test "encoding and decoding unsuback messages"
end
