defmodule Tortoise.Package.PubrecTest do
  use ExUnit.Case
  use ExUnitProperties

  doctest Tortoise.Package.Pubrec

  alias Tortoise.Package

  property "encoding and decoding pubrec messages" do
    config = %Package.Pubrec{identifier: nil, reason: nil, properties: nil}

    check all pubrec <- Package.generate(config) do
      assert pubrec ==
               pubrec
               |> Package.encode()
               |> Package.decode()
    end
  end
end
