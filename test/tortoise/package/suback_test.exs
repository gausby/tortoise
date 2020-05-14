defmodule Tortoise.Package.SubackTest do
  use ExUnit.Case
  use ExUnitProperties

  doctest Tortoise.Package.Suback

  alias Tortoise.Package

  property "encoding and decoding suback messages" do
    config = %Package.Suback{identifier: nil, acks: nil, properties: nil}

    check all suback <- Package.generate(config) do
      assert suback ==
               suback
               |> Package.encode()
               |> Package.decode()
    end
  end
end
