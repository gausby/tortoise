defmodule Tortoise.Package.SubackTest do
  use ExUnit.Case
  # use EQC.ExUnit
  doctest Tortoise.Package.Suback

  # import Tortoise.TestGenerators, only: [gen_suback: 0]

  # alias Tortoise.Package

  # property "encoding and decoding suback messages" do
  #   forall suback <- gen_suback() do
  #     ensure(
  #       suback ==
  #         suback
  #         |> Package.encode()
  #         |> Package.decode()
  #     )
  #   end
  # end

  @tag :skip
  test "encoding and decoding suback messages"
end
