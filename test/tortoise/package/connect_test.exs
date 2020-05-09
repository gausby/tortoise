defmodule Tortoise.Package.ConnectTest do
  use ExUnit.Case
  # use EQC.ExUnit
  doctest Tortoise.Package.Connect

  # alias Tortoise.Package

  # import Tortoise.TestGenerators, only: [gen_connect: 0]

  # property "encoding and decoding connect messages" do
  #   forall connect <- gen_connect() do
  #     ensure(
  #       connect ==
  #         connect
  #         |> Package.encode()
  #         |> Package.decode()
  #     )
  #   end
  # end
  @tag :skip
  test "encoding and decoding connect messages"
end
