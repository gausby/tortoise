defmodule Tortoise311.Package.DisconnectTest do
  use ExUnit.Case
  doctest Tortoise311.Package.Disconnect

  alias Tortoise311.Package

  test "encoding and decoding disconnect messages" do
    disconnect = %Package.Disconnect{}

    assert ^disconnect =
             disconnect
             |> Package.encode()
             |> Package.decode()
  end
end
