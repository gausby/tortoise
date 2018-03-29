defmodule Tortoise.Package.DisconnectTest do
  use ExUnit.Case
  doctest Tortoise.Package.Disconnect

  alias Tortoise.Package

  test "encoding and decoding disconnect messages" do
    disconnect = %Package.Disconnect{}

    assert ^disconnect =
             disconnect
             |> Package.encode()
             |> Package.decode()
  end
end
