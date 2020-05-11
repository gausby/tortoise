defmodule Tortoise.Package.PubrelTest do
  use ExUnit.Case
  use ExUnitProperties

  doctest Tortoise.Package.Pubrel

  alias Tortoise.Package

  property "encoding and decoding pubrel messages" do
    config = %Package.Pubrel{identifier: nil, reason: nil, properties: nil}

    check all pubrel <- Package.generate(config) do
      assert pubrel ==
               pubrel
               |> Package.encode()
               |> Package.decode()
    end
  end
end
