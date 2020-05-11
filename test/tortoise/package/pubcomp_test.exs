defmodule Tortoise.Package.PubcompTest do
  use ExUnit.Case
  use ExUnitProperties

  doctest Tortoise.Package.Pubcomp

  alias Tortoise.Package

  property "encoding and decoding pubcomp messages" do
    config = %Package.Pubcomp{identifier: nil, reason: nil, properties: nil}

    check all pubcomp <- Package.generate(config) do
      assert pubcomp ==
               pubcomp
               |> Package.encode()
               |> Package.decode()
    end
  end
end
