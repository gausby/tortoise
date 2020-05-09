defmodule Tortoise.Package.DisconnectTest do
  use ExUnit.Case
  # use EQC.ExUnit
  doctest Tortoise.Package.Disconnect

  # alias Tortoise.Package

  # import Tortoise.TestGenerators, only: [gen_disconnect: 0]

  # property "encoding and decoding disconnect messages" do
  #   forall disconnect <- gen_disconnect() do
  #     ensure(
  #       disconnect ==
  #         disconnect
  #         |> Package.encode()
  #         |> Package.decode()
  #     )
  #   end
  # end
  @tag :skip
  test "encoding and decoding disconnect messages"
end
