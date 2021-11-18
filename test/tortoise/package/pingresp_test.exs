defmodule Tortoise311.Package.PingrespTest do
  use ExUnit.Case
  doctest Tortoise311.Package.Pingresp

  alias Tortoise311.Package

  test "encoding and decoding ping responses" do
    pingresp = %Package.Pingresp{}

    assert ^pingresp =
             pingresp
             |> Package.encode()
             |> Package.decode()
  end
end
