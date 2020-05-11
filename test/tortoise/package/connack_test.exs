defmodule Tortoise.Package.ConnackTest do
  use ExUnit.Case
  use ExUnitProperties

  doctest Tortoise.Package.Connack

  alias Tortoise.Package

  property "encoding and decoding connack messages" do
    config = %Package.Connack{reason: nil, session_present: nil, properties: nil}

    check all connack <- Package.generate(config) do
      assert connack ==
               connack
               |> Package.encode()
               |> Package.decode()
    end
  end
end
