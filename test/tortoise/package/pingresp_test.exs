defmodule Tortoise.Package.PingrespTest do
  use ExUnit.Case
  doctest Tortoise.Package.Pingresp

  alias Tortoise.Package

  test "encoding and decoding ping responses" do
    pingresp = %Package.Pingresp{}

    assert ^pingresp =
             pingresp
             |> Package.encode()
             |> Package.decode()
  end
end
