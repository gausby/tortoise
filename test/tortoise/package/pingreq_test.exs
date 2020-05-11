defmodule Tortoise.Package.PingreqTest do
  use ExUnit.Case
  use ExUnitProperties

  doctest Tortoise.Package.Pingreq

  alias Tortoise.Package

  property "encoding and decoding pingreq messages" do
    # as pingreqs always look the same it might be overkill to have a
    # property based testing for this, but it is added for
    # completeness; also in case of future changes to the protocol it
    # might be eaiser to expand on this test, as I am hoping for user
    # defined properties on ping request and responses (just kidding)
    #
    # Yeah, this is kind of silly...
    config = %Package.Pingreq{}

    check all pingreq <- Package.generate(config) do
      assert pingreq ==
               pingreq
               |> Package.encode()
               |> Package.decode()
    end
  end
end
