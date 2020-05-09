defmodule Tortoise.Package.PubrecTest do
  use ExUnit.Case
  # use EQC.ExUnit
  doctest Tortoise.Package.Pubrec

  # alias Tortoise.Package

  # import Tortoise.TestGenerators, only: [gen_pubrec: 0]

  # property "encoding and decoding pubrec messages" do
  #   forall pubrec <- gen_pubrec() do
  #     ensure(
  #       pubrec ==
  #         pubrec
  #         |> Package.encode()
  #         |> Package.decode()
  #     )
  #   end
  # end

  @tag :skip
  test "encoding and decoding pubrec messages"
end
