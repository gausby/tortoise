defmodule Tortoise.Package.PubackTest do
  use ExUnit.Case
  use ExUnitProperties

  doctest Tortoise.Package.Puback

  alias Tortoise.Package

  property "encoding and decoding puback messages" do
    config = %Package.Puback{identifier: nil, reason: nil, properties: nil}

    check all puback <- Package.generate(config) do
      assert puback ==
               puback
               |> Package.encode()
               |> Package.decode()
    end
  end
end
