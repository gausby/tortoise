defmodule Tortoise.PackageTest do
  use ExUnit.Case
  # use EQC.ExUnit
  doctest Tortoise.Package

  # alias Tortoise.Package

  # import Tortoise.TestGenerators,
  #   only: [gen_unsuback: 0, gen_puback: 0, gen_pubcomp: 0, gen_pubrel: 0, gen_pubrec: 0]

  # # Test that we support encoding and decoding of all the
  # # acknowledgement and complete packages
  # property "encoding and decoding acknowledgement messages" do
  #   forall ack <- oneof([gen_unsuback(), gen_puback(), gen_pubcomp(), gen_pubrel(), gen_pubrec()]) do
  #     ensure(
  #       ack ==
  #         ack
  #         |> Package.encode()
  #         |> Package.decode()
  #     )
  #   end
  # end

  @tag :skip
  test "gen_unsuback/0"

  @tag :skip
  test "gen_puback/0"

  @tag :skip
  test "gen_pubcomp/0"

  @tag :skip
  test "gen_pubrel/0"

  @tag :skip
  test "gen_pubrec/0"
end
