defmodule Tortoise.Package.PingreqTest do
  use ExUnit.Case
  doctest Tortoise.Package.Pingreq

  alias Tortoise.Package

  test "encoding and decoding ping requests" do
    pingreq = %Package.Pingreq{}

    assert ^pingreq =
             pingreq
             |> Package.encode()
             |> Package.decode()
  end
end
