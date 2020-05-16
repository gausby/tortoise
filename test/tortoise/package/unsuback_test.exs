defmodule Tortoise.Package.UnsubackTest do
  use ExUnit.Case
  use ExUnitProperties

  doctest Tortoise.Package.Unsuback

  alias Tortoise.Package

  property "encoding and decoding unsuback messages" do
    config = %Package.Unsuback{identifier: nil, results: nil, properties: nil}

    check all unsuback <- Package.generate(config) do
      assert unsuback ==
               unsuback
               |> Package.encode()
               |> Package.decode()
    end
  end
end
