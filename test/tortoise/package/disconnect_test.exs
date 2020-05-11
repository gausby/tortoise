defmodule Tortoise.Package.DisconnectTest do
  use ExUnit.Case
  use ExUnitProperties

  doctest Tortoise.Package.Disconnect

  alias Tortoise.Package

  property "encoding and decoding disconnect messages" do
    config = %Package.Disconnect{reason: nil, properties: nil}

    check all disconnect <- Package.generate(config) do
      assert disconnect ==
               disconnect
               |> Package.encode()
               |> Package.decode()
    end
  end
end
