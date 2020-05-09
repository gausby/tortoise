defmodule Tortoise.Package.PropertiesTest do
  use ExUnit.Case
  # use EQC.ExUnit
  doctest Tortoise.Package.Properties

  # alias Tortoise.Package.Properties

  # import Tortoise.TestGenerators, only: [gen_properties: 0]

  # property "encoding and decoding properties" do
  #   forall properties <- gen_properties() do
  #     ensure(
  #       properties ==
  #         properties
  #         |> Properties.encode()
  #         |> IO.iodata_to_binary()
  #         |> Properties.decode()
  #     )
  #   end
  # end
  @tag :skip
  test "encoding and decoding properties"
end
