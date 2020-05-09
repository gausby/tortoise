defmodule Tortoise.Package.PubcompTest do
  use ExUnit.Case
  # use EQC.ExUnit
  doctest Tortoise.Package.Pubcomp

  # alias Tortoise.Package

  # import Tortoise.TestGenerators, only: [gen_pubcomp: 0]

  # property "encoding and decoding pubcomp messages" do
  #   forall pubcomp <- gen_pubcomp() do
  #     ensure(
  #       pubcomp ==
  #         pubcomp
  #         |> Package.encode()
  #         |> Package.decode()
  #     )
  #   end
  # end
  @tag :skip
  test "encoding and decoding pubcomp messages"
end
