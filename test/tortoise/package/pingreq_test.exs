defmodule Tortoise311.Package.PingreqTest do
  use ExUnit.Case
  doctest Tortoise311.Package.Pingreq

  alias Tortoise311.Package

  test "encoding and decoding ping requests" do
    pingreq = %Package.Pingreq{}

    assert ^pingreq =
             pingreq
             |> Package.encode()
             |> Package.decode()
  end
end
