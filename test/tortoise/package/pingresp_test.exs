defmodule Tortoise.Package.PingrespTest do
  use ExUnit.Case
  use ExUnitProperties

  doctest Tortoise.Package.Pingresp

  alias Tortoise.Package

  property "encoding and decoding pingresp messages" do
    # I know, data will always be the same, having a property for this
    # is kind of silly...
    config = %Package.Pingresp{}

    check all pingresp <- Package.generate(config) do
      assert pingresp ==
               pingresp
               |> Package.encode()
               |> Package.decode()
    end
  end
end
